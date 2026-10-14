import Flutter
import UIKit
import UserNotifications

/// One call snapshot, as [PhoneEngine] builds it on every change. Every
/// snapshot is complete, so the latest one is always enough to render.
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
  /// MOS of what you hear, and of what the other side hears ("" until measured).
  var mosYou: String { raw["mosYou"] as? String ?? "" }
  var mosThem: String { raw["mosThem"] as? String ?? "" }
  var encrypted: Bool { raw["encrypted"] as? Bool ?? false }
  /// ok | reconnecting | weak
  var link: String { raw["link"] as? String ?? "ok" }
  var dark: Bool { raw["dark"] as? Bool ?? false }
  var rtl: Bool { raw["rtl"] as? Bool ?? false }
  var outgoing: Bool { raw["outgoing"] as? Bool ?? false }
  var details: [[String]] {
    (raw["details"] as? [[Any]])?.map { $0.map { "\($0)" } } ?? []
  }
  var second: [String: Any]? { raw["second"] as? [String: Any] }
  /// A warm transfer under way: phase (calling | talking), status, hint, join, back.
  var transfer: [String: Any]? { raw["transfer"] as? [String: Any] }
  /// Outputs offered during the call: [{id, kind, name}].
  var routes: [[String: Any]] { raw["routes"] as? [[String: Any]] ?? [] }

  var title: String { name.isEmpty ? number : name }
  var isLive: Bool { phase != "idle" && phase != "ended" }

  /// Translated label from Flutter's string table, so native and Flutter share one.
  func label(_ key: String, _ fallback: String) -> String {
    PhoneEngine.shared.config.label(key, fallback)
  }
}

/// The `medut/native` channel between Flutter and [PhoneEngine] (the same
/// contract as NativeBridge.kt), and the fan-out of call snapshots to the
/// native call screen. Messages to Dart before it is listening are dropped,
/// except navigation, which waits for `ready`.
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
    let engine = PhoneEngine.shared
    switch call.method {
    case "ready":
      dartReady = true
      result(engine.state())
      flush()
    case "state":
      result(engine.state())
    case "getAccounts":
      result(engine.repo.all().map { $0.json })
    case "setAccounts":
      engine.setAccounts((args["accounts"] as? [[String: Any]] ?? []).map(AccountCfg.init(json:)))
      result(nil)
    case "setConfig":
      engine.setConfig(args)
      result(nil)
    case "tryRegister":
      let account = AccountCfg(json: args["account"] as? [String: Any] ?? [:])
      engine.tryRegister(account, timeoutMs: (args["timeoutMs"] as? NSNumber)?.intValue ?? 8000) { result($0) }
    case "cancelProbe":
      engine.cancelProbe(args["id"] as? String ?? "")
      result(nil)
    case "retry":
      engine.retryNow(args["id"] as? String ?? "")
      result(nil)
    case "dial":
      engine.dial(args["number"] as? String ?? "", accountId: args["accountId"] as? String, name: args["name"] as? String)
      result(nil)
    case "sendMessage":
      result(engine.sendMessage(args["peer"] as? String ?? "", args["body"] as? String ?? "",
                                accountId: args["accountId"] as? String))
    case "queueCodes":
      engine.queueCodes(args["codes"] as? [[String: Any]] ?? [])
      result(nil)
    case "setPresenceTargets":
      engine.setPresenceTargets(args["targets"] as? [String] ?? [])
      result(nil)
    case "getLog":
      result(EngineLog.read(args["kind"] as? String ?? "conn", since: (args["since"] as? NSNumber)?.intValue ?? 0))
    case "openCallScreen":
      CallScreenPresenter.present()
      result(nil)
    case "missedSeen":
      engine.missedSeen()
      result(nil)
    case "requestBatteryExemption", "openFullScreenIntentSettings":
      result(nil) // Android only
    case "isBatteryExempt", "canUseFullScreenIntent":
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Engine → call screen

  func update(_ next: CallSnapshot) {
    let prev = latest
    latest = next
    // CallKit rings and answers; the app's own screen takes over once the
    // call is dialling or connected, when the app is in front.
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
        // Only navigation is worth replaying: state is pulled on ready.
        if method == "openRoute" { self.pending.append((method, args)) }
        return
      }
      ch.invokeMethod(method, arguments: args)
    }
  }

  private func flush() {
    guard let ch = channel else { return }
    let items = pending
    pending.removeAll()
    for (m, a) in items { ch.invokeMethod(m, arguments: a) }
  }
}
