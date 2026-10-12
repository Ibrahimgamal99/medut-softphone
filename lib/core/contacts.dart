import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

class PhoneContact {
  const PhoneContact(this.name, this.numbers);
  final String name;
  final List<String> numbers;
}

/// The device address book, read once permission is given. Used to put names
/// on numbers and for the Contacts list on the Team tab.
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
      contacts = list
          .where((c) => c.phones.isNotEmpty)
          .map((c) => PhoneContact(c.displayName, c.phones.map((p) => p.number).toList()))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _byNumber.clear();
      for (final c in contacts) {
        for (final n in c.numbers) {
          _byNumber[normalize(n)] = c.name;
        }
      }
      notifyListeners();
    } catch (_) {
      // No address book on this platform / build.
    }
  }

  String nameFor(String number) => _byNumber[normalize(number)] ?? '';
}
