import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// Linux or Windows: the desktop app, with lib/desktop's engine and shell.
/// The target platform, not the host's: widget tests run on a Linux machine
/// but test the phone app (Android unless a test says otherwise).
bool get isDesktop => switch (defaultTargetPlatform) {
      TargetPlatform.linux || TargetPlatform.windows => true,
      _ => false,
    };

/// sqflite over FFI for medut.db, on the operating system's own SQLite.
void initDesktopSqlite() {
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _openSystemSqlite);
}

/// Runs in sqflite's background isolate: libsqlite3.so.0 on Linux (the
/// unversioned name needs the -devel package), winsqlite3.dll on Windows 10
/// and later.
void _openSystemSqlite() {
  open
    ..overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'))
    ..overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
}
