import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/desktop/call_links.dart';
import 'package:medut_phone/desktop/contact_import.dart';
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

  group('contacts import', () {
    test('vCard 3 from Google: folded lines, grouped TEL, escapes', () {
      const vcf = 'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Sara Ahmed\\, Sales\r\nN:Ahmed;Sara;;;\r\n'
          'item1.TEL;TYPE=CELL:+20 100 123\r\n 4567\r\nTEL;TYPE=WORK:201\r\nEND:VCARD\r\n'
          'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Phone\r\nEMAIL:x@y.z\r\nEND:VCARD\r\n';
      final c = parseContactsFile(vcf);
      expect(c, hasLength(1));
      expect(c.single.name, 'Sara Ahmed, Sales');
      expect(c.single.numbers, ['+201001234567', '201']);
    });

    test('vCard 2.1 with only N, and a tel: URI', () {
      final c = parseContactsFile('BEGIN:VCARD\nVERSION:2.1\nN:Hassan;Omar\nTEL;VALUE=uri:tel:+44-20-7946-0958\nEND:VCARD\n');
      expect(c.single.name, 'Omar Hassan');
      expect(c.single.numbers, ['+442079460958']);
    });

    test('Google CSV: name parts and several numbers in one cell', () {
      const csv = 'First Name,Middle Name,Last Name,Phone 1 - Label,Phone 1 - Value\n'
          'Mona,,Ali,Mobile,"+20 122 000 1111 ::: 0100 222 3333"\n'
          'Empty,,Row,,\n';
      final c = parseContactsFile(csv);
      expect(c.single.name, 'Mona Ali');
      expect(c.single.numbers, ['+201220001111', '01002223333']);
    });

    test('Outlook CSV, and Excel semicolons', () {
      final outlook = parseContactsFile('"First Name","Last Name","Company","Mobile Phone","Business Phone"\n'
          '"","","Acme Ltd","","(02) 2345-6789"\n');
      expect(outlook.single.name, 'Acme Ltd');
      expect(outlook.single.numbers, ['0223456789']);
      final excel = parseContactsFile('Name;Phone\nKarim;105\n');
      expect(excel.single.name, 'Karim');
      expect(excel.single.numbers, ['105']);
    });

    test('a file that is neither', () {
      expect(parseContactsFile('hello world'), isEmpty);
    });
  });
}
