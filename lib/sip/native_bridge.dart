import 'dart:async';

import 'package:flutter/services.dart';

/// Dart side of the `medut/native` channel to the native engine
/// (NativeBridge.kt / MedutBridge.swift).
class NativeBridge {
  NativeBridge._() {
    _ch.setMethodCallHandler(_onCall);
  }

  static final NativeBridge instance = NativeBridge._();
  static const _ch = MethodChannel('medut/native');

  final _states = StreamController<Map<String, dynamic>>.broadcast();
  final _routes = StreamController<String>.broadcast();
  final _history = StreamController<void>.broadcast();
  final _notices = StreamController<String>.broadcast();

  /// Registrations, calls and presence, on every change.
  Stream<Map<String, dynamic>> get states => _states.stream;

  /// A notification or the call screen asks for a Flutter flow (chat, Calls tab).
  Stream<String> get routes => _routes.stream;

  /// Native wrote a call or a message into the history database.
  Stream<void> get historyChanges => _history.stream;

  /// A short message for the user (a call or transfer that failed).
  Stream<String> get notices => _notices.stream;

  static Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'state':
        _states.add(_map(call.arguments));
      case 'openRoute':
        _routes.add(_map(call.arguments)['route'] as String? ?? '');
      case 'historyChanged':
        _history.add(null);
      case 'notice':
        _notices.add(_map(call.arguments)['text'] as String? ?? '');
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

  /// Tells native Dart is listening; returns the current state, and native
  /// then flushes anything it queued.
  Future<Map<String, dynamic>?> ready() async {
    final r = await _invoke<Object?>('ready');
    return r == null ? null : _map(r);
  }

  /// The saved accounts, secrets included: null when native is not there (tests).
  Future<List<Map<String, dynamic>>?> getAccounts() async {
    final r = await _invoke<List<Object?>>('getAccounts');
    return r?.map(_map).toList();
  }

  /// Replaces every saved account; native re-registers what changed.
  Future<bool> setAccounts(List<Map<String, dynamic>> accounts) async {
    try {
      await _ch.invokeMethod<void>('setAccounts', {'accounts': accounts});
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setConfig(Map<String, Object?> config) => _invoke('setConfig', config);

  /// {status, sipCode, error}; null when native is not there.
  Future<Map<String, dynamic>?> tryRegister(Map<String, dynamic> account, int timeoutMs) async {
    final r = await _invoke<Object?>('tryRegister', {'account': account, 'timeoutMs': timeoutMs});
    return r == null ? null : _map(r);
  }

  Future<void> cancelProbe(String id) => _invoke('cancelProbe', {'id': id});
  Future<void> retry(String id) => _invoke('retry', {'id': id});

  Future<void> dial(String number, {String? accountId, String? name}) =>
      _invoke('dial', {'number': number, 'accountId': accountId, 'name': name});

  /// Null when sent, else why not.
  Future<String?> sendMessage(String peer, String body, {String? accountId}) =>
      _invoke<String>('sendMessage', {'peer': peer, 'body': body, 'accountId': accountId});

  Future<void> queueCodes(List<Map<String, String>> codes) => _invoke('queueCodes', {'codes': codes});
  Future<void> setPresenceTargets(List<String> targets) => _invoke('setPresenceTargets', {'targets': targets});

  /// {seq, lines, reset}: the lines of [kind] ('conn' | 'sip') after [since].
  Future<Map<String, dynamic>?> getLog(String kind, int since) async {
    final r = await _invoke<Object?>('getLog', {'kind': kind, 'since': since});
    return r == null ? null : _map(r);
  }

  Future<void> openCallScreen() => _invoke('openCallScreen');
  Future<void> missedSeen() => _invoke('missedSeen');

  Future<bool> isBatteryExempt() async => await _invoke<bool>('isBatteryExempt') ?? true;
  Future<void> requestBatteryExemption() => _invoke('requestBatteryExemption');
  Future<bool> canUseFullScreenIntent() async => await _invoke<bool>('canUseFullScreenIntent') ?? true;
  Future<void> openFullScreenIntentSettings() => _invoke('openFullScreenIntentSettings');
}
