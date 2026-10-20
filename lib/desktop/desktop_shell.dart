import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/db.dart';
import '../core/settings.dart';
import '../sip/native_bridge.dart';
import '../sip/sip_service.dart';
import 'call_links.dart';
import 'engine.dart';

/// How the window is shown: the app, or the small always-on-top card a call
/// rings in while the app is hidden or behind other windows.
enum WindowMode { normal, ringing }

/// The desktop around the app: the window (close keeps Medut in the tray),
/// the tray icon and its menu, the ringing pop-up and notifications, links
/// and command lines handed over by a second launch, and start at login.
class DesktopShell with WindowListener, TrayListener, WidgetsBindingObserver {
  DesktopShell._();
  static final instance = DesktopShell._();

  static const _channel = MethodChannel('medut/desktop');
  static const normalSize = Size(1040, 720);
  static const minSize = Size(360, 560);
  static const popupSize = Size(380, 216);

  final mode = ValueNotifier<WindowMode>(WindowMode.normal);

  /// The call screen is in front (over the tabs, or in the wide layout's pane).
  final callOpen = ValueNotifier<bool>(false);

  /// The wide layout's right-hand pane is on screen and shows the call
  /// there, so it is not also laid over the app (HomeShell sets it).
  final paneShowsCall = ValueNotifier<bool>(false);

  late AppSettings _settings;
  late LocalDb _db;
  SipService? _sip;
  final _engine = DesktopEngine.instance;
  final _notes = Platform.isLinux ? LinuxFlutterLocalNotificationsPlugin() : null;
  bool _quitting = false;
  bool _trayUp = false;

  /// Window state before the ringing card replaced it.
  Rect? _savedBounds;
  bool _wasVisible = true, _wasMinimized = false;

  // ── Start-up ──────────────────────────────────────────────────────────────

