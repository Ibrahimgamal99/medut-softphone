import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/core/people.dart';

void main() {
  test('an extension is 2 to 6 digits', () {
    for (final n in ['21', '214', '2 14', '20-1', '123456']) {
      expect(isExtension(n), isTrue, reason: n);
    }
    for (final n in ['1', '1234567', '01001112233', '+20100', '*97', 'sara', '']) {
      expect(isExtension(n), isFalse, reason: n);
    }
  });

  test('presence follows favourites and hand-added ones, then the most recent up to the cap', () {
    final targets = presenceTargets(
      favourites: {'214', '01001112233'},
      watched: ['230'],
      recent: ['220', '01009876543', '214', '221', '222'],
      contacts: ['240', '0100 555 0000'],
      hidden: {'221'},
      cap: 2,
    );
    // Mobile numbers and hidden extensions are left out; 214 is not counted twice.
    expect(targets, ['214', '230', '220', '222']);
  });

  test('contacts saved with an extension fill the cap after recent calls', () {
    expect(presenceTargets(favourites: const {}, watched: const [], recent: ['220'], contacts: ['2 40', '250']),
        ['220', '240', '250']);
  });

  test('the same number however it is written', () {
    expect(sameNumber('+20 100 111 2233', '01001112233'), isTrue);
    expect(sameNumber('214', '214'), isTrue);
    expect(sameNumber('214', '215'), isFalse);
    expect(sameNumber('', ''), isFalse);
  });

  test('search matches names, and numbers on their digits', () {
    expect(matchesQuery('sara', ['Sara Adel', '214']), isTrue);
    expect(matchesQuery('0100-111', ['', '01001112233']), isTrue);
    expect(matchesQuery('omar', ['Sara Adel', '214']), isFalse);
  });
}
