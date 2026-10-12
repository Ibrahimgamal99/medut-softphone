import Flutter
import UIKit
import UserNotifications

/// One call snapshot, as pushed from Dart on every change. Dart owns the call;
/// native only reports it to CallKit and draws the in-call screen.
struct CallSnapshot {
  let raw: [String: Any]

  init(_ raw: [String: Any] = [:]) { self.raw = raw }

  var phase: String { raw["phase"] as? String ?? "idle" }
  var callId: String { raw["callId"] as? String ?? "" }
  var name: String { raw["name"] as? String ?? "" }
  var number: String { raw["number"] as? String ?? "" }
  var account: String { raw["account"] as? String ?? "" }
  var status: String { raw["status"] as? String ?? "" }
  var startedAt: Double { (raw["startedAt"] as? NSNumber)?.doubleValue ?? 0 }
  var muted: Bool { raw["muted"] as? Bool ?? false }
  var held: Bool { raw["held"] as? Bool ?? false }
  var route: String { raw["route"] as? String ?? "earpiece" }
  var bluetooth: Bool { raw["bluetooth"] as? Bool ?? false }
  var recording: Bool { raw["recording"] as? Bool ?? false }
  var canRecord: Bool { raw["canRecord"] as? Bool ?? true }
  var mos: String { raw["mos"] as? String ?? "" }
  var quality: String { raw["quality"] as? String ?? "" }
  var qualityLevel: Int { (raw["qualityLevel"] as? NSNumber)?.intValue ?? 0 }
  var qualityWord: String { raw["qualityWord"] as? String ?? "" }
  var dark: Bool { raw["dark"] as? Bool ?? false }
  var rtl: Bool { raw["rtl"] as? Bool ?? false }
  var outgoing: Bool { raw["outgoing"] as? Bool ?? false }
  var details: [[String]] {
    (raw["details"] as? [[Any]])?.map { $0.map { "\($0)" } } ?? []
  }
  var second: [String: Any]? { raw["second"] as? [String: Any] }
  /// Outputs offered during the call: [{id, kind, name}].
  var routes: [[String: Any]] { raw["routes"] as? [[String: Any]] ?? [] }

  var title: String { name.isEmpty ? number : name }
  var isLive: Bool { phase != "idle" && phase != "ended" }

  /// Translated label from Dart, so native and Flutter share one string table.
  func label(_ key: String, _ fallback: String) -> String {
    (raw["labels"] as? [String: Any])?[key] as? String ?? fallback
  }
}

/// The `medut/native` channel. Dart → native: call snapshots and a few
/// commands. Native → Dart: CallKit actions and in-call screen taps
/// (`callAction`), PushKit tokens and pushes, CallKit audio activation.
/// Messages sent before Dart is listening are queued until it sends `ready`.
final class MedutBridge {
  static let shared = MedutBridge()

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var pending: [(String, Any?)] = []
  private(set) var latest = CallSnapshot()
  private var listeners: [UUID: (CallSnapshot) -> Void] = [:]

  func attach(messenger: FlutterBinaryMessenger) {
    if channel != nil { return }
    let ch = FlutterMethodChannel(name: "medut/native", binaryMessenger: messenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ready":
      dartReady = true
      flush()
      result(nil)
    case "callState":
      update(CallSnapshot(args))
      result(nil)
    case "openCallScreen":
      CallScreenPresenter.present()
      result(nil)
    case "pushToken":
      result(CallKitManager.shared.pushTokenInfo)
    case "missedCalls":
      notify(id: "medut.missed", title: args["title"] as? String ?? "Missed call",
             body: args["latest"] as? String ?? "", badge: args["count"] as? Int)
      result(nil)
    case "clearMissed":
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["medut.missed"])
      result(nil)
    case "messageNotification":
      let peer = args["peer"] as? String ?? ""
      notify(id: "medut.msg.\(peer)", title: args["title"] as? String ?? peer, body: args["body"] as? String ?? "")
      result(nil)
    case "setRingtone":
      CallKitManager.shared.setRingtone(path: args["path"] as? String)
      result(nil)
    case "keepAlive", "requestBatteryExemption", "openFullScreenIntentSettings":
      result(nil)  // Android only
    case "isBatteryExempt", "canUseFullScreenIntent":
      result(true)
    case "setRoute":
      result(false)  // the SDK's own iOS shim routes audio
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Dart → native state

  private func update(_ next: CallSnapshot) {
    let prev = latest
    latest = next
    CallKitManager.shared.sync(prev: prev, next: next)
    if next.isLive && next.phase != "incoming" && UIApplication.shared.applicationState == .active
      && (prev.callId != next.callId || prev.phase == "incoming") {
      CallScreenPresenter.present()
    }
    for l in listeners.values { l(next) }
  }

  @discardableResult
  func addListener(_ l: @escaping (CallSnapshot) -> Void) -> UUID {
    let id = UUID()
    listeners[id] = l
    l(latest)
    return id
  }

  func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

  // MARK: native → Dart

  func toDart(_ method: String, _ args: Any? = nil) {
    DispatchQueue.main.async {
      guard let ch = self.channel, self.dartReady else {
        self.pending.append((method, args))
        return
      }
      ch.invokeMethod(method, arguments: args)
    }
  }

  func action(_ action: String, callId: String? = nil, extra: [String: Any] = [:]) {
    var args: [String: Any] = ["action": action, "callId": callId ?? latest.callId]
    extra.forEach { args[$0.key] = $0.value }
    toDart("callAction", args)
  }

  private func flush() {
    guard let ch = channel else { return }
    let items = pending
    pending.removeAll()
    for (m, a) in items { ch.invokeMethod(m, arguments: a) }
  }

  /// A pop-up notification; the same [id] replaces the previous one
  /// (one "N missed calls", one per conversation).
  private func notify(id: String, title: String, body: String, badge: Int? = nil) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      if let badge = badge { content.badge = NSNumber(value: badge) }
      center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
  }
}