  /// Before runApp: the window, shown at once unless started at login.
  Future<void> init({required AppSettings settings, required LocalDb db, required bool minimized}) async {
    _settings = settings;
    _db = db;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // The close button reaches Dart either as window_manager's close event or
    // as Flutter's own "may the app exit?" (whichever handler GTK runs first).
    WidgetsBinding.instance.addObserver(this);
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: normalSize, minimumSize: minSize, center: true, title: 'Medut'),
      () async {
        if (minimized && await _hasTray()) return; // started at login: in the tray
        await windowManager.show();
        await windowManager.focus();
      },
    );
    launchAtStartup.setup(appName: 'Medut', appPath: Platform.resolvedExecutable, args: const ['--minimized']);
    _channel.setMethodCallHandler((call) async {
      // A second launch (a link, the menu, the command line) hands its arguments here.
      if (call.method == 'open') await handleArgs([for (final a in call.arguments as List? ?? const []) '$a']);
    });
  }

  /// After SIP has started: the engine's hooks, the tray, notifications.
  Future<void> attach(SipService sip) async {
    _sip = sip;
    final h = _engine.hooks;
    h.ringing = (on) => unawaited(_ringing(on));
    h.showCall = () {
      callOpen.value = true;
      if (mode.value == WindowMode.normal) unawaited(showWindow());
    };
    h.openRoute = (route) {
      callOpen.value = false; // the chat or the Calls tab, not the call over them
      unawaited(showWindow());
      NativeBridge.instance.deliver('openRoute', {'route': route});
    };
    h.missed = (count, latest, title) => unawaited(_notify(_missedId, title, latest, route: 'activity'));
    h.message = (peer, who, body) => unawaited(_notify(_messageId, who, body, route: 'chat:$peer'));
    h.status = (_, _, _) => _scheduleTray();
    h.foreground = () => _focused;
    _db.addListener(_scheduleTray);
    _settings.addListener(_scheduleTray);
    sip.addListener(_scheduleTray);

    await _notes?.initialize(
      settings: const LinuxInitializationSettings(defaultActionName: 'Open'),
      onDidReceiveNotificationResponse: (r) => unawaited(_onNotification(r.actionId, r.payload)),
    );
    try {
      trayManager.addListener(this);
      await _tray();
      _trayUp = true;
    } catch (e) {
      debugPrint('no tray: $e');
    }
  }

  // ── The window ────────────────────────────────────────────────────────────

  bool _focused = true;

  @override
  void onWindowFocus() => _focused = true;

  @override
  void onWindowBlur() => _focused = false;

  @override
  void onWindowClose() => unawaited(_close());

  /// Flutter asks before the window's close button ends the app: only Quit does.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (_quitting) return AppExitResponse.exit;
    await _close();
    return _quitting ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  /// Closing hides to the tray, so calls still ring; with no tray to come
  /// back from (GNOME without the AppIndicator extension), minimise instead.
  Future<void> _close() async {
    if (_quitting) return;
    if (!_settings.closeToTray) return quit();
    if (_trayUp && await _hasTray()) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Unregisters every account, then closes the app (tray › Quit).
  Future<void> quit() async {
    _quitting = true;
    await _notes?.cancelAll();
    await _engine.shutdown();
    if (_trayUp) await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  /// Whether a tray (StatusNotifierItem host) is there to hide into. Windows
  /// always has one; on Linux KDE, Xfce and Cinnamon do, GNOME only with the
  /// AppIndicator extension.
  static Future<bool> _hasTray() async {
    if (!Platform.isLinux) return true;
    try {
      final r = await Process.run('dbus-send', [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.DBus',
        '/org/freedesktop/DBus',
        'org.freedesktop.DBus.NameHasOwner',
        'string:org.kde.StatusNotifierWatcher',
      ]);
      return (r.stdout as String).contains('boolean true');
    } on ProcessException {
      return true; // cannot tell: trust the setting
    }
  }

  // ── Ringing ───────────────────────────────────────────────────────────────

  /// A call rings: in the app if you are looking at it, otherwise in a small
  /// card on top of everything at the bottom corner (and, on Wayland, which
  /// does not let an app put itself on top, a notification with Answer and
  /// Decline). When it stops ringing the window goes back as it was, unless
  /// the call was answered.
  Future<void> _ringing(bool on) {
    // One change of the window at a time, each to where the ringing is now:
    // a call answered or ended while the card was still being put up must
    // not leave the window small or on top.
    _wantRing = on;
    return _ringStep = _ringStep.then((_) => _applyRinging(_wantRing)).catchError((Object e) {
      debugPrint('ringing window: $e');
    });
  }

  bool _wantRing = false;
  Future<void> _ringStep = Future.value();

  Future<void> _applyRinging(bool on) async {
    if (on && mode.value == WindowMode.ringing) return; // already the card
    if (on) {
      callOpen.value = true;
      final visible = await windowManager.isVisible();
      final minimized = await windowManager.isMinimized();
      if (visible && !minimized && _focused) return;
      _wasVisible = visible;
      _wasMinimized = minimized;
      _savedBounds = await windowManager.getBounds();
      mode.value = WindowMode.ringing;
      await windowManager.setMinimumSize(const Size(300, 160));
      if (minimized) await windowManager.restore();
      await windowManager.setSize(popupSize);
      final d = await screenRetriever.getPrimaryDisplay();
      final at = d.visiblePosition ?? Offset.zero;
      final area = d.visibleSize ?? d.size;
      await windowManager.setPosition(Offset(at.dx + area.width - popupSize.width - 16, at.dy + area.height - popupSize.height - 16));
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
      if (Platform.environment['XDG_SESSION_TYPE'] == 'wayland') await _ringNotification();
      return;
    }
    await _notes?.cancel(id: _ringId);
    if (mode.value != WindowMode.ringing) return;
    mode.value = WindowMode.normal;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setMinimumSize(minSize);
    final b = _savedBounds;
    if (b != null) await windowManager.setBounds(b);
    if (_engine.calls.isNotEmpty) {
      await showWindow(); // answered: the call screen, full size
    } else if (!_wasVisible) {
      callOpen.value = false;
      await windowManager.hide();
    } else if (_wasMinimized) {
      callOpen.value = false;
      await windowManager.minimize();
    }
  }

  static const _ringId = 1, _missedId = 2, _messageId = 3;

  Future<void> _ringNotification() async {
    final s = _engine.snapshotNotifier.value;
    final title = '${s['name']}'.isNotEmpty ? '${s['name']}' : '${s['number']}';
    await _notes?.show(
      id: _ringId,
      title: title,
      body: 'incomingCall'.tr(),
      notificationDetails: LinuxNotificationDetails(
        urgency: LinuxNotificationUrgency.critical,
        timeout: const LinuxNotificationTimeout.expiresNever(),
        resident: true,
        suppressSound: true, // the ringtone is ringing
        icon: FilePathLinuxIcon(_iconFile),
        actions: [
          LinuxNotificationAction(key: 'answer', label: 'answer'.tr()),
          LinuxNotificationAction(key: 'decline', label: 'decline'.tr()),
        ],
      ),
      payload: 'ring',
    );
  }

  Future<void> _notify(int id, String title, String body, {required String route}) async {
    if (_notes == null) return; // Windows: the tray shows it
    await _notes.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: LinuxNotificationDetails(icon: FilePathLinuxIcon(_iconFile)),
      payload: route,
    );
  }

  Future<void> _onNotification(String? action, String? payload) async {
    switch (action) {
      case 'answer':
        await _engine.action('answer');
      case 'decline':
        await _engine.action('decline');
      default:
        await showWindow();
        if (payload != null && payload != 'ring') NativeBridge.instance.deliver('openRoute', {'route': payload});
    }
  }

  static String get _iconFile => p.join(p.dirname(Platform.resolvedExecutable), 'data', 'medut.png');

  // ── Links and command lines ───────────────────────────────────────────────

  /// tel:/sip:/callto: links, a number, `--answer`, `--hangup`: from this
  /// launch's command line, or handed over by a second launch.
  Future<void> handleArgs(List<String> args) async {
    final r = LaunchRequest.parse(args);
    if (r.answer) return _engine.action('answer');
    if (r.hangup) {
      for (final c in _engine.calls.toList()) {
        await _engine.hangup(c);
      }
      return;
    }
    if (!r.minimized || r.dial != null) await showWindow();
    final number = r.dial;
    if (number == null) return;
    // Opened by a link at start-up: give the account a moment to register.
    for (var i = 0; i < 20 && !_engine.runtimes.values.any((rt) => rt.status == 'registered'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _sip?.dial(number);
  }

  // ── Start at login ────────────────────────────────────────────────────────

  Future<bool> get startsAtLogin => launchAtStartup.isEnabled();

  Future<void> setStartAtLogin(bool on) => on ? launchAtStartup.enable() : launchAtStartup.disable();

  // ── The tray ──────────────────────────────────────────────────────────────

  Timer? _trayTimer;

  /// Rebuilds the tray menu (the language changed).
  void refreshTray() {
    _lastMenu = '';
    _scheduleTray();
  }

  void _scheduleTray() {
    if (!_trayUp) return;
    _trayTimer?.cancel();
    _trayTimer = Timer(const Duration(milliseconds: 200), () => unawaited(_tray()));
  }

  String _lastIcon = '', _lastMenu = '';

  /// The icon (online, offline, in a call, missed calls), its tooltip and menu.
  Future<void> _tray() async {
    final rts = _engine.runtimes.values.where((r) => !r.probe).toList();
    final up = rts.where((r) => r.status == 'registered').length;
    final missed = await _db.missedSince(_settings.activitySeenAt);
    final inCall = _engine.calls.isNotEmpty;
    final dnd = _settings.effectiveStatus() == MyStatus.dnd;
    final icon = inCall
        ? 'call'
        : up == 0
            ? 'offline'
            : missed > 0
                ? 'missed'
                : 'online';
    final line = inCall
        ? 'trayInCall'.tr()
        : rts.isEmpty
            ? 'noAccount'.tr()
            : up == 0
                ? 'trayOffline'.tr()
                : 'keepAliveOn'.tr(namedArgs: {'n': '$up'});
    final tip = [
      'Medut',
      line,
      if (missed > 0) missed == 1 ? 'missedCall'.tr() : 'missedCalls'.tr(namedArgs: {'n': '$missed'}),
    ].join(' · ');
    if (icon != _lastIcon) {
      _lastIcon = icon;
      // Installed beside flutter_assets (linux/ and windows/ CMakeLists.txt).
      await trayManager.setIcon('../tray/$icon.${Platform.isWindows ? 'ico' : 'png'}');
    }
    final key = '$tip|$dnd|$inCall';
    if (key == _lastMenu) return;
    _lastMenu = key;
    if (!Platform.isLinux) await trayManager.setToolTip(tip);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'trayOpen'.tr()),
      MenuItem(label: line, disabled: true),
      if (missed > 0)
        MenuItem(key: 'missed', label: missed == 1 ? 'missedCall'.tr() : 'missedCalls'.tr(namedArgs: {'n': '$missed'})),
      MenuItem.separator(),
      if (inCall) MenuItem(key: 'hangup', label: 'trayHangUp'.tr()),
      MenuItem.checkbox(key: 'dnd', label: 'statusDnd'.tr(), checked: dnd),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'trayQuit'.tr()),
    ]));
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'missed':
        unawaited(showWindow());
        NativeBridge.instance.deliver('openRoute', {'route': 'activity'});
      case 'hangup':
        for (final c in _engine.calls.toList()) {
          unawaited(_engine.hangup(c));
        }
      case 'dnd':
        _sip?.setMyStatus(_settings.status == MyStatus.dnd ? MyStatus.available : MyStatus.dnd);
      case 'quit':
        unawaited(quit());
    }
  }
}
