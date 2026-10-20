import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../desktop/call_view.dart';
import '../desktop/desktop_shell.dart';
import '../desktop/platform.dart';
import '../sip/native_bridge.dart';
import '../sip/sip_service.dart';
import 'activity.dart';
import 'chat.dart';
import 'dialer.dart';
import 'contacts_screen.dart';
import 'settings_screen.dart';

/// Bottom tabs (Calls · Contacts · Settings), the dial button that opens the
/// keypad over Calls and Contacts, and the bar that returns to a call running
/// on the native screen. A wide desktop window has the tabs down the side
/// and the keypad, or the call, in a pane on the right.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0; // Calls
  final _addCallMode = ValueNotifier<bool>(false);
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    final sip = ref.read(sipProvider);
    _subs.add(sip.notices.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }));
    _subs.add(NativeBridge.instance.routes.listen(_openRoute));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    if (isDesktop) DesktopShell.instance.paneShowsCall.value = false;
    super.dispose();
  }

  void _selectTab(int i) {
    setState(() => _tab = i);
    if (i == 0) {
      ref.read(settingsProvider).activitySeenAt = DateTime.now();
      ref.read(sipProvider).missedSeen();
    }
  }

  /// Tells the desktop frame whether the call is in this pane (wide, and no
  /// page pushed over the tabs) or must be laid over the app.
  void _paneShowsCall(bool on) {
    final pane = DesktopShell.instance.paneShowsCall;
    if (pane.value == on) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => pane.value = on);
  }

  static const _wideFrom = 900.0;

  /// A notification or the native call screen hands over to Flutter for
  /// these flows (Transfer and Add call stay on the call screen).
  void _openRoute(String route) {
    if (!mounted) return;
    final sip = ref.read(sipProvider);
    switch (route) {
      case final r when r.startsWith('chat:'):
        final peer = r.substring(5);
        final name = sip.nameFor(peer);
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: peer, title: name.isNotEmpty ? name : peer)));
      case 'activity':
        setState(() => _tab = 0);
        ref.read(settingsProvider).activitySeenAt = DateTime.now();
        sip.missedSeen();
    }
  }

  /// The keypad, full screen over the tabs.
  void _openKeypad() {
    _addCallMode.value = false;
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => KeypadPage(addCallMode: _addCallMode),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return _narrow(context);
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= _wideFrom;
      _paneShowsCall(wide && current && ref.read(sipProvider).hasCall);
      return wide ? _wide(context) : _narrow(context);
    });
  }

  /// Desktop, wide: the tabs on a rail, the tab, and the keypad or the call.
  Widget _wide(BuildContext context) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    return Scaffold(
      body: SafeArea(
        child: Row(children: [
          _SideNav(index: _tab, onTap: _selectTab, tokens: t),
          VerticalDivider(width: 1, color: t.border),
          Expanded(
            child: IndexedStack(index: _tab, children: const [
              ActivityScreen(),
              ContactsScreen(),
              SettingsScreen(),
            ]),
          ),
          VerticalDivider(width: 1, color: t.border),
          SizedBox(
            width: 400,
            child: sip.hasCall
                ? const DesktopCallView(embedded: true)
                : DialerScreen(addCallMode: _addCallMode),
          ),
        ]),
      ),
    );
  }

  Widget _narrow(BuildContext context) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    return Scaffold(
      floatingActionButton: _tab < 2
          ? FloatingActionButton(
              tooltip: 'tabKeypad'.tr(),
              onPressed: _openKeypad,
              backgroundColor: t.accent,
              foregroundColor: t.onAccent,
              shape: const CircleBorder(),
              child: const Icon(Icons.dialpad),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          if (sip.hasCall) _ReturnToCallBar(sip: sip),
          Expanded(
            child: IndexedStack(index: _tab, children: const [
              ActivityScreen(),
              ContactsScreen(),
              SettingsScreen(),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: _BottomNav(index: _tab, onTap: _selectTab, tokens: t),
    );
  }
}

class _ReturnToCallBar extends StatefulWidget {
  const _ReturnToCallBar({required this.sip});
  final SipService sip;

  @override
  State<_ReturnToCallBar> createState() => _ReturnToCallBarState();
}

class _ReturnToCallBarState extends State<_ReturnToCallBar> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final call = widget.sip.focused ?? widget.sip.calls.first;
    final since = call.answeredAt;
    final d = since == null ? null : DateTime.now().difference(since);
    final time = d == null ? '' : ' · ${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    return Material(
      color: t.success,
      child: InkWell(
        onTap: widget.sip.openCallScreen,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Icon(Icons.call, size: 18, color: t.onSuccess),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${call.title}$time',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.onSuccess, fontWeight: FontWeight.w700)),
            ),
            Text('returnToCall'.tr(), style: TextStyle(color: t.onSuccess, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class _BottomNav extends ConsumerWidget {
  const _BottomNav({required this.index, required this.onTap, required this.tokens});
  final int index;
  final ValueChanged<int> onTap;
  final Tokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tokens;
    final db = ref.watch(dbProvider);
    final seen = ref.watch(settingsProvider).activitySeenAt;
    final items = _navItems();
    return Container(
      color: t.nav,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: Semantics(
                  selected: i == index,
                  button: true,
                  child: InkWell(
                    onTap: () => onTap(i),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Stack(clipBehavior: Clip.none, children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 56,
                            height: 30,
                            decoration: BoxDecoration(
                              color: i == index ? t.accentSoft : Colors.transparent,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(items[i].$1, size: 21, color: i == index ? t.accentText : t.text2),
                          ),
                          if (i == 0)
                            FutureBuilder<int>(
                              future: _navBadge(db, seen),
                              builder: (_, s) => (s.data ?? 0) == 0
                                  ? const SizedBox.shrink()
                                  : PositionedDirectional(
                                      top: -4,
                                      end: 4,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5),
                                        decoration: BoxDecoration(color: t.missed, borderRadius: BorderRadius.circular(9)),
                                        child: Text('${s.data}',
                                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                                      ),
                                    ),
                            ),
                        ]),
                        const SizedBox(height: 3),
                        Text(items[i].$2,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                                color: i == index ? t.accentText : t.text2)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The Calls tab's badge: missed calls since you last looked, and unread messages.
Future<int> _navBadge(LocalDb db, DateTime seen) async => await db.missedSince(seen) + await db.unreadCount();

List<(IconData, String)> _navItems() => [
      (Icons.schedule, 'tabCalls'.tr()),
      (Icons.people_outline, 'tabContacts'.tr()),
      (Icons.settings_outlined, 'settings'.tr()),
    ];

/// The tabs down the side of a wide desktop window.
class _SideNav extends ConsumerWidget {
  const _SideNav({required this.index, required this.onTap, required this.tokens});
  final int index;
  final ValueChanged<int> onTap;
  final Tokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tokens;
    final db = ref.watch(dbProvider);
    final seen = ref.watch(settingsProvider).activitySeenAt;
    final items = _navItems();
    return Container(
      width: 88,
      color: t.nav,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(children: [
        for (var i = 0; i < items.length; i++)
          Semantics(
            selected: i == index,
            button: true,
            child: InkWell(
              onTap: () => onTap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(children: [
                  Stack(clipBehavior: Clip.none, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 56,
                      height: 32,
                      decoration: BoxDecoration(
                        color: i == index ? t.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(items[i].$1, size: 22, color: i == index ? t.accentText : t.text2),
                    ),
                    if (i == 0)
                      FutureBuilder<int>(
                        future: _navBadge(db, seen),
                        builder: (_, s) => (s.data ?? 0) == 0
                            ? const SizedBox.shrink()
                            : PositionedDirectional(
                                top: -4,
                                end: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5),
                                  decoration: BoxDecoration(color: t.missed, borderRadius: BorderRadius.circular(9)),
                                  child: Text('${s.data}',
                                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                                ),
                              ),
                      ),
                  ]),
                  const SizedBox(height: 4),
                  Text(items[i].$2,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                          color: i == index ? t.accentText : t.text2)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
