import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One SIP account as the user configured it. Passwords live in the
/// Keychain / Keystore; everything else in preferences.
@immutable
class SipAccountConfig {
  const SipAccountConfig({
    required this.id,
    required this.name,
    required this.user,
    required this.domain,
    this.password = '',
    this.transport = 'udp',
    this.port = 0,
    this.serverUrl = '',
    this.authUser = '',
    this.displayName = '',
    this.outboundProxy = '',
    this.mediaEnc = 'none',
    this.ice = false,
    this.stun = '',
    this.turn = '',
    this.turnUser = '',
    this.turnPass = '',
    this.codecs = const ['opus', 'alaw', 'ulaw'],
    this.verifyTls = true,
    this.enabled = true,
    this.isDefault = false,
    this.push = true,
    this.dtmf = 'rfc4733',
    this.voicemail = '*97',
    this.recordCalls = true,
  });

  final String id, name, user, domain, password, transport;
  final int port;
  final String serverUrl, authUser, displayName, outboundProxy, mediaEnc;
  final bool ice;
  final String stun, turn, turnUser, turnPass;
  final List<String> codecs;
  final bool verifyTls, enabled, isDefault, push;
  final String dtmf;

  /// What the voicemail button dials (PBX feature code, e.g. *97).
  final String voicemail;

  /// Whether "Record every call" applies to this account.
  final bool recordCalls;

  /// `user@domain[:port]`, as Medut-SDK expects the AOR.
  String get aor => port > 0 ? '$user@$domain:$port' : '$user@$domain';
  String get label => name.isNotEmpty ? name : domain;

  SipAccountConfig copyWith({
    String? name,
    String? user,
    String? domain,
    String? password,
    String? transport,
    int? port,
    String? serverUrl,
    String? authUser,
    String? displayName,
    String? outboundProxy,
    String? mediaEnc,
    bool? ice,
    String? stun,
    String? turn,
    String? turnUser,
    String? turnPass,
    List<String>? codecs,
    bool? verifyTls,
    bool? enabled,
    bool? isDefault,
    bool? push,
    String? dtmf,
    String? voicemail,
    bool? recordCalls,
  }) =>
      SipAccountConfig(
        id: id,
        name: name ?? this.name,
        user: user ?? this.user,
        domain: domain ?? this.domain,
        password: password ?? this.password,
        transport: transport ?? this.transport,
        port: port ?? this.port,
        serverUrl: serverUrl ?? this.serverUrl,
        authUser: authUser ?? this.authUser,
        displayName: displayName ?? this.displayName,
        outboundProxy: outboundProxy ?? this.outboundProxy,
        mediaEnc: mediaEnc ?? this.mediaEnc,
        ice: ice ?? this.ice,
        stun: stun ?? this.stun,
        turn: turn ?? this.turn,
        turnUser: turnUser ?? this.turnUser,
        turnPass: turnPass ?? this.turnPass,
        codecs: codecs ?? this.codecs,
        verifyTls: verifyTls ?? this.verifyTls,
        enabled: enabled ?? this.enabled,
        isDefault: isDefault ?? this.isDefault,
        push: push ?? this.push,
        dtmf: dtmf ?? this.dtmf,
        voicemail: voicemail ?? this.voicemail,
        recordCalls: recordCalls ?? this.recordCalls,
      );

