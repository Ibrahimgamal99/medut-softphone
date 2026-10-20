import '../core/contacts.dart';

/// People and their numbers from an exported address book: vCard (.vcf, any
/// version) or the CSV that Google Contacts, Outlook and Thunderbird write.
/// Entries without a phone number are left out.
List<PhoneContact> parseContactsFile(String text) {
  final t = text.replaceFirst('﻿', '');
  return RegExp(r'^\s*BEGIN:VCARD', caseSensitive: false, multiLine: true).hasMatch(t) ? _vcards(t) : _csv(t);
}

// ── vCard ───────────────────────────────────────────────────────────────────

List<PhoneContact> _vcards(String text) {
  // Unfold: a line that starts with a space or a tab continues the one before.
  final lines = text.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n[ \t]'), '').split('\n');
  final out = <PhoneContact>[];
  String fn = '', n = '', org = '';
  var tels = <String>[];
  var inCard = false;
  for (final raw in lines) {
    final line = raw.trimRight();
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    // "item1.TEL;TYPE=CELL" → "TEL"
    final key = line.substring(0, colon).split(';').first.split('.').last.toUpperCase();
    final value = line.substring(colon + 1);
    switch (key) {
      case 'BEGIN' when value.toUpperCase() == 'VCARD':
        inCard = true;
        fn = n = org = '';
        tels = [];
      case 'END' when value.toUpperCase() == 'VCARD' && inCard:
        inCard = false;
        final name = fn.isNotEmpty ? fn : (n.isNotEmpty ? n : org);
        final numbers = tels.where((x) => x.isNotEmpty).toSet().toList();
        if (numbers.isNotEmpty) out.add(PhoneContact(name.isEmpty ? numbers.first : name, numbers));
      case 'FN':
        fn = _unescape(value).trim();
      case 'N':
        // Family;Given;Middle;Prefix;Suffix → "Given Middle Family"
        final p = value.split(';').map(_unescape).toList();
        n = [if (p.length > 1) p[1], if (p.length > 2) p[2], p[0]].where((x) => x.trim().isNotEmpty).join(' ').trim();
      case 'ORG':
        org = _unescape(value.split(';').first).trim();
      case 'TEL':
        tels.add(_number(_unescape(value).replaceFirst(RegExp('^tel:', caseSensitive: false), '')));
    }
  }
  return out;
}

String _unescape(String s) =>
    s.replaceAll(r'\n', ' ').replaceAll(r'\N', ' ').replaceAll(r'\,', ',').replaceAll(r'\;', ';').replaceAll(r'\\', r'\');

// ── CSV ─────────────────────────────────────────────────────────────────────

List<PhoneContact> _csv(String text) {
  final rows = _csvRows(text);
  if (rows.length < 2) return const [];
  final head = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(bool Function(String h) test) => head.indexWhere(test);
  // A whole name if there is one, else its parts.
  final full = col((h) => h == 'name' || h == 'display name' || h == 'full name' || h == 'file as');
  final first = col((h) => h == 'first name' || h == 'given name');
  final middle = col((h) => h == 'middle name' || h == 'additional name');
  final last = col((h) => h == 'last name' || h == 'family name' || h == 'surname');
  final company = col((h) => h == 'company' || h == 'organization name' || h == 'organization 1 - name');
  // "Phone 1 - Value", "Mobile Phone", "Business Phone", "Work Phone", "Mobile Number"…
  final phones = [
    for (var i = 0; i < head.length; i++)
      if ((head[i].contains('phone') || head[i].contains('mobile') || head[i] == 'tel' || head[i].contains('number')) &&
          !head[i].contains('type') &&
          !head[i].contains('label'))
        i,
  ];
  if (phones.isEmpty) return const [];
  String at(List<String> r, int i) => i >= 0 && i < r.length ? r[i].trim() : '';
  final out = <PhoneContact>[];
  for (final r in rows.skip(1)) {
    final numbers = <String>{
      for (final i in phones)
        // Google puts several in one cell: "+20 100 … ::: +20 122 …".
        for (final v in at(r, i).split(':::'))
          if (_number(v) case final n when n.isNotEmpty) n,
    }.toList();
    if (numbers.isEmpty) continue;
    var name = at(r, full);
    if (name.isEmpty) name = [at(r, first), at(r, middle), at(r, last)].where((x) => x.isNotEmpty).join(' ');
    if (name.isEmpty) name = at(r, company);
    out.add(PhoneContact(name.isEmpty ? numbers.first : name, numbers));
  }
  return out;
}

/// RFC 4180: commas, quotes doubled inside quoted fields, newlines in them.
/// Excel in much of Europe writes semicolons: the header line says which.
List<List<String>> _csvRows(String text) {
  final header = text.split('\n').first;
  final sep = !header.contains(',') && header.contains(';') ? ';' : ',';
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((x) => x.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  row.add(cell.toString());
  if (row.any((x) => x.trim().isNotEmpty)) rows.add(row);
  return rows;
}

/// A dialable number: digits, a leading +, * and #; the rest is formatting.
String _number(String v) {
  final s = v.trim();
  final plus = s.startsWith('+');
  final digits = s.replaceAll(RegExp(r'[^\d*#]'), '');
  return digits.isEmpty ? '' : (plus ? '+$digits' : digits);
}
