// Who is on the phone system. Medut works with any SIP server, and SIP has
// no directory, so extensions are learned: from calls, from phone contacts
// saved with one, and from the few typed in by hand.

String _compact(String number) => number.replaceAll(RegExp(r'[\s\-().]'), '');

/// An extension on the phone system: 2–6 digits. Anything longer is an
/// outside number.
bool isExtension(String number) => RegExp(r'^\d{2,6}$').hasMatch(_compact(number));

/// The extensions to follow presence for, in this order: favourites and
/// hand-added ones always, then up to [cap] more, the most recent from calls
/// first, then phone contacts saved with an extension. Hidden ones are left
/// out, and so is anything that is not an extension.
List<String> presenceTargets({
  required Iterable<String> favourites,
  required Iterable<String> watched,
  required Iterable<String> recent,
  required Iterable<String> contacts,
  Set<String> hidden = const {},
  int cap = 30,
}) {
  final out = <String>[];
  bool add(String n) {
    final e = _compact(n);
    if (!isExtension(e) || hidden.contains(e) || out.contains(e)) return false;
    out.add(e);
    return true;
  }

  favourites.forEach(add);
  watched.forEach(add);
  var more = 0;
  for (final n in [...recent, ...contacts]) {
    if (more >= cap) break;
    if (add(n)) more++;
  }
  return out;
}

/// The same phone number however it is written: compared on the last nine
/// digits, so +20 100… and 0100… match, and spaces or dashes don't matter.
bool sameNumber(String a, String b) {
  String tail(String n) {
    final d = n.replaceAll(RegExp(r'\D'), '');
    return d.length > 9 ? d.substring(d.length - 9) : d;
  }

  final x = tail(a);
  return x.isNotEmpty && x == tail(b);
}

/// Text in any of [fields]; a number typed with spaces, dashes or brackets
/// matches on its digits.
bool matchesQuery(String query, List<String> fields) {
  final q = query.toLowerCase();
  final digits = RegExp(r'^[\d\s\-+().]+$').hasMatch(q) ? q.replaceAll(RegExp(r'\D'), '') : '';
  return fields.any((f) => f.toLowerCase().contains(q) || (digits.isNotEmpty && f.replaceAll(RegExp(r'\D'), '').contains(digits)));
}
