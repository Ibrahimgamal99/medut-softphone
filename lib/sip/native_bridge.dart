import 'dart:async';

import 'package:flutter/services.dart';

/// A tap on the native call screen, a notification, CallKit, or a headset.
class NativeAction {
  NativeAction(this.action, this.callId, this.args);
  final String action;
  final String callId;
  final Map<String, dynamic> args;
}

/// Dart side of the `medut/native` channel (see NativeBridge.kt / MedutBridge.swift).
class NativeBridge {
  NativeBridge._() {
    _ch.setMethodCallHandler(_onCall);
  }

  static final NativeBridge instance = NativeBridge._();
  static const _ch = MethodChannel('medut/native');

  final _actions = StreamController<NativeAction>.broadcast();
  final _routes = StreamController<String>.broadcast();
  final _pushTokens = StreamController<Map<String, dynamic>?>.broadcast();
  final _voipPushes = StreamController<Map<String, dynamic>>.broadcast();
  final _callkitAudio = StreamController<bool>.broadcast();
  final _audioRoutes = StreamController<Map<String, dynamic>>.broadcast();

  Stream<NativeAction> get actions => _actions.stream;
  Stream<String> get routes => _routes.stream;
  Stream<Map<String, dynamic>?> get pushTokens => _pushTokens.stream;
  Stream<Map<String, dynamic>> get voipPushes => _voipPushes.stream;
  Stream<bool> get callkitAudio => _callkitAudio.stream;
  Stream<Map<String, dynamic>> get audioRoutes => _audioRoutes.stream;

  /// Tells native Dart is listening; it then flushes anything it queued.
  Future<void> ready() => _invoke('ready');

  Future<dynamic> _onCall(MethodCall call) async {
    final args = (call.arguments is Map) ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
    switch (call.method) {
      case 'callAction':
        final a = args.remove('action') as String? ?? '';
        final id = args.remove('callId') as String? ?? '';
        _actions.add(NativeAction(a, id, args));
      case 'openRoute':
        _routes.add(args['route'] as String? ?? '');
      case 'pushToken':
        _pushTokens.add(call.arguments == null ? null : args);
      case 'voipPush':
        _voipPushes.add(args);
      case 'callkitAudio':
        _callkitAudio.add(args['active'] == true);
      case 'audioRoute':
        _audioRoutes.add(args);
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null; // tests / desktop
    } on PlatformException {
      return null;
    }
  }

  Future<void> callState(Map<String, Object?> snapshot) => _invoke('callState', snapshot);
  Future<void> openCallScreen() => _invoke('openCallScreen');

  Future<void> keepAlive({required bool enabled, required String title, required String text}) =>
      _invoke('keepAlive', {'enabled': enabled, 'title': title, 'text': text});

  /// One "N missed calls" notification, replaced on every new miss.
  Future<void> missedCalls({required int count, required String latest, required String title}) =>
      _invoke('missedCalls', {'count': count, 'latest': latest, 'title': title});

  Future<void> clearMissed() => _invoke('clearMissed');

  Future<void> messageNotification({required String peer, required String title, required String body}) =>
      _invoke('messageNotification', {'peer': peer, 'title': title, 'body': body});

  /// iOS: the sound CallKit rings with (a file path, or null for the default).
  Future<void> setRingtone(String? path) => _invoke('setRingtone', {'path': path});

  /// True when native took the route change (Android Telecom call up).
  Future<bool> setRoute(String route) async => await _invoke<bool>('setRoute', {'route': route}) ?? false;

  /// iOS: the current PushKit token as {token, provider}.
  Future<Map<String, dynamic>?> pushToken() async {
    final r = await _invoke<Map<Object?, Object?>>('pushToken');
    return r == null ? null : Map<String, dynamic>.from(r);
  }

  Future<bool> isBatteryExempt() async => await _invoke<bool>('isBatteryExempt') ?? true;
  Future<void> requestBatteryExemption() => _invoke('requestBatteryExemption');
  Future<bool> canUseFullScreenIntent() async => await _invoke<bool>('canUseFullScreenIntent') ?? true;
  Future<void> openFullScreenIntentSettings() => _invoke('openFullScreenIntentSettings');
}
