import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// Opens the file manager on [path]'s folder with the file selected:
/// org.freedesktop.FileManager1 (Dolphin, Files, Nemo…) or the plain folder
/// on Linux, Explorer on Windows.
Future<void> showInFolder(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', path]);
      return;
    }
    final r = await Process.run('dbus-send', [
      '--session',
      '--dest=org.freedesktop.FileManager1',
      '--type=method_call',
      '/org/freedesktop/FileManager1',
      'org.freedesktop.FileManager1.ShowItems',
      'array:string:${Uri.file(path)}',
      'string:',
    ]);
    if (r.exitCode == 0) return;
  } on ProcessException {
    // no dbus-send: open the folder instead
  }
  await openPath(p.dirname(path));
}

/// Opens a file or folder with the desktop's default application.
Future<void> openPath(String path) async {
  try {
    await Process.start(Platform.isWindows ? 'explorer.exe' : 'xdg-open', [path]);
  } on ProcessException {
    // nothing to open it with
  }
}

/// Desktop "Share" for an export: asks where to save [contents] as [name],
/// writes it, and shows it in its folder. False when the user cancelled.
Future<bool> saveTextAs(String name, String contents) async {
  final path = await FilePicker.platform.saveFile(fileName: name);
  if (path == null) return false;
  await File(path).writeAsString(contents);
  await showInFolder(path);
  return true;
}
