import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Finds how a SIP server can be reached before signing in: TLS, TCP, UDP and
/// SIP over secure WebSocket are all checked at the same time. Nothing here
/// sends credentials, so a wrong password is never tried more than once.

/// A way in that answered.
class ProbeHit {
  const ProbeHit(this.transport, {this.url = ''});

  /// tls | tcp | udp | wss
  final String transport;

  /// The wss:// link that accepted the `sip` WebSocket protocol.
  final String url;
}

enum CheckState { running, ok, failed, skipped }

/// What one check found, as a code the UI translates ([detail]) plus a value
/// shown as-is ([extra]: an address, a path).
typedef ProbeListener = void Function(String key, CheckState state, String detail, String extra);

class ProbeReport {
  const ProbeReport({required this.resolved, required this.hits, required this.log});

  /// The server's name resolved to an address.
  final bool resolved;

  /// In the order sign-in should try them: TLS, TCP, UDP, then web link.
  final List<ProbeHit> hits;

  /// One line per check, for the "What happened" log.
  final List<String> log;
}

/// Default ports, shown next to each check.
const probePorts = {'tls': 5061, 'tcp': 5060, 'udp': 5060, 'wss': 443};

/// Where SIP over WebSocket usually lives: Asterisk `/ws` on 8089,
/// FreeSWITCH `/` on 7443, and reverse proxies on 443.
const _wssTargets = [(443, '/ws'), (443, '/sip-ws'), (443, '/'), (8089, '/ws'), (7443, '/'), (8443, '/ws')];

Future<ProbeReport> probeServer(String host,
    {int port = 0, ProbeListener? onStep, Duration timeout = const Duration(seconds: 4)}) async {
  final log = <String>[];
  void step(String key, CheckState s, [String detail = '', String extra = '']) => onStep?.call(key, s, detail, extra);
  for (final k in const ['dns', 'tls', 'tcp', 'udp', 'wss']) {
    step(k, CheckState.running);
  }

  InternetAddress? addr;
  try {
    final all = await InternetAddress.lookup(host).timeout(timeout);
    addr = all.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => all.first);
    step('dns', CheckState.ok, 'found', addr.address);
    log.add('DNS  $host → ${addr.address}');
  } catch (_) {
    step('dns', CheckState.failed, 'notFound');
    log.add('DNS  $host: no address');
  }
  if (addr == null) {
    // SIP DNS (SRV) records may still lead somewhere: the SDK looks those up.
    for (final k in const ['tls', 'tcp', 'udp', 'wss']) {
      step(k, CheckState.skipped);
    }
    return ProbeReport(resolved: false, hits: const [], log: log);
  }

  String portOf(String t) => '${port > 0 ? port : probePorts[t]}';
  Future<ProbeHit?> run(String key, Future<(bool, String, String)> Function() check, ProbeHit hit) async {
    final (ok, detail, extra) = await check();
    step(key, ok ? CheckState.ok : CheckState.failed, detail, extra);
    log.add('${key.toUpperCase().padRight(4)} :${portOf(key)}  ${_words[detail] ?? detail}');
    return ok ? hit : null;
  }

  final a = addr;
  final found = await Future.wait([
    run('tls', () => _tls(host, port > 0 ? port : 5061, timeout), const ProbeHit('tls')),
    run('tcp', () => _tcp(host, port > 0 ? port : 5060, timeout), const ProbeHit('tcp')),
    run('udp', () => _udp(a, host, port > 0 ? port : 5060, timeout), const ProbeHit('udp')),
    _wss(host, port, timeout).then((url) {
      step('wss', url == null ? CheckState.failed : CheckState.ok, url == null ? 'noSip' : 'found',
          url == null ? '' : Uri.parse(url).path);
      log.add('WSS  ${url ?? ':443 :8089 :7443  no SIP at /ws, /sip-ws, /'}');
      return url == null ? null : ProbeHit('wss', url: url);
    }),
  ]);
  return ProbeReport(resolved: true, hits: found.whereType<ProbeHit>().toList(), log: log);
}

const _words = {
  'answered': 'answered',
  'badCert': 'answered, certificate not trusted',
  'noAnswer': 'no answer',
  'refused': 'connection refused',
  'notTls': 'answered, but not with TLS',
};

String _failure(Object e) {
  final m = (e is SocketException ? (e.osError?.message ?? e.message) : '$e').toLowerCase();
  return m.contains('refused') ? 'refused' : 'noAnswer';
}

Future<(bool, String, String)> _tls(String host, int port, Duration timeout) async {
  var badCert = false;
  try {
    final s = await SecureSocket.connect(host, port, timeout: timeout, onBadCertificate: (_) => badCert = true)
        .timeout(timeout);
    s.destroy();
    return (true, badCert ? 'badCert' : 'answered', '');
  } on HandshakeException {
    return (false, 'notTls', '');
  } catch (e) {
    return (false, _failure(e), '');
  }
}

Future<(bool, String, String)> _tcp(String host, int port, Duration timeout) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout).timeout(timeout);
    s.destroy();
    return (true, 'answered', '');
  } catch (e) {
    return (false, _failure(e), '');
  }
}

/// An OPTIONS request: any SIP reply, even an error, means SIP over UDP works.
Future<(bool, String, String)> _udp(InternetAddress addr, String host, int port, Duration timeout) async {
  RawDatagramSocket? s;
  Timer? resend;
  try {
    s = await RawDatagramSocket.bind(
        addr.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
    final sock = s;
    final rnd = Random();
    String hex() => rnd.nextInt(1 << 32).toRadixString(16);
    final msg = utf8.encode('OPTIONS sip:$host SIP/2.0\r\n'
        'Via: SIP/2.0/UDP 0.0.0.0:${sock.port};branch=z9hG4bK${hex()};rport\r\n'
        'Max-Forwards: 70\r\n'
        'From: <sip:probe@$host>;tag=${hex()}\r\n'
        'To: <sip:$host>\r\n'
        'Call-ID: ${hex()}${hex()}\r\n'
        'CSeq: 1 OPTIONS\r\n'
        'User-Agent: Medut\r\n'
        'Content-Length: 0\r\n\r\n');
    final reply = Completer<void>();
    sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d != null && latin1.decode(d.data.take(7).toList()) == 'SIP/2.0' && !reply.isCompleted) reply.complete();
    });
    sock.send(msg, addr, port);
    resend = Timer.periodic(const Duration(seconds: 1), (_) => sock.send(msg, addr, port));
    await reply.future.timeout(timeout);
    return (true, 'answered', '');
  } catch (e) {
    return (false, 'noAnswer', '');
  } finally {
    resend?.cancel();
    s?.close();
  }
}

/// The first wss:// link (in [_wssTargets] order) whose server agrees to the
/// `sip` WebSocket protocol (RFC 7118).
Future<String?> _wss(String host, int port, Duration timeout) async {
  final targets = port > 0 ? [(port, '/ws'), (port, '/sip-ws'), (port, '/')] : _wssTargets;
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..badCertificateCallback = (_, _, _) => true;
  Future<String?> one((int, String) t) async {
    final url = t.$1 == 443 ? 'wss://$host${t.$2}' : 'wss://$host:${t.$1}${t.$2}';
    try {
      final ws = await WebSocket.connect(url, protocols: const ['sip'], customClient: client).timeout(timeout);
      final sip = ws.protocol == 'sip';
      unawaited(ws.close());
      return sip ? url : null;
    } catch (_) {
      return null;
    }
  }

  final urls = await Future.wait(targets.map(one));
  client.close(force: true);
  return urls.whereType<String>().firstOrNull;
}
