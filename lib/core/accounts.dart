import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sip/native_bridge.dart';

/// Filled in when ICE is turned on and no STUN server is set.
const kDefaultStun = 'stun:stun.l.google.com:19302';

/// Every codec Medut-SDK builds, in the default order: G.711 first, which
/// most PBXs and trunks speak without transcoding.
const kCodecs = ['alaw', 'ulaw', 'opus'];

/// `PCMA · PCMU · Opus` for a codec list.
String codecNames(List<String> codecs) =>
    codecs.map((c) => switch (c) { 'alaw' => 'PCMA', 'ulaw' => 'PCMU', _ => 'Opus' }).join(' · ');

/// The status feature codes a status change dials, by key.
const kStatusCodeKeys = ['dndOn', 'dndOff', 'queueLogin', 'queueLogout'];

/// Feature codes as each PBX ships them (all editable per account):
/// FreePBX and Issabel (Asterisk) DND *78 / *79, queue toggle *45;
/// FusionPBX (FreeSWITCH) DND *78 / *79, call-center agent toggle *22;
/// 3CX queue log in *62 / out *63 (no DND code by default).
const kPbxPresets = <String, Map<String, String>>{
  'freepbx': {'dndOn': '*78', 'dndOff': '*79', 'queueLogin': '*45', 'queueLogout': '*45'},
  'fusionpbx': {'dndOn': '*78', 'dndOff': '*79', 'queueLogin': '*22', 'queueLogout': '*22'},
  '3cx': {'dndOn': '', 'dndOff': '', 'queueLogin': '*62', 'queueLogout': '*63'},
  'custom': {'dndOn': '', 'dndOff': '', 'queueLogin': '', 'queueLogout': ''},
};

/// One SIP account as the user configured it. The native engine keeps it,
/// passwords included, encrypted (see [AccountStore]).
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
    this.verifyTls = true,
    this.enabled = true,
    this.isDefault = false,
    this.push = true,
    this.dtmf = 'rfc4733',
    this.voicemail = '*97',
    this.recordCalls = true,
    this.dialPrefix = '',
    this.plusReplace = '',
    this.headers = '',
    this.pbx = 'freepbx',
    this.codes = const {},
  });

  final String id, name, user, domain, password, transport;
  final int port;
  final String serverUrl, authUser, displayName, outboundProxy, mediaEnc;
  final bool ice;
  final String stun, turn, turnUser, turnPass;
  final bool verifyTls, enabled, isDefault, push;
  final String dtmf;

  /// What the voicemail button dials (PBX feature code, e.g. *97).
  final String voicemail;

  /// Whether "Record every call" applies to this account.
  final bool recordCalls;

  /// Added in front of outside numbers (7+ digits), e.g. 9 for a line out.
  final String dialPrefix;

  /// What a leading + becomes (e.g. 00); empty keeps the +.
  final String plusReplace;

  /// Extra SIP headers on this account's requests, one "Name: value" per line.
  final String headers;

  /// Which PBX this is (a key of [kPbxPresets]): it fills [codes].
  final String pbx;

  /// Status feature codes set on this account, by [kStatusCodeKeys] key;
  /// a key not set here takes the [pbx] preset's code.
  final Map<String, String> codes;

  /// The code to dial for [key] ('' = this PBX has none).
  String code(String key) => codes[key] ?? kPbxPresets[pbx]?[key] ?? '';

  /// The codecs this account offers, in order: the app-wide [order], except
  /// that a web link (a WebRTC server) puts Opus first.
  List<String> codecsFrom(List<String> order) =>
      transport == 'ws' || transport == 'wss' ? ['opus', ...order.where((c) => c != 'opus')] : order;

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
    bool? verifyTls,
    bool? enabled,
    bool? isDefault,
    bool? push,
    String? dtmf,
    String? voicemail,
    bool? recordCalls,
    String? dialPrefix,
    String? plusReplace,
    String? headers,
    String? pbx,
    Map<String, String>? codes,
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
        verifyTls: verifyTls ?? this.verifyTls,
        enabled: enabled ?? this.enabled,
        isDefault: isDefault ?? this.isDefault,
        push: push ?? this.push,
        dtmf: dtmf ?? this.dtmf,
        voicemail: voicemail ?? this.voicemail,
        recordCalls: recordCalls ?? this.recordCalls,
        dialPrefix: dialPrefix ?? this.dialPrefix,
        plusReplace: plusReplace ?? this.plusReplace,
        headers: headers ?? this.headers,
        pbx: pbx ?? this.pbx,
        codes: codes ?? this.codes,
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
        'verifyTls': verifyTls,
        'enabled': enabled,
        'isDefault': isDefault,
        'push': push,
        'dtmf': dtmf,
        'voicemail': voicemail,
        'recordCalls': recordCalls,
        'dialPrefix': dialPrefix,
        'plusReplace': plusReplace,
        'headers': headers,
        'pbx': pbx,
        'codes': codes,
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
        verifyTls: j['verifyTls'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        isDefault: j['isDefault'] as bool? ?? false,
        push: j['push'] as bool? ?? true,
        dtmf: j['dtmf'] as String? ?? 'rfc4733',
        voicemail: j['voicemail'] as String? ?? '*97',
        recordCalls: j['recordCalls'] as bool? ?? true,
        dialPrefix: j['dialPrefix'] as String? ?? '',
        plusReplace: j['plusReplace'] as String? ?? '',
        headers: j['headers'] as String? ?? '',
        pbx: j['pbx'] as String? ?? 'freepbx',
        codes: (j['codes'] as Map?)?.cast<String, String>() ?? const {},
      );

  /// The provisioning JSON (Medut-SDK account format) for sharing this
  /// account as a QR code. Includes the password.
  String toProvisioning() => jsonEncode({
        'name': name,
        'uri': aor,
        'password': password,
        'display_name': displayName,
        'transport': transport,
        if (serverUrl.isNotEmpty) 'server_url': serverUrl,
        if (authUser.isNotEmpty) 'auth_user': authUser,
        if (outboundProxy.isNotEmpty) 'outbound_proxy': outboundProxy,
        'media_enc': switch (mediaEnc) { 'dtls' => 'dtls_srtp', 'sdes' => 'sdes', _ => 'none' },
        'ice_enabled': ice,
        if (stun.isNotEmpty) 'stun_server': stun,
        if (turn.isNotEmpty) 'turn_server': turn,
        if (turnUser.isNotEmpty) 'turn_user': turnUser,
        if (turnPass.isNotEmpty) 'turn_pass': turnPass,
        'verify_tls': verifyTls,
      });

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// `pbx.example.com:5070` → (pbx.example.com, 5070); no port → 0. A
  /// bracketed IPv6 address keeps its colons. Null when what follows the
  /// colon is not a port (1–65535).
  static ({String host, int port})? splitHostPort(String s) {
    final m = RegExp(r'^(\[[^\]]*\]|[^:]*):([^:]*)$').firstMatch(s);
    if (m == null) return (host: s, port: 0);
    final port = int.tryParse(m.group(2)!) ?? 0;
    if (port < 1 || port > 65535) return null;
    return (host: m.group(1)!, port: port);
  }

  /// Reads a provisioning payload: a Medut-SDK account JSON (the same shape as
  /// the SDK's `account.json`), or a SIP URI like
  /// `sip:201:secret@pbx.example.com:5061;transport=tls`. Its `audio_codecs`
  /// is ignored: the codec order is app-wide ([codecsFrom]).
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