  /// Everything except the password.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'user': user,
        'domain': domain,
        'transport': transport,
        'port': port,
        'serverUrl': serverUrl,
        'authUser': authUser,
        'displayName': displayName,
        'outboundProxy': outboundProxy,
        'mediaEnc': mediaEnc,
        'ice': ice,
        'stun': stun,
        'turn': turn,
        'turnUser': turnUser,
        'codecs': codecs,
        'verifyTls': verifyTls,
        'enabled': enabled,
        'isDefault': isDefault,
        'push': push,
        'dtmf': dtmf,
        'voicemail': voicemail,
        'recordCalls': recordCalls,
      };

  factory SipAccountConfig.fromJson(Map<String, dynamic> j, {String password = '', String turnPass = ''}) =>
      SipAccountConfig(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        user: j['user'] as String? ?? '',
        domain: j['domain'] as String? ?? '',
        password: password,
        transport: j['transport'] as String? ?? 'udp',
        port: (j['port'] as num?)?.toInt() ?? 0,
        serverUrl: j['serverUrl'] as String? ?? '',
        authUser: j['authUser'] as String? ?? '',
        displayName: j['displayName'] as String? ?? '',
        outboundProxy: j['outboundProxy'] as String? ?? '',
        mediaEnc: j['mediaEnc'] as String? ?? 'none',
        ice: j['ice'] as bool? ?? false,
        stun: j['stun'] as String? ?? '',
        turn: j['turn'] as String? ?? '',
        turnUser: j['turnUser'] as String? ?? '',
        turnPass: turnPass,
        codecs: (j['codecs'] as List?)?.cast<String>() ?? const ['opus', 'alaw', 'ulaw'],
        verifyTls: j['verifyTls'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        isDefault: j['isDefault'] as bool? ?? false,
        push: j['push'] as bool? ?? true,
        dtmf: j['dtmf'] as String? ?? 'rfc4733',
        voicemail: j['voicemail'] as String? ?? '*97',
        recordCalls: j['recordCalls'] as bool? ?? true,
      );

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Reads a provisioning payload: a Medut-SDK account JSON (the same shape as
  /// the SDK's `account.json`), or a SIP URI like
  /// `sip:201:secret@pbx.example.com:5061;transport=tls`.
  static SipAccountConfig? parseProvisioning(String raw) {
    final text = raw.trim();
    if (text.startsWith('{')) {
      try {
        final j = jsonDecode(text) as Map<String, dynamic>;
        final uri = (j['uri'] as String? ?? '').replaceFirst(RegExp(r'^sips?:'), '');
        final at = uri.lastIndexOf('@');
        if (at <= 0) return null;
        var host = uri.substring(at + 1);
        var port = 0;
        final colon = host.lastIndexOf(':');
        if (colon > 0) {
          port = int.tryParse(host.substring(colon + 1)) ?? 0;
          host = host.substring(0, colon);
        }
        final codecs = (j['audio_codecs'] as List?)?.cast<String>() ??
            (j['audio_codec'] is String ? [j['audio_codec'] as String] : null);
        return SipAccountConfig(
          id: newId(),
          name: j['name'] as String? ?? j['display_name'] as String? ?? host,
          user: uri.substring(0, at),
          domain: host,
          port: port,
          password: j['password'] as String? ?? '',
          transport: (j['transport'] as String? ?? 'udp').toLowerCase(),
          serverUrl: j['server_url'] as String? ?? '',
          authUser: j['auth_user'] as String? ?? '',
          displayName: j['display_name'] as String? ?? '',
          outboundProxy: j['outbound_proxy'] as String? ?? '',
          mediaEnc: switch (j['media_enc'] as String? ?? 'none') {
            'dtls_srtp' || 'dtls' => 'dtls',
            'sdes' || 'srtp' => 'sdes',
            _ => 'none',
          },
          ice: j['ice_enabled'] as bool? ?? false,
          stun: j['stun_server'] as String? ?? '',
          turn: j['turn_server'] as String? ?? '',
          turnUser: j['turn_user'] as String? ?? '',
          turnPass: j['turn_pass'] as String? ?? '',
          codecs: codecs ?? const ['opus', 'alaw', 'ulaw'],
          verifyTls: j['verify_tls'] as bool? ?? true,
        );
      } catch (_) {
        return null;
      }
    }
    final m = RegExp(r'^sips?:([^:@]+)(?::([^@]*))?@([^:;]+)(?::(\d+))?(.*)$').firstMatch(text);
    if (m == null) return null;
    final params = m.group(5) ?? '';
    final transport = RegExp(r'transport=(\w+)').firstMatch(params)?.group(1)?.toLowerCase() ?? 'udp';
    return SipAccountConfig(
      id: newId(),
      name: m.group(3)!,
      user: Uri.decodeComponent(m.group(1)!),
      password: Uri.decodeComponent(m.group(2) ?? ''),
      domain: m.group(3)!,
      port: int.tryParse(m.group(4) ?? '') ?? 0,
      transport: transport,
    );
  }
}

class AccountStore extends ChangeNotifier {
  AccountStore._(this._prefs);

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final SharedPreferences _prefs;
  List<SipAccountConfig> _accounts = [];

  List<SipAccountConfig> get accounts => List.unmodifiable(_accounts);

  static Future<AccountStore> load() async {
    final s = AccountStore._(await SharedPreferences.getInstance());
    await s._read();
    return s;
  }

  Future<void> _read() async {
    final list = jsonDecode(_prefs.getString('accounts') ?? '[]') as List;
    final out = <SipAccountConfig>[];
    for (final e in list) {
      final j = e as Map<String, dynamic>;
      final id = j['id'] as String;
      out.add(SipAccountConfig.fromJson(
        j,
        password: await _secure.read(key: 'pw_$id') ?? '',
        turnPass: await _secure.read(key: 'turn_$id') ?? '',
      ));
    }
    _accounts = out;
  }

  Future<void> _write() async {
    await _prefs.setString('accounts', jsonEncode(_accounts.map((a) => a.toJson()).toList()));
    notifyListeners();
  }

  SipAccountConfig? byId(String id) {
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  SipAccountConfig? get defaultAccount {
    final enabled = _accounts.where((a) => a.enabled).toList();
    if (enabled.isEmpty) return null;
    return enabled.firstWhere((a) => a.isDefault, orElse: () => enabled.first);
  }

  Future<void> save(SipAccountConfig a) async {
    await _secure.write(key: 'pw_${a.id}', value: a.password);
    await _secure.write(key: 'turn_${a.id}', value: a.turnPass);
    var list = [..._accounts];
    final i = list.indexWhere((x) => x.id == a.id);
    if (a.isDefault) list = list.map((x) => x.isDefault ? x.copyWith(isDefault: false) : x).toList();
    if (i >= 0) {
      list[i] = a;
    } else {
      list.add(list.isEmpty ? a.copyWith(isDefault: true) : a);
    }
    _accounts = list;
    await _write();
  }

  Future<void> remove(String id) async {
    await _secure.delete(key: 'pw_$id');
    await _secure.delete(key: 'turn_$id');
    _accounts = _accounts.where((a) => a.id != id).toList();
    if (_accounts.isNotEmpty && !_accounts.any((a) => a.isDefault)) {
      _accounts = [_accounts.first.copyWith(isDefault: true), ..._accounts.skip(1)];
    }
    await _write();
  }

  Future<void> setEnabled(String id, bool on) async {
    final a = byId(id);
    if (a != null) await save(a.copyWith(enabled: on));
  }
}
