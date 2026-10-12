import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sip/sip_service.dart';
import 'accounts.dart';
import 'contacts.dart';
import 'db.dart';
import 'settings.dart';

// Created in main() before runApp and injected with overrides.
final settingsProvider = ChangeNotifierProvider<AppSettings>((_) => throw UnimplementedError());
final accountsProvider = ChangeNotifierProvider<AccountStore>((_) => throw UnimplementedError());
final dbProvider = ChangeNotifierProvider<LocalDb>((_) => throw UnimplementedError());
final sipProvider = ChangeNotifierProvider<SipService>((_) => throw UnimplementedError());
final contactsProvider = ChangeNotifierProvider<ContactsService>((_) => throw UnimplementedError());