/// The saved accounts. The native engine keeps them (encrypted, passwords
/// included), so it can register them after a push or a reboot with no
/// Flutter running; this reads and replaces the list over the channel. The
/// first run after the move brings the accounts over from the old store
/// (preferences + secure storage). With no native side (tests) it keeps
/// using that old store.
class AccountStore extends ChangeNotifier {
  AccountStore._(this._prefs);

  static const _legacySecure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final SharedPreferences _prefs;
  List<SipAccountConfig> _accounts = [];
  bool _native = false;

  List<SipAccountConfig> get accounts => List.unmodifiable(_accounts);

  static Future<AccountStore> load() async {
    final s = AccountStore._(await SharedPreferences.getInstance());
    await s._read();
    return s;
  }

  /// What native keeps for [a]: [SipAccountConfig.toJson] plus the secrets.
  static Map<String, dynamic> withSecrets(SipAccountConfig a) =>
      {...a.toJson(), 'password': a.password, 'turnPass': a.turnPass};

  static SipAccountConfig _fromNative(Map<String, dynamic> j) => SipAccountConfig.fromJson(
        j,
        password: j['password'] as String? ?? '',
        turnPass: j['turnPass'] as String? ?? '',
      );

  Future<void> _read() async {
    final native = await NativeBridge.instance.getAccounts();
    _native = native != null;
    if (native == null) {
      _accounts = await _readLegacy();
      return;
    }
    if (native.isEmpty && _prefs.containsKey('accounts')) {
      final legacy = await _readLegacy();
      if (legacy.isEmpty || await NativeBridge.instance.setAccounts(legacy.map(withSecrets).toList())) {
        await _clearLegacy(legacy);
      }
      _accounts = legacy;
      return;
    }
    _accounts = native.map(_fromNative).toList();
  }

  Future<List<SipAccountConfig>> _readLegacy() async {
    final list = jsonDecode(_prefs.getString('accounts') ?? '[]') as List;
    final out = <SipAccountConfig>[];
    for (final e in list) {
      final j = e as Map<String, dynamic>;
      final id = j['id'] as String;
      out.add(SipAccountConfig.fromJson(
        j,
        password: await _legacySecure.read(key: 'pw_$id') ?? '',
        turnPass: await _legacySecure.read(key: 'turn_$id') ?? '',
      ));
    }
    return out;
  }

  Future<void> _clearLegacy(List<SipAccountConfig> moved) async {
    for (final a in moved) {
      await _legacySecure.delete(key: 'pw_${a.id}');
      await _legacySecure.delete(key: 'turn_${a.id}');
    }
    await _prefs.remove('accounts');
  }

  Future<void> _write() async {
    if (_native) {
      await sync();
    } else {
      for (final a in _accounts) {
        await _legacySecure.write(key: 'pw_${a.id}', value: a.password);
        await _legacySecure.write(key: 'turn_${a.id}', value: a.turnPass);
      }
      await _prefs.setString('accounts', jsonEncode(_accounts.map((a) => a.toJson()).toList()));
    }
    notifyListeners();
  }

  /// Hands native the saved list again; it re-registers what changed.
  Future<void> sync() async {
    if (_native) await NativeBridge.instance.setAccounts(_accounts.map(withSecrets).toList());
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
    if (!_native) {
      await _legacySecure.delete(key: 'pw_$id');
      await _legacySecure.delete(key: 'turn_$id');
    }
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
