import 'package:flutter/material.dart';

import 'call_view.dart';
import 'desktop_shell.dart';
import 'engine.dart';

/// Wraps the app on the desktop (MaterialApp.builder): the call screen over
/// it while a call is up and in front, or nothing but the ringing card while
/// the window is that card. In the wide layout the tabs show the call in
/// their own pane instead ([DesktopShell.paneShowsCall]).
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shell = DesktopShell.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([shell.mode, shell.callOpen, shell.paneShowsCall, DesktopEngine.instance.snapshotNotifier]),
      builder: (context, _) {
        final phase = DesktopEngine.instance.snapshotNotifier.value['phase'];
        final live = phase != null && phase != 'idle';
        if (shell.mode.value == WindowMode.ringing && live) return _own(const DesktopCallView(compact: true));
        final over = live && shell.callOpen.value && !shell.paneShowsCall.value;
        return Stack(children: [
          // Kept mounted under the call so the tabs keep their place.
          Positioned.fill(child: child),
          if (over) Positioned.fill(child: _own(const DesktopCallView())),
        ]);
      },
    );
  }

  /// The call screen sits above the Navigator, so it brings the Overlay its
  /// text field and tooltips need.
  static Widget _own(Widget view) => Overlay(initialEntries: [OverlayEntry(builder: (_) => view)]);
}
