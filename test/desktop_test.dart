import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/desktop/call_links.dart';
import 'package:medut_phone/desktop/engine_config.dart';
import 'package:medut_phone/desktop/engine_log.dart';

void main() {
  group('call links', () {
    test('tel: drops the spacing and the parameters', () {
      expect(LaunchRequest.target('tel:+20%20100%20123-4567'), '+201001234567');
      expect(LaunchRequest.target('tel:201;phone-context=example.com'), '201');
    });

    test('callto: with or without slashes', () {
      expect(LaunchRequest.target('callto://201'), '201');
      expect(LaunchRequest.target('callto:0100 123 4567'), '01001234567');
    });

    test('sip: keeps the address, not its parameters or headers', () {
      expect(LaunchRequest.target('sip:201@pbx.example.com;transport=tls'), '201@pbx.example.com');
      expect(LaunchRequest.target('sips:sara@pbx.example.com?subject=hi'), 'sara@pbx.example.com');
    });

    test('a bare number from the command line, not any word', () {
      expect(LaunchRequest.target('+20 100 123 4567'), '+201001234567');
      expect(LaunchRequest.target('*45'), '*45');
      expect(LaunchRequest.target('--verbose'), isNull);
      expect(LaunchRequest.target('hello'), isNull);
    });

    test('flags', () {
      final r = LaunchRequest.parse(['--minimized']);
      expect(r.minimized, isTrue);
      expect(r.isEmpty, isTrue);
      expect(LaunchRequest.parse(['--answer']).answer, isTrue);
      expect(LaunchRequest.parse(['tel:201']).dial, '201');
    });
  });

  group('engine config', () {
    test('dial rules: X is a digit, otherwise a prefix', () {
      expect(const DialRule('9', 'a').matches('9 0100'), isTrue);
      expect(const DialRule('2XX', 'a').matches('201'), isTrue);
      expect(const DialRule('2XX', 'a').matches('2010'), isFalse);
      expect(const DialRule('2XX', 'a').matches('3a1'), isFalse);
    });

    test('office hours: Do not disturb outside them', () {
      const c = EngineConfig({'officeHours': true, 'officeDays': '1,2,3,4,5', 'officeStart': '09:00', 'officeEnd': '17:00'});
      expect(c.effectiveStatus(DateTime(2026, 10, 19, 10)), 'available'); // Monday
      expect(c.effectiveStatus(DateTime(2026, 10, 19, 18)), 'dnd');
      expect(c.effectiveStatus(DateTime(2026, 10, 18, 10)), 'dnd'); // Sunday
    });

    test('labels fill their placeholders, and fall back to English', () {
      const c = EngineConfig({'labels': {'missedCalls': '{n} appels manqués'}});
      expect(c.label('missedCalls', '{n} missed calls', {'n': '3'}), '3 appels manqués');
      expect(c.label('noAccount', 'Add a SIP account first'), 'Add a SIP account first');
    });
  });

  test('engine log hands out only the lines not seen yet', () {
    final start = EngineLog.seq('conn');
    EngineLog.conn('one');
    EngineLog.conn('two');
    final r = EngineLog.read('conn', start + 1);
    expect(r['reset'], isFalse);
    expect((r['lines'] as List).single, endsWith('two'));
    expect(EngineLog.read('conn', 0)['reset'], isTrue);
  });
}
