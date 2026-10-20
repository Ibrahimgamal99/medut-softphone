import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/accounts.dart';

/// The desktop engine's accounts, passwords included, as one entry in the
/// system keyring (libsecret on Linux, a DPAPI-encrypted file on Windows):
/// what AccountRepository.kt keeps on Android. Entries are
/// [AccountStore.withSecrets] maps.
class DesktopAccountRepo {
  static const _storage = FlutterSecureStorage();
  static const _key = 'medut.desktop.accounts';

  List<Map<String, Object?>> _list = [];

  List<Map<String, Object?>> get raw => _list;

  List<SipAccountConfig> get all => [for (final j in _list) fromRaw(j)];

  static SipAccountConfig fromRaw(Map<String, Object?> j) => SipAccountConfig.fromJson(
        Map<String, dynamic>.from(j),
        password: j['password'] as String? ?? '',
        turnPass: j['turnPass'] as String? ?? '',
      );

  SipAccountConfig? byId(String? id) {
    for (final a in all) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// The enabled one marked default, else the first enabled.
  SipAccountConfig? get defaultAccount {
    final enabled = all.where((a) => a.enabled).toList();
    if (enabled.isEmpty) return null;
    return enabled.firstWhere((a) => a.isDefault, orElse: () => enabled.first);
  }

  Future<void> load() async {
    try {
      final s = await _storage.read(key: _key);
      if (s == null) return;
      _list = [for (final e in jsonDecode(s) as List) Map<String, Object?>.from(e as Map)];
    } catch (e) {
      // No keyring (a bare window manager with no Secret Service): nothing saved.
      debugPrint('desktop accounts unreadable: $e');
    }
  }

  Future<void> replace(List<Map<String, Object?>> list) async {
    _list = list;
    try {
      await _storage.write(key: _key, value: jsonEncode(list));
    } catch (e) {
      debugPrint('desktop accounts not saved: $e');
    }
  }
}
