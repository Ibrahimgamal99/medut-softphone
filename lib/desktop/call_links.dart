import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:win32_registry/win32_registry.dart';

/// What the command line asks for: a number to call (from a tel:, sip:,
/// sips: or callto: link, or a bare number), answer / hang up, and whether
/// the app was started at login (stay in the tray).
class LaunchRequest {
  const LaunchRequest({this.dial, this.answer = false, this.hangup = false, this.minimized = false});
  final String? dial;
  final bool answer, hangup, minimized;

  bool get isEmpty => dial == null && !answer && !hangup;

  static LaunchRequest parse(List<String> args) {
    String? dial;
    var answer = false, hangup = false, minimized = false;
    for (final a in args) {
      switch (a) {
        case '--minimized':
          minimized = true;
        case '--answer':
          answer = true;
        case '--hangup':
          hangup = true;
        default:
          dial = target(a) ?? dial;
      }
    }
    return LaunchRequest(dial: dial, answer: answer, hangup: hangup, minimized: minimized);
  }

  /// The number or SIP address in [link]: `tel:+20 100 123`, `callto://201`,
  /// `sip:201@pbx;transport=tls`, or a number typed on the command line.
  static String? target(String link) {
    var s = link.trim();
    final scheme = RegExp(r'^(tel|sips?|callto):(//)?', caseSensitive: false).firstMatch(s);
    if (scheme != null) {
      s = Uri.decodeComponent(s.substring(scheme.end));
      // Parameters and headers are the link's, not the number's.
      s = s.split(RegExp('[;?]')).first;
      if (scheme.group(1)!.toLowerCase() != 'sip' && scheme.group(1)!.toLowerCase() != 'sips') {
        s = s.replaceAll(RegExp(r'[\s\-().]'), '');
      }
      return s.isEmpty ? null : s;
    }
    final bare = s.replaceAll(RegExp(r'[\s\-().]'), '');
    return RegExp(r'^\+?[\d*#]{2,}$').hasMatch(bare) ? bare : null;
  }
}

/// Medut as the app that opens tel:, sip: and callto: links.
///
/// Linux: the .desktop file names the schemes (installed by the package, or
/// written to ~/.local/share/applications for a bundle run from a folder),
/// and xdg-mime makes it their default. Windows: per-user URL protocol keys,
/// plus Capabilities so Medut is listed in Settings › Default apps, where
/// Windows 10 and 11 let only the user make it the default.
class CallLinks {
  CallLinks._();

  static const schemes = ['tel', 'sip', 'sips', 'callto'];
  static const desktopId = 'com.medut.generic.phone.desktop';
  static const _progId = 'Medut.CallLink';

  /// Whether Medut opens sip: links now.
  static Future<bool> isDefault() async {
    try {
      if (Platform.isLinux) {
        final r = await Process.run('xdg-mime', ['query', 'default', 'x-scheme-handler/sip']);
        return (r.stdout as String).trim() == desktopId;
      }
      if (Platform.isWindows) {
        final choice = _read(r'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\sip\UserChoice', 'ProgId');
        if (choice != null) return choice == _progId;
        return _read(r'Software\Classes\sip\shell\open\command', '')?.contains(Platform.resolvedExecutable) ?? false;
      }
    } catch (_) {}
    return false;
  }

  /// Registers the schemes; true when Medut is now the default. On Windows
  /// the user still confirms in Settings, which this opens.
  static Future<bool> makeDefault() async {
    if (Platform.isLinux) {
      await _linuxDesktopFile();
      for (final s in schemes) {
        await Process.run('xdg-mime', ['default', desktopId, 'x-scheme-handler/$s']);
      }
      return isDefault();
    }
    if (Platform.isWindows) {
      _windowsKeys();
      await Process.start('explorer.exe', ['ms-settings:defaultapps?registeredAppUser=Medut']);
      return isDefault();
    }
    return false;
  }

  /// Writes a per-user .desktop file unless the package installed one.
  static Future<void> _linuxDesktopFile() async {
    final system = ['/usr/share/applications', '/usr/local/share/applications'];
    if (system.any((d) => File(p.join(d, desktopId)).existsSync())) return;
    final home = Platform.environment['XDG_DATA_HOME'] ?? p.join(Platform.environment['HOME'] ?? '', '.local', 'share');
    final dir = Directory(p.join(home, 'applications'));
    await dir.create(recursive: true);
    final exe = Platform.resolvedExecutable;
    final icon = p.join(p.dirname(exe), 'data', 'medut.png');
    await File(p.join(dir.path, desktopId)).writeAsString(desktopEntry(exe: '"$exe"', icon: icon));
    try {
      await Process.run('update-desktop-database', [dir.path]);
    } on ProcessException {
      // xdg-mime reads the file without the cache too
    }
  }

  /// The .desktop entry; linux/com.medut.generic.phone.desktop is the same for packages.
  static String desktopEntry({required String exe, required String icon}) => '''
[Desktop Entry]
Type=Application
Name=Medut
GenericName=Softphone
Comment=Calls over your SIP PBX
Exec=$exe %u
Icon=$icon
Terminal=false
Categories=Network;Telephony;
MimeType=${schemes.map((s) => 'x-scheme-handler/$s;').join()}
StartupWMClass=com.medut.generic.phone
StartupNotify=true
''';

  static void _windowsKeys() {
    final exe = Platform.resolvedExecutable;
    final command = '"$exe" "%1"';
    final hkcu = Registry.currentUser;
    try {
      // The handler, by ProgId, for Default apps.
      final prog = hkcu.createKey('Software\\Classes\\$_progId');
      prog.createValue(const RegistryValue.string('', 'Medut call link'));
      prog.createValue(const RegistryValue.string('URL Protocol', ''));
      prog.createKey('DefaultIcon').createValue(RegistryValue.string('', '"$exe",0'));
      prog.createKey(r'shell\open\command').createValue(RegistryValue.string('', command));
      // Each scheme, for browsers that look it up directly.
      for (final s in schemes) {
        final k = hkcu.createKey('Software\\Classes\\$s');
        k.createValue(RegistryValue.string('', 'URL:$s'));
        k.createValue(const RegistryValue.string('URL Protocol', ''));
        k.createKey('DefaultIcon').createValue(RegistryValue.string('', '"$exe",0'));
        k.createKey(r'shell\open\command').createValue(RegistryValue.string('', command));
      }
      final caps = hkcu.createKey(r'Software\Medut\Capabilities');
      caps.createValue(const RegistryValue.string('ApplicationName', 'Medut'));
      caps.createValue(const RegistryValue.string('ApplicationDescription', 'Calls over your SIP PBX'));
      final urls = caps.createKey('URLAssociations');
      for (final s in schemes) {
        urls.createValue(RegistryValue.string(s, _progId));
      }
      hkcu
          .createKey(r'Software\RegisteredApplications')
          .createValue(const RegistryValue.string('Medut', r'Software\Medut\Capabilities'));
    } finally {
      hkcu.close();
    }
  }

  static String? _read(String path, String value) {
    try {
      final k = Registry.openPath(RegistryHive.currentUser, path: path);
      try {
        return k.getStringValue(value);
      } finally {
        k.close();
      }
    } catch (_) {
      return null;
    }
  }
}
