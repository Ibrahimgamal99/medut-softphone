import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../desktop/contact_import.dart';
import '../desktop/platform.dart';

class PhoneContact {
  const PhoneContact(this.name, this.numbers);
  final String name;
  final List<String> numbers;

  Map<String, Object?> toJson() => {'name': name, 'numbers': numbers};

  static PhoneContact fromJson(Map<String, Object?> j) =>
      PhoneContact(j['name'] as String? ?? '', [for (final n in j['numbers'] as List? ?? const []) '$n']);
}

/// The device address book, read once permission is given. Used to put names
/// on numbers and for the Contacts list on the Team tab. A computer has no
/// such book, so on the desktop Medut keeps its own (contacts.json), filled
/// from an exported .vcf or .csv and by "Save to contacts".
class ContactsService extends ChangeNotifier {
  List<PhoneContact> contacts = [];
  final Map<String, String> _byNumber = {};
  bool permitted = false;

  static String normalize(String n) {
    final digits = n.replaceAll(RegExp(r'[^\d+]'), '');
    // Compare on the last 9 digits so +20 100… and 0100… match.
    return digits.length > 9 ? digits.substring(digits.length - 9) : digits;
  }

  Future<void> load({bool ask = false}) async {
    if (isDesktop) return _loadDesktop();
    try {
      // Only prompt when the user asked; at start-up just use what is allowed.
      if (!ask && !await Permission.contacts.isGranted) {
        permitted = false;
        notifyListeners();
        return;
      }
      permitted = await FlutterContacts.requestPermission(readonly: true);
      if (!permitted) {
        notifyListeners();
        return;
      }
      final list = await FlutterContacts.getContacts(withProperties: true);
      _set(list
          .where((c) => c.phones.isNotEmpty)
          .map((c) => PhoneContact(c.displayName, c.phones.map((p) => p.number).toList())));
    } catch (_) {
      // No address book on this platform / build.
    }
  }

  String nameFor(String number) => _byNumber[normalize(number)] ?? '';

  /// Sorted by name, with the number → name index rebuilt.
  void _set(Iterable<PhoneContact> list) {
    contacts = list.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _byNumber.clear();
    for (final c in contacts) {
      for (final n in c.numbers) {
        _byNumber[normalize(n)] = c.name;
      }
    }
    notifyListeners();
  }

  // ── Desktop: Medut's own address book ─────────────────────────────────────

  static Future<File> _desktopFile() async => File('${(await getApplicationSupportDirectory()).path}/contacts.json');

  Future<void> _loadDesktop() async {
    permitted = true; // nothing to ask for
    try {
      final f = await _desktopFile();
      if (!await f.exists()) return notifyListeners();
      _set([for (final e in jsonDecode(await f.readAsString()) as List) PhoneContact.fromJson(Map<String, Object?>.from(e as Map))]);
    } catch (e) {
      debugPrint('contacts.json unreadable: $e');
      notifyListeners();
    }
  }

  Future<void> _saveDesktop() async {
    final f = await _desktopFile();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final c in contacts) c.toJson()]));
    await tmp.rename(f.path);
  }

  /// Adds the people in an exported address book (.vcf or .csv). Someone
  /// already here by one of their numbers gets the new numbers, not a second
  /// entry. Returns how many were added or updated; null if the file is not
  /// an address book.
  Future<int?> importFile(String path) async {
    final found = parseContactsFile(await File(path).readAsString());
    if (found.isEmpty) return null;
    final list = [...contacts];
    var changed = 0;
    for (final c in found) {
      final i = list.indexWhere((x) => x.numbers.any((n) => c.numbers.any((m) => normalize(n) == normalize(m))));
      if (i < 0) {
        list.add(c);
        changed++;
        continue;
      }
      final old = list[i];
      final numbers = [...old.numbers, for (final n in c.numbers) if (!old.numbers.any((o) => normalize(o) == normalize(n))) n];
      if (numbers.length != old.numbers.length) {
        list[i] = PhoneContact(old.name, numbers);
        changed++;
      }
    }
    _set(list);
    await _saveDesktop();
    return changed;
  }

  /// "Save to contacts": [number] under [name], or that name added to the
  /// person who already has it.
  Future<void> saveContact(String name, String number) async {
    final list = contacts.where((c) => !c.numbers.any((n) => normalize(n) == normalize(number))).toList();
    final existing = contacts.where((c) => c.name == name).firstOrNull;
    if (existing != null) {
      list.remove(existing);
      list.add(PhoneContact(name, [...existing.numbers, number]));
    } else {
      list.add(PhoneContact(name, [number]));
    }
    _set(list);
    await _saveDesktop();
  }

  /// Removes whoever has [number] from the desktop address book.
  Future<void> removeContact(String number) async {
    _set(contacts.where((c) => !c.numbers.any((n) => normalize(n) == normalize(number))));
    await _saveDesktop();
  }
}
