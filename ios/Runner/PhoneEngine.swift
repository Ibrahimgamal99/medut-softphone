import AVFoundation
import Contacts
import Foundation
import PushKit
import UIKit
import UserNotifications
import medut

enum Phase: String {
  case incoming, outgoing, active, held
}

/// A configured account and its live SDK object.
final class AccountRuntime {
  var cfg: AccountCfg
  let signature: String
  var account: Account?
  /// off | registering | registered | reconnecting | failed
  var status = "registering"
  var error = ""
  var retryInMs = 0
  var sipCode = 0
  var mwiNew = 0, mwiOld = 0, mwiUrgent = 0
  /// Registered by sign-in to see whether it works, not saved yet.
  var probe = false

  init(_ cfg: AccountCfg, _ signature: String) {
    self.cfg = cfg
    self.signature = signature
  }
}

final class ActiveCall {
  let id: String
  let call: Call
  let runtime: AccountRuntime
  let incoming: Bool
  var number: String
  var name: String
  var phase: Phase
  let createdAt = Date()
  var answeredAt: Date?
  var muted = false
  var recording = false
  var recordingPath = ""
  var userDeclined = false
  var remoteRinging = false
  var stats: MediaStats?
  var crypto = ""
  /// ok | reconnecting | weak
  var link = "ok"
  var info: CallInfo?
  var endedLocally = false
  var rttSum = 0.0, jitterSum = 0.0, lossSum = 0.0
  var samples = 0
  var autoAnswer: DispatchWorkItem?
  /// On the consult call of an attended transfer: the held call to hand over.
  weak var transferOf: ActiveCall?
  /// On a call placed to follow the other side's transfer: the old leg.
  weak var replaces: ActiveCall?
  var transferring = false
  var backstop: DispatchWorkItem?
  var semiTried = false
  /// A status feature code: kept out of the history.
  var featureCode = false

  var title: String { name.isEmpty ? number : name }

  init(id: String, call: Call, runtime: AccountRuntime, incoming: Bool, number: String, name: String, phase: Phase) {
    self.id = id
    self.call = call
    self.runtime = runtime
    self.incoming = incoming
    self.number = number
    self.name = name
    self.phase = phase
  }
}

/// The phone: drives MedutKit for every account, call, transfer, recording
/// and message, with or without the Flutter UI (PhoneEngine.kt is its twin).
/// CallKit rings and answers through the SDK's own integration; the native
/// call screen renders this engine's snapshots ([MedutBridge.latest]).
/// Everything runs on the main queue.
final class PhoneEngine: NSObject, PKPushRegistryDelegate {
  static let shared = PhoneEngine()

  private(set) var config = EngineConfig.load()
  let repo = AccountRepository()
  private let history = HistoryWriter()
  private(set) var sdkUp = false
  private var started = false

  var runtimes: [String: AccountRuntime] = [:]
  private(set) var calls: [ActiveCall] = []
  private(set) weak var focused: ActiveCall?
  private(set) var presence: [String: String] = [:]
  private var presenceTargets: [String] = []
  private var subscribed: Set<String> = []
  private var routes: [AudioRoute] = []
  private var route = "earpiece"
  private var pushToken: String?
  private var pushProvider: PushProvider = .none
  private var codeQueue: [(String, String, String)] = []
  private weak var codeCall: ActiveCall?
  private var probeWaiters: [String: () -> Void] = [:]
  private var subscription: MedutSubscription?
  /// Pushes whose CallKit call waits for its INVITE, oldest first: the SDK
  /// gives each INVITE to the oldest, and one that times out is a missed call
  /// with the caller its push named.
  private var pendingPushes: [(at: Date, uri: String?, name: String?, aor: String?)] = []
  private var registry: PKPushRegistry?
  private var statusTimer: Timer?
  private var names: [String: String] = [:]

  private var foreground: Bool { UIApplication.shared.applicationState == .active }

  // MARK: Start-up

  /// didFinishLaunching: every launch, with or without UI (a VoIP push).
  func start() {
    if started { return }
    started = true
    pushToken = UserDefaults.standard.string(forKey: "medut.engine.pushToken")
    #if DEBUG
      let provider: PushProvider = .apnsSandbox
    #else
      let provider: PushProvider = .apns
    #endif
    pushProvider = pushToken == nil ? .none : provider

    var options = StartOptions()
    options.callKit = callKitOptions()
    options.restoreAccounts = false
    do {
      try Medut.shared.start(medutConfig(), options: options)
      // The app-owned voice engine arms when CallKit activates the session,
      // so media never starts before CallKit.
      try? MedutAudioSession.shared.useAppOwnedAudio(true)
      sdkUp = true
    } catch {
      NSLog("Medut: SDK start failed: \(error)")
      EngineLog.conn("SDK failed to start: \(error)")
    }
    if sdkUp {
      subscription = Medut.shared.addEventHandler(queue: .main) { [weak self] e in self?.onEvent(e) }
      try? Medut.shared.network.setHandoverPolicy(reinviteCalls: true, hangupOnFailure: false)
      applyAudioPrefs()
      // Blocked, busy and Do not disturb are turned away before CallKit
      // hears of the call, so it never starts to ring.
      MedutCallKit.shared.incomingCallFilter = { [weak self] call in self?.refusal(call) }
      // Mute and hold from CallKit's screen, AirPods, or a cellular call.
      MedutCallKit.shared.onCallMutedChanged = { [weak self] call, muted in
        DispatchQueue.main.async {
          guard let self = self, let ac = self.find(call) else { return }
          ac.muted = muted
          self.push()
        }
      }
      MedutCallKit.shared.onCallHeldChanged = { [weak self] call, held in
        DispatchQueue.main.async {
          guard let self = self, let ac = self.find(call), ac.phase != .incoming else { return }
          ac.phase = held ? .held : .active
          self.push()
          self.pushState()
        }
      }
      MedutCallKit.shared.onPushCallTimedOut = { [weak self] in self?.pushCallTimedOut() }
      MedutCallKit.shared.onOutgoingCallRefused = { [weak self] _, _ in
        self?.notice(self?.config.label("callFailed", "Couldn't place the call") ?? "")
      }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(routeChanged),
                                           name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                           name: UIApplication.didBecomeActiveNotification, object: nil)
    let r = PKPushRegistry(queue: .main)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    registry = r
    applyAccounts()
    statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.publishStatus() }
    push()
  }

  private func medutConfig() -> MedutConfig {
    var c = MedutConfig()
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
    c.userAgent = "Medut/\(version) (ios)"
    c.iceGatheringTimeoutMs = 800
    c.statsIntervalMs = 2000
    c.mediaStallMs = 3000
    c.mosAlertThreshold = 3.5
    c.dscpRTP = 46
    c.dscpSIP = 26
    c.opus.forwardErrorCorrection = true
    c.opus.discontinuousTransmission = true
    c.opusExpectedLossPct = 10
    c.sipTimerBMs = 10_000
    c.regExpires = UInt32(config.regExpires)
    c.keepaliveIntervalMs = UInt32(config.keepaliveSec * 1000)
    c.logLevel = config.debugLogging ? .info : .warning
    c.traceSIP = config.traceSip
    c.aecMode = AECMode(rawValue: config.aecMode) ?? .webRTC
    c.noiseSuppression = config.noiseSuppression
    c.autoGainControl = config.autoGain
    return c
  }

  private func applyAudioPrefs() {
    guard sdkUp else { return }
    try? Medut.shared.audio.setAECMode(AECMode(rawValue: config.aecMode) ?? .webRTC)
    try? Medut.shared.audio.setNoiseSuppression(config.noiseSuppression)
    try? Medut.shared.audio.setAutoGainControl(config.autoGain)
    try? Medut.shared.audio.setJitterBufferType(.adaptive)
    switch config.jitterMode {
    case "low": try? Medut.shared.audio.setJitterBuffer(minMs: 20, maxMs: 150)
    case "robust": try? Medut.shared.audio.setJitterBuffer(minMs: 60, maxMs: 500)
    default: break
    }
  }

  private func callKitOptions() -> CallKitOptions {
    var o = CallKitOptions()
    o.localizedName = "Medut"
    o.maximumCallGroups = 2
    o.ringtoneSound = ringtoneSound()
    return o
  }

  /// The ringtone CallKit plays: a bundled `medut_<id>.wav`, or the user's
  /// own file copied to Library/Sounds; nil for the system one.
  private func ringtoneSound() -> String? {
    let path = config.ringtone
    if path == "system" || path.isEmpty { return nil }
    let file = (path as NSString).lastPathComponent
    if path.contains("/tones/"), Bundle.main.path(forResource: "medut_" + file, ofType: nil) != nil {
      return "medut_" + file
    }
    guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
    let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
    let dest = dir.appendingPathComponent("medut_custom." + (file as NSString).pathExtension)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: dest)
    return (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dest)) != nil ? dest.lastPathComponent : nil
  }

  @objc private func becameActive() {
    publishStatus()
    MedutPush.reachAccounts()
    push()
  }

  // MARK: PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    MedutPush.updatePushToken(credentials.token)
    setPushToken(credentials.token.map { String(format: "%02x", $0) }.joined())
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    setPushToken(nil)
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                    for type: PKPushType, completion: @escaping () -> Void) {
    let data = payload.dictionaryPayload
    func field(_ key: String) -> String? {
      if let s = data[key] as? String, !s.isEmpty { return s }
      if let nested = data["medut"] as? [AnyHashable: Any], let s = nested[key] as? String, !s.isEmpty { return s }
      return nil
    }
    let uri = field("caller_uri"), aor = field("aor")
    EngineLog.conn("push call: call_id=\(field("call_id") ?? "-") aor=\(aor ?? "-") caller=\(uri ?? "-")")
    prunePushes()
    pendingPushes.append((at: Date(), uri: uri, name: field("caller_name"), aor: aor))
    // Reports a CallKit call at once (iOS requires it), then the INVITE binds to it.
    MedutPush.wake(payload: data, completion: completion)
  }

  /// A push rang and no INVITE came (MedutCallKit ended its call as
  /// unanswered): a missed call, as on Android.
  private func pushCallTimedOut() {
    prunePushes()
    guard !pendingPushes.isEmpty else { return }
    let p = pendingPushes.removeFirst()
    guard let rt = runtimeForPush(p.aor) else { return }
    let number = Numbers.userPart(p.uri ?? "")
    let contact = nameFor(number)
    let shown = (p.name ?? "").trimmingCharacters(in: .whitespaces)
    let name = !contact.isEmpty ? contact : (shown == number ? "" : shown)
    history.insert("calls", [
      "account_id": rt.cfg.id, "account_name": rt.cfg.label, "number": number, "name": name,
      "direction": "incoming", "result": "missed", "started_at": Int(p.at.timeIntervalSince1970 * 1000),
      "duration": 0, "end_reason": "no INVITE",
    ])
    MedutBridge.shared.toDart("historyChanged")
    notifyMissed(!name.isEmpty ? name : !number.isEmpty ? number : config.label("incomingCall", "Incoming call"))
  }

  private func prunePushes() {
    let now = Date()
    pendingPushes.removeAll { now.timeIntervalSince($0.at) > 30 }
  }

  /// The account a push is for: the one whose user its AOR names (servers
  /// often write their own address for the domain), else the default one.
  private func runtimeForPush(_ aor: String?) -> AccountRuntime? {
    let live = runtimes.values.filter { $0.account != nil && !$0.probe }
    if let aor = aor, let rt = live.first(where: { $0.cfg.user == Numbers.userPart(aor) }) { return rt }
    let def = repo.defaultAccount()
    return live.first { $0.cfg.id == def?.id } ?? live.first
  }

  private func setPushToken(_ token: String?) {
    if token == pushToken { return }
    let hadProvider = pushProvider != .none
    pushToken = token
    #if DEBUG
      pushProvider = token == nil ? .none : .apnsSandbox
    #else
      pushProvider = token == nil ? .none : .apns
    #endif
    UserDefaults.standard.set(token, forKey: "medut.engine.pushToken")
    for rt in Array(runtimes.values) where rt.cfg.push {
      if hadProvider, let t = token { try? rt.account?.setPushToken(t) } else { recreate(rt.cfg) }
    }
  }

  // MARK: Settings and accounts from Flutter

  func setConfig(_ raw: [String: Any]) {
    let ringtoneBefore = config.ringtone
    EngineConfig.save(raw)
    config = EngineConfig(raw)
    // A new ringtone rings from the next call on.
    if sdkUp && config.ringtone != ringtoneBefore { MedutCallKit.shared.update(options: callKitOptions()) }
    updatePolicy()
    publishStatus()
    applyAudioPrefs()
    scheduleApply()
    push()
  }

  func setAccounts(_ list: [AccountCfg]) {
    repo.replace(list)
    scheduleApply()
  }

  private var applyWork: DispatchWorkItem?

  private func scheduleApply() {
    applyWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.applyAccounts() }
    applyWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
  }

  private var providerName: String { "\(pushProvider)" }

  private func applyAccounts() {
    guard sdkUp else {
      pushState()
      return
    }
    let wanted = Dictionary(repo.all().filter { $0.enabled }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for (id, rt) in runtimes where rt.probe && wanted[id] != nil { rt.probe = false }
    for (id, rt) in runtimes where wanted[id] == nil && !rt.probe && !calls.contains(where: { $0.runtime.cfg.id == id }) {
      destroy(id)
    }
    for c in wanted.values {
      if let rt = runtimes[c.id], rt.signature == c.signature(config, pushProvider: providerName) {
        rt.cfg = c
      } else {
        recreate(c)
      }
    }
    syncSubscriptions()
    updatePolicy()
    pushState()
  }

  private func destroy(_ id: String) {
    guard let rt = runtimes.removeValue(forKey: id) else { return }
    try? rt.account?.unregister()
    rt.account?.destroy()
    subscribed = subscribed.filter { !$0.hasPrefix("\(id)|") }
  }

  private func recreate(_ c: AccountCfg) {
    if calls.contains(where: { $0.runtime.cfg.id == c.id }) { return } // never under a live call
    let wasProbe = runtimes[c.id]?.probe ?? false
    destroy(c.id)
    guard sdkUp else { return }
    let rt = AccountRuntime(c, c.signature(config, pushProvider: providerName))
    rt.probe = wasProbe
    runtimes[c.id] = rt
    do {
      let acct = try Medut.shared.createAccount(c.toSDK(config, pushProvider: pushProvider, pushToken: pushToken))
      rt.account = acct
      for (k, v) in c.headerPairs() { try? acct.addHeader(name: k, value: v) }
      try acct.register()
    } catch {
      rt.status = "failed"
      rt.error = "\(error)"
    }
  }

  /// Registers [c] without saving it, to see whether it works (sign-in).
  func tryRegister(_ c: AccountCfg, timeoutMs: Int, done: @escaping ([String: Any]) -> Void) {
    guard sdkUp else {
      done(["status": "failed", "sipCode": 0, "error": "SIP stack not running"])
      return
    }
    probeWaiters.removeValue(forKey: c.id)?()
    runtimes[c.id]?.probe = true
    recreate(c)
    guard let rt = runtimes[c.id] else {
      cancelProbe(c.id)
      done(["status": "failed", "sipCode": 0, "error": ""])
      return
    }
    rt.probe = true
    var finished = false
    let timeout = DispatchWorkItem { [weak self] in self?.probeWaiters[c.id]?() }
    var timedOut = false
    let finish: () -> Void = { [weak self] in
      guard let self = self, !finished else { return }
      finished = true
      timeout.cancel()
      self.probeWaiters.removeValue(forKey: c.id)
      let status = self.runtimes[c.id] !== rt ? "off" : rt.status
      if status != "registered" { self.cancelProbe(c.id) }
      done(["status": status, "sipCode": rt.sipCode, "error": rt.error])
    }
    probeWaiters[c.id] = { [weak self] in
      guard let self = self else { return }
      if timedOut || ["registered", "failed", "reconnecting"].contains(rt.status) || self.runtimes[c.id] !== rt {
        finish()
      }
    }
    let realTimeout = DispatchWorkItem { timedOut = true; timeout.perform() }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: realTimeout)
    probeWaiters[c.id]?()
  }

  func cancelProbe(_ id: String) {
    guard let rt = runtimes[id], rt.probe, repo.byId(id) == nil else { return }
    destroy(id)
    probeWaiters.removeValue(forKey: id)?()
    pushState()
  }

  func retryNow(_ id: String) { try? runtimes[id]?.account?.retryNow() }

  private func runtime(of a: Account?) -> AccountRuntime? {
    guard let a = a else { return nil }
    return runtimes.values.first { $0.account === a }
  }

  // MARK: SDK events

  private func onEvent(_ e: MedutEvent) {
    switch e {
    case .registration(let r): onRegistration(r)
    case .messageWaiting(let m):
      if let rt = runtime(of: m.account) {
        rt.mwiNew = Int(m.newVoice)
        rt.mwiOld = Int(m.oldVoice)
        rt.mwiUrgent = Int(m.newUrgent)
        pushState()
      }
    case .message(let m): onMessage(m)
    case .presence(let p):
      presence[Numbers.userPart(p.targetURI)] = "\(p.status)"
      pushState()
    case .incomingCall(let i): onIncoming(i)
    case .callState(let s): onCallState(s)
    case .mediaStats(let m):
      guard let c = m.call, let ac = find(c) else { return }
      ac.stats = m.stats
      if ac.phase == .active || ac.phase == .held {
        ac.rttSum += Double(m.stats.rttMs)
        ac.jitterSum += Double(m.stats.jitterMs)
        ac.lossSum += Double(m.stats.lossPctRx)
        ac.samples += 1
      }
      push()
    case .sdpNegotiation(let s):
      if let c = s.call, let ac = find(c) { ac.crypto = s.negotiatedCrypto ?? "" }
    case .transferRequest(let t): onTransferRequest(t)
    case .transferFailed(let t): onTransferFailed(t)
    case .network(let n):
      EngineLog.conn("network \(n.stage)\(n.localAddress.isEmpty ? "" : " \(n.localAddress)")")
      guard let c = n.call, let ac = find(c) else { return }
      let link: String
      switch n.stage {
      case .callMigrating, .callDeferred, .callICEStale: link = "reconnecting"
      case .callMigrated, .callMigrateAccepted: link = "ok"
      case .callMigrationFailed, .callICEFailed: link = "weak"
      default: link = ac.link
      }
      if link != ac.link {
        ac.link = link
        push()
      }
    case .qualityAlert(let q):
      guard let c = q.call, let ac = find(c), q.issue == .mediaStall else { return }
      ac.link = q.recovering ? "ok" : "weak"
      push()
    case .log(let line):
      if config.debugLogging { EngineLog.conn(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
    case .sipTrace(let t):
      EngineLog.sip("\(t.direction == .tx ? "→" : "←") \(t.transport) \(t.remoteAddress)\n\(t.message)")
    default:
      break
    }
  }

  private func onRegistration(_ e: RegistrationEvent) {
    guard let rt = runtime(of: e.account) else { return }
    let was = rt.status
    switch e.state {
    case .registered: rt.status = "registered"
    case .registering: rt.status = "registering"
    case .reconnecting: rt.status = "reconnecting"
    case .failed: rt.status = "failed"
    default: rt.status = "off"
    }
    rt.error = e.errorText ?? ""
    rt.retryInMs = Int(e.retryDelayMs)
    EngineLog.conn("\(rt.cfg.label): \(e.state)" + (rt.error.isEmpty ? "" : " — \(rt.error)")
      + (e.retryDelayMs > 0 ? " (retry \(e.retryDelayMs / 1000)s)" : ""))
    if let r = rt.error.range(of: "\\b[3-6]\\d\\d\\b", options: .regularExpression) {
      rt.sipCode = Int(rt.error[r]) ?? 0
    } else {
      rt.sipCode = 0
    }
    // Each refresh reports "registered" again: publish and subscribe only on arrival.
    if rt.status == "registered" && was != "registered" {
      publishStatus(rt)
      syncSubscriptions()
    }
    probeWaiters[rt.cfg.id]?()
    pushState()
  }

  private func onMessage(_ m: MessageEvent) {
    guard let rt = runtime(of: m.account) else { return }
    let peer = Numbers.userPart(m.fromURI)
    history.addMessage(accountId: rt.cfg.id, peer: peer, body: m.body, outgoing: false)
    if !foreground {
      let who = nameFor(peer)
      notify(id: "medut.msg.\(peer)", title: who.isEmpty ? peer : who, body: m.body)
    }
    MedutBridge.shared.toDart("historyChanged")
  }

  // MARK: Presence and your status

  private func publishStatus(_ only: AccountRuntime? = nil) {
    let dnd = config.effectiveStatus() == "dnd"
    for rt in only.map({ [$0] }) ?? Array(runtimes.values) where rt.status == "registered" {
      try? rt.account?.publishPresence(dnd ? .closed : .open)
    }
  }

  func setPresenceTargets(_ targets: [String]) {
    presenceTargets = targets
    syncSubscriptions()
  }

  private func syncSubscriptions() {
    guard let def = repo.defaultAccount(), let rt = runtimes[def.id], rt.status == "registered" else { return }
    let want = Set(presenceTargets.map { "\(rt.cfg.id)|\($0)" })
    for key in subscribed.subtracting(want) {
      let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
      if parts.count == 2, let o = runtimes[parts[0]] { try? o.account?.unsubscribePresence(uriFor(o.cfg, parts[1])) }
      subscribed.remove(key)
    }
    for key in want.subtracting(subscribed) {
      let ext = String(key.split(separator: "|", maxSplits: 1).last ?? "")
      try? rt.account?.subscribePresence(uriFor(rt.cfg, ext))
      subscribed.insert(key)
    }
  }

  /// Status feature codes to dial, one after the other, as ordinary calls.
  func queueCodes(_ codes: [[String: Any]]) {
    for c in codes {
      guard let id = c["accountId"] as? String, let code = c["code"] as? String else { continue }
      codeQueue.append((id, c["key"] as? String ?? "", code))
    }
    publishStatus()
    dialNextCode()
  }

  private func dialNextCode() {
    guard codeCall == nil, !codeQueue.isEmpty, calls.isEmpty else { return }
    let (id, key, code) = codeQueue.removeFirst()
    EngineLog.conn("status code: \(key) \(code)")
    guard let ac = dial(code, accountId: id, name: config.label("code_\(key)", key)) else {
      dialNextCode()
      return
    }
    ac.featureCode = true
    codeCall = ac
    // The PBX hangs up after its announcement; if it does not, we do.
    let w = DispatchWorkItem { [weak self, weak ac] in
      if let ac = ac, self?.calls.contains(where: { $0 === ac }) == true { self?.hangup(ac) }
    }
    ac.backstop = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
  }

  // MARK: Calls

  private func find(_ c: Call) -> ActiveCall? { calls.first { $0.call === c } }

  private func byId(_ id: String?) -> ActiveCall? {
    guard let id = id, !id.isEmpty else { return nil }
    return calls.first { $0.id == id }
  }

  private func callId(of c: Call) -> String {
    let id = (try? c.info().callID) ?? ""
    return id.isEmpty ? UUID().uuidString : id
  }

  /// What the incoming-call filter needs, readable from the SDK's event
  /// thread: the settings, how many calls are up, and our accounts.
  private struct Policy {
    var config = EngineConfig()
    var callCount = 0
    var accounts: [ObjectIdentifier: (id: String, label: String)] = [:]
  }

  private let policyLock = NSLock()
  private var policy = Policy()
  /// Calls the filter turned away, until their event arrives.
  private var refused: Set<ObjectIdentifier> = []

  private func updatePolicy() {
    var accounts: [ObjectIdentifier: (id: String, label: String)] = [:]
    for rt in runtimes.values {
      if let a = rt.account { accounts[ObjectIdentifier(a)] = (rt.cfg.id, rt.cfg.label) }
    }
    let p = Policy(config: config, callCount: calls.count, accounts: accounts)
    policyLock.lock()
    policy = p
    policyLock.unlock()
  }

  /// Whether an incoming call is turned away, and with which SIP code: 480
  /// for an account we no longer have, 603 for a blocked number, 486 when two
  /// calls are already up or under Do not disturb (unless a favourite or a
  /// repeat caller gets through; one turned away by Do not disturb still
  /// shows as missed). Nil lets it ring. Any thread.
  private func refusal(_ call: Call) -> UInt16? {
    policyLock.lock()
    let p = policy
    policyLock.unlock()
    let code = refusalCode(call, p)
    if code != nil {
      policyLock.lock()
      refused.insert(ObjectIdentifier(call))
      policyLock.unlock()
    }
    return code
  }

  private func refusalCode(_ call: Call, _ p: Policy) -> UInt16? {
    guard let acct = call.account, let owner = p.accounts[ObjectIdentifier(acct)] else { return 480 }
    let number = Numbers.userPart(call.remoteURI)
    if p.config.blocked.contains(number) {
      DispatchQueue.main.async { EngineLog.conn("blocked call from \(number)") }
      return 603
    }
    if p.callCount >= 2 { return 486 }
    if p.config.effectiveStatus() == "dnd" {
      let fav = p.config.letFavourites && p.config.favourites.contains { Numbers.sameNumber($0, number) }
      let repeatCaller = p.config.letRepeat && HistoryWriter.calledRecentlyReadOnly(number)
      if !fav && !repeatCaller {
        let shown = (call.remoteDisplayName ?? "").trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          let contact = self.nameFor(number)
          let name = !contact.isEmpty ? contact : (shown == number ? "" : shown)
          self.history.insert("calls", [
            "account_id": owner.id, "account_name": owner.label, "number": number, "name": name,
            "direction": "incoming", "result": "missed", "started_at": Int(Date().timeIntervalSince1970 * 1000), "duration": 0,
          ])
          MedutBridge.shared.toDart("historyChanged")
          // Turned away, but still a call you missed: say so.
          self.notifyMissed(name.isEmpty ? number : name)
        }
        return 486
      }
    }
    return nil
  }

  private func onIncoming(_ e: IncomingCallEvent) {
    let call = e.call
    policyLock.lock()
    let wasRefused = refused.remove(ObjectIdentifier(call)) != nil
    policyLock.unlock()
    // The SDK gave this INVITE the oldest push's CallKit call (or turned it
    // away in that call's place): that push is answered for.
    prunePushes()
    if !pendingPushes.isEmpty { pendingPushes.removeFirst() }
    // Already turned away by the filter, before CallKit was told.
    if wasRefused { return }
    // No CallKit: the same rules, applied here.
    if !MedutCallKit.shared.isEnabled, let code = refusal(call) {
      policyLock.lock()
      refused.remove(ObjectIdentifier(call))
      policyLock.unlock()
      try? call.reject(statusCode: code, reason: code == 603 ? "Decline" : code == 480 ? "Temporarily Unavailable" : "Busy Here")
      return
    }
    guard let rt = runtime(of: e.account ?? call.account) else { return }
    let number = Numbers.userPart(e.fromURI)
    let shown = (e.displayName ?? "").trimmingCharacters(in: .whitespaces)
    let contact = nameFor(number)
    let name = !contact.isEmpty ? contact : (shown == number ? "" : shown)
    let ac = ActiveCall(id: callId(of: call), call: call, runtime: rt, incoming: true, number: number, name: name, phase: .incoming)
    calls.append(ac)
    // A second call while talking is "call waiting": the live one stays in front.
    if focused == nil { focused = ac }
    push()
    pushState()
    // Auto-answer (not over another call). It still rings, so it can be declined.
    if config.autoAnswer && focused === ac {
      let w = DispatchWorkItem { [weak self, weak ac] in
        if let ac = ac, ac.phase == .incoming, self?.calls.contains(where: { $0 === ac }) == true { self?.answer(ac) }
      }
      ac.autoAnswer = w
      DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(config.autoAnswerDelay), execute: w)
    }
  }

  private func onCallState(_ e: CallStateEvent) {
    guard let ac = find(e.call) else { return }
    switch e.state {
    case .ringing:
      ac.remoteRinging = true
      if !ac.incoming && config.ringback && focused === ac { Ringback.start() }
    case .established:
      Ringback.stop()
      let first = ac.answeredAt == nil
      ac.info = (try? ac.call.info()) ?? ac.info
      if first {
        initCallRoute()
        ac.answeredAt = Date()
      }
      ac.phase = .active
      if let old = ac.replaces, calls.contains(where: { $0 === old }) { hangup(old) }
      ac.replaces = nil
      if first && config.recordingMode == "always" && ac.runtime.cfg.recordCalls && !ac.recording { toggleRecord(ac) }
    case .held:
      ac.phase = .held
    case .ended, .cancelled, .failed:
      // Ended from this phone, the app or not (CallKit, AirPods, a watch).
      if e.endedLocally { ac.endedLocally = true }
      finish(ac, failed: e.state == .failed, reason: e.reason, state: e.state)
      return
    default:
      break
    }
    push()
    pushState()
  }

  private func finish(_ ac: ActiveCall, failed: Bool, reason: String?, state: CallState) {
    ac.info = (try? ac.call.info()) ?? ac.info
    calls.removeAll { $0 === ac }
    ac.autoAnswer?.cancel()
    ac.backstop?.cancel()
    if !calls.contains(where: { $0.phase == .outgoing }) { Ringback.stop() }
    if calls.isEmpty {
      routes = []
      route = "earpiece"
    }
    if ac.recording {
      ac.recording = false
      Recordings.repairWav(ac.recordingPath)
    }
    // The person we were consulting hung up, declined or never answered:
    // the caller waiting on hold comes back.
    if let waiting = ac.transferOf, calls.contains(where: { $0 === waiting }), !waiting.transferring, waiting.phase == .held {
      resume(waiting)
    }
    if focused === ac || focused == nil { focused = calls.first }
    if codeCall === ac { codeCall = nil }
    if calls.isEmpty && !codeQueue.isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.dialNextCode() }
    }
    if ac.featureCode {
      push()
      pushState()
      return
    }
    let answered = ac.answeredAt != nil
    let result = ac.incoming
      // Unanswered and ended here was declined; by the caller or the network, missed.
      ? (answered ? "answered" : (ac.userDeclined || ac.endedLocally ? "declined" : "missed"))
      : (failed && !answered ? "failed" : "answered")
    let s = ac.stats
    let info = ac.info
    let now = Date()
    func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
    var sipCode: Int?
    if let st = info?.sipStatus, st > 0 {
      sipCode = Int(st)
    } else if let r = reason, let range = r.range(of: "\\b[3-6]\\d\\d\\b", options: .regularExpression) {
      sipCode = Int(r[range])
    }
    let cfg = ac.runtime.cfg
    var row: [String: Any?] = [:]
    row["account_id"] = cfg.id
    row["account_name"] = cfg.label
    row["number"] = ac.number
    row["name"] = ac.name
    row["direction"] = ac.incoming ? "incoming" : "outgoing"
    row["result"] = result
    row["started_at"] = ms(ac.createdAt)
    row["answered_at"] = ac.answeredAt.map(ms)
    row["ended_at"] = ms(now)
    row["duration"] = ac.answeredAt.map { Int(now.timeIntervalSince($0)) } ?? 0
    row["encryption"] = ac.crypto.isEmpty ? (cfg.mediaEnc == "none" ? "none" : cfg.mediaEnc) : ac.crypto
    row["call_id"] = (info?.callID).flatMap { $0.isEmpty ? nil : $0 } ?? ac.id
    row["remote_uri"] = info?.peerURI ?? ""
    row["local_uri"] = info?.localURI ?? ""
    row["setup_ms"] = info.flatMap { $0.setupDurationMs > 0 ? Int($0.setupDurationMs) : nil }
    row["end_reason"] = reason?.isEmpty == false ? reason : "\(state)"
    row["sip_code"] = sipCode
    row["ended_by"] = ac.endedLocally || ac.userDeclined ? "local" : "remote"
    row["transport"] = cfg.transport.uppercased()
    row["recording"] = ac.recordingPath
    row["rec_seconds"] = Recordings.wavSeconds(ac.recordingPath)
    row["codec"] = s?.codecName ?? ""
    row["ice"] = s.map { "\($0.iceLocalType) → \($0.iceRemoteType)" } ?? ""
    row["remote_media"] = s?.remoteAddress ?? ""
    if let s = s {
      row["mos"] = Double(s.mosLQAvg > 0 ? s.mosLQAvg : s.mosLQ)
      if s.mosLQMin > 0 { row["mos_min"] = Double(s.mosLQMin) }
      if s.mosLQRx > 0 { row["mos_rx"] = Double(s.mosLQRx) }
      row["packets_lost"] = Int(s.packetsLostRx)
    }
    if ac.samples > 0 {
      row["rtt"] = ac.rttSum / Double(ac.samples)
      row["jitter"] = ac.jitterSum / Double(ac.samples)
      row["loss"] = ac.lossSum / Double(ac.samples)
    }
    history.insert("calls", row)
    MedutBridge.shared.toDart("historyChanged")
    if result == "missed" { notifyMissed(ac.title) }
    if failed, let r = reason, !r.isEmpty, foreground { notice(r) }
    push()
    pushState()
  }

  private func notifyMissed(_ latest: String) {
    let count = history.missedSince(config.activitySeenAt)
    guard count > 0 else { return }
    notify(id: "medut.missed",
           title: count > 1 ? config.label("missedCalls", "{n} missed calls", ["n": "\(count)"]) : config.label("missedCall", "Missed call"),
           body: latest, badge: count)
  }

  func missedSeen() {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["medut.missed"])
  }

  // MARK: Actions

  func action(_ name: String, _ args: [String: Any] = [:]) {
    let ac = byId(args["callId"] as? String) ?? focused
    switch name {
    case "answer": if let ac = ac { answer(ac) }
    case "decline": if let ac = ac { decline(ac, code: 603) }
    case "busy": if let ac = ac { decline(ac, code: 486) }
    case "hangup": if let ac = ac { hangup(ac) }
    case "mute", "unmute": if let ac = ac { setMute(ac, name == "mute") }
    case "toggleMute": if let ac = ac { setMute(ac, !ac.muted) }
    case "hold": if let ac = ac { hold(ac) }
    case "unhold": if let ac = ac { resume(ac) }
    case "route":
      if let id = args["routeId"] as? String { selectRoute(id) } else { toggleSpeaker() }
    case "toggleSpeaker": toggleSpeaker()
    case "record": if let ac = ac { toggleRecord(ac) }
    case "dtmf":
      if let d = (args["digit"] as? String)?.first, let ac = ac { try? ac.call.sendDTMF(d) }
    case "swap": swap()
    case "answerWaiting": if let w = calls.first(where: { $0.phase == .incoming }) { answer(w) }
    case "completeTransfer": completeTransfer()
    case "cancelTransfer": if let c = calls.first(where: { $0.transferOf != nil }) { hangup(c) }
    case "transferBlind": if let t = args["target"] as? String { transferBlind(t) }
    case "transferWarm": if let t = args["target"] as? String { transferAttended(t) }
    case "addCall": if let n = args["number"] as? String { _ = dial(n, accountId: focused?.runtime.cfg.id, name: nil) }
    case "message":
      if let ac = ac { MedutBridge.shared.toDart("openRoute", ["route": "chat:\(ac.number)"]) }
    default: break
    }
  }

  func answer(_ ac: ActiveCall) {
    guard ac.phase == .incoming else { return }
    for other in calls where other !== ac && other.phase == .active { hold(other) }
    focused = ac
    try? ac.call.answer()
    push()
    pushState()
  }

  func decline(_ ac: ActiveCall, code: UInt16) {
    ac.userDeclined = true
    try? ac.call.reject(statusCode: code, reason: code == 486 ? "Busy Here" : "Decline")
  }

  func hangup(_ ac: ActiveCall) {
    ac.endedLocally = true
    if ac.recording {
      try? ac.call.stopRecording()
      ac.recording = false
    }
    if ac.phase == .incoming { decline(ac, code: 603) } else { try? ac.call.hangup() }
  }

  private func setMute(_ ac: ActiveCall, _ on: Bool) {
    try? ac.call.setMuted(on)
    ac.muted = on
    push()
  }

  private func hold(_ ac: ActiveCall) {
    guard ac.phase == .active else { return }
    try? ac.call.hold()
    ac.phase = .held
    push()
    pushState()
  }

  private func resume(_ ac: ActiveCall) {
    for other in calls where other !== ac && other.phase == .active { hold(other) }
    try? ac.call.resume()
    ac.phase = .active
    focused = ac
    push()
    pushState()
  }

  private func swap() {
    if let other = calls.first(where: { $0 !== focused && $0.phase != .incoming }) { resume(other) }
  }

  private func toggleRecord(_ ac: ActiveCall) {
    if !ac.recording && config.recordingMode == "off" { return }
    if ac.recording {
      try? ac.call.stopRecording()
      ac.recording = false
    } else {
      let dir = Recordings.dir(config)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      ac.recordingPath = dir.appendingPathComponent(Recordings.name(number: ac.number, name: ac.name)).path
      ac.recording = (try? ac.call.startRecording(to: ac.recordingPath)) != nil
    }
    push()
  }

  // MARK: Audio routes

  private func kindName(_ k: AudioRoute.Kind) -> String {
    switch k {
    case .speaker: return "speaker"
    case .bluetooth: return "bluetooth"
    case .wiredHeadset: return "wired"
    case .earpiece: return "earpiece"
    }
  }

  private func refreshRoutes() {
    routes = MedutAudioSession.shared.availableRoutes()
    if let active = routes.first(where: { $0.isActive }) { route = kindName(active.kind) }
  }

  @objc private func routeChanged() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.calls.isEmpty else { return }
      self.refreshRoutes()
      self.push()
    }
  }

  /// When a call connects: a connected headset wins, otherwise the earpiece.
  private func initCallRoute() {
    refreshRoutes()
    let headset = routes.first { $0.kind == .bluetooth } ?? routes.first { $0.kind == .wiredHeadset }
    if let h = headset, !h.isActive {
      selectRoute(h.id)
    } else if headset == nil && route == "speaker" {
      try? MedutAudioSession.shared.setSpeakerphone(false)
      route = "earpiece"
    }
  }

  private func toggleSpeaker() {
    let on = route == "speaker"
    let target = on
      ? (routes.first { $0.kind == .bluetooth } ?? routes.first { $0.kind == .wiredHeadset } ?? routes.first { $0.kind == .earpiece })
      : routes.first { $0.kind == .speaker }
    if let t = target { return selectRoute(t.id) }
    route = on ? "earpiece" : "speaker"
    try? MedutAudioSession.shared.setSpeakerphone(!on)
    push()
  }

  private func selectRoute(_ id: String) {
    if let r = routes.first(where: { $0.id == id }) { route = kindName(r.kind) }
    push()
    try? MedutAudioSession.shared.selectRoute(id)
    refreshRoutes()
    push()
  }

  // MARK: Placing calls and transfers

  private func accountFor(_ number: String, accountId: String?) -> AccountRuntime? {
    if let id = accountId, let rt = runtimes[id], !rt.probe { return rt }
    for r in config.dialRules where r.matches(number) {
      if let rt = runtimes[r.accountId], !rt.probe { return rt }
    }
    guard let def = repo.defaultAccount() else { return nil }
    return runtimes[def.id]
  }

  /// Places a call; an active call is put on hold first ("Add call").
  @discardableResult
  func dial(_ input: String, accountId: String?, name: String?) -> ActiveCall? {
    guard let rt = accountFor(input, accountId: accountId), let acct = rt.account else {
      notice(config.label("noAccount", "Add a SIP account first"))
      return nil
    }
    if calls.count >= 2 {
      notice(config.label("twoCallsMax", "You can have two calls at once"))
      return nil
    }
    for other in calls where other.phase == .active { hold(other) }
    do {
      let call = try acct.call(uriFor(rt.cfg, input))
      let number = Numbers.userPart(input)
      let ac = ActiveCall(id: callId(of: call), call: call, runtime: rt, incoming: false, number: number,
                          name: name ?? nameFor(number), phase: .outgoing)
      calls.append(ac)
      focused = ac
      push()
      pushState()
      CallScreenPresenter.present()
      return ac
    } catch {
      notice("\(config.label("callFailed", "Couldn't place the call")): \(error)")
      return nil
    }
  }

  private func refer(_ ac: ActiveCall, _ target: String) {
    ac.transferring = true
    do {
      try ac.call.transfer(to: Numbers.referUri(uriFor(ac.runtime.cfg, target)))
    } catch {
      notice("\(config.label("transferFailed", "Transfer failed")): \(error)")
    }
    armBackstop(ac)
    push()
  }

  private func armBackstop(_ ac: ActiveCall) {
    ac.backstop?.cancel()
    let w = DispatchWorkItem { [weak self, weak ac] in
      if let ac = ac, ac.transferring, self?.calls.contains(where: { $0 === ac }) == true { self?.hangup(ac) }
    }
    ac.backstop = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
  }

  func transferBlind(_ target: String) {
    guard let ac = focused, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    refer(ac, target)
  }

  func transferAttended(_ target: String) {
    guard let original = focused, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    dial(target, accountId: original.runtime.cfg.id, name: nil)?.transferOf = original
    push()
  }

  private func completeTransfer() {
    guard let consult = calls.first(where: { $0.transferOf != nil }), let original = consult.transferOf else { return }
    if consult.phase == .outgoing || consult.phase == .incoming {
      consult.transferOf = nil // its end must not take the caller off hold
      hangup(consult)
      refer(original, consult.number)
    } else {
      original.transferring = true
      do {
        try original.call.attendedTransfer(to: consult.call)
      } catch {
        notice("\(config.label("transferFailed", "Transfer failed")): \(error)")
      }
      armBackstop(original)
      push()
    }
  }

  private func onTransferRequest(_ e: TransferRequestEvent) {
    if e.autoFollowed { return }
    guard let c = e.call else { return }
    guard let old = find(c), let next = try? c.acceptTransfer() else {
      try? c.rejectTransfer()
      return
    }
    let number = Numbers.userPart(e.referToURI)
    let ac = ActiveCall(id: callId(of: next), call: next, runtime: old.runtime, incoming: false, number: number,
                        name: nameFor(number), phase: .outgoing)
    ac.replaces = old
    calls.append(ac)
    focused = ac
    push()
    pushState()
  }

  private func onTransferFailed(_ e: TransferFailedEvent) {
    if let c = e.call, let ac = find(c) {
      ac.backstop?.cancel()
      if let consult = calls.first(where: { $0.transferOf === ac }), !ac.semiTried {
        // The PBX would not join the two calls: a plain transfer instead.
        ac.semiTried = true
        consult.transferOf = nil
        hangup(consult)
        refer(ac, consult.number)
        return
      }
      ac.transferring = false
      if ac.phase == .held { resume(ac) }
      push()
    }
    let why = e.reason ?? ""
    notice(config.label("transferFailed", "Transfer failed") + (why.isEmpty ? "" : ": \(why)"))
  }

  /// Null when sent, else why not.
  func sendMessage(_ peer: String, _ body: String, accountId: String?) -> String? {
    guard let rt = accountFor(peer, accountId: accountId), let acct = rt.account else {
      return config.label("noAccount", "Add a SIP account first")
    }
    do {
      try acct.sendMessage(to: uriFor(rt.cfg, peer), body: body)
      history.addMessage(accountId: rt.cfg.id, peer: Numbers.userPart(peer), body: body, outgoing: true)
      MedutBridge.shared.toDart("historyChanged")
      return nil
    } catch {
      return "\(error)"
    }
  }

  // MARK: Names, numbers, notices

  func nameFor(_ number: String) -> String {
    if let w = config.watched.first(where: { $0.1 == number }) { return w.0 }
    if let n = names[number] { return n }
    var found = ""
    if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
      let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
      let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
      if let c = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys).first {
        found = CNContactFormatter.string(from: c, style: .fullName) ?? ""
      }
    }
    if names.count > 200 { names.removeAll() }
    names[number] = found
    return found
  }

  private func uriFor(_ cfg: AccountCfg, _ input: String) -> String {
    Numbers.uriFor(input, domain: cfg.domain, port: cfg.port, plusReplace: cfg.plusReplace, dialPrefix: cfg.dialPrefix)
  }

  private func notice(_ text: String) {
    MedutBridge.shared.toDart("notice", ["text": text])
  }

  /// A pop-up notification; the same [id] replaces the previous one.
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

  // MARK: Snapshot for the call screen, state for Flutter

  private func push() {
    updatePolicy()
    MedutBridge.shared.update(CallSnapshot(snapshot()))
    // Screen off at the ear: a live call on the earpiece.
    UIDevice.current.isProximityMonitoringEnabled = calls.contains { $0.phase != .incoming } && route == "earpiece"
  }

  private func fmt(_ v: Float, _ d: Int = 0) -> String { String(format: "%.\(d)f", v) }

  func snapshot() -> [String: Any] {
    let l = config
    var base: [String: Any] = ["dark": l.dark, "rtl": l.rtl]
    guard let f = focused ?? calls.first else {
      base["phase"] = "idle"
      return base
    }
    let other = calls.first { $0 !== f }
    let s = l.showCallQuality ? f.stats : nil
    var level = s.map { Quality.level(mos: Double($0.mosLQ), rtt: Double($0.rttMs), jitter: Double($0.jitterMs), loss: Double($0.lossPctRx)) } ?? 0
    if f.link != "ok" { level = 1 }
    var second: [String: Any]?
    if let o = other {
      if o.phase == .incoming {
        second = ["name": o.title, "text": "↙ \(o.title)",
                  "label": l.label("answer", "Answer"), "action": "answerWaiting"]
      } else if f.transferOf === o {
        second = ["name": o.title, "text": "\(o.title) · \(l.label("onHold", "On hold"))",
                  "label": l.label("complete", "Complete"), "action": "completeTransfer"]
      } else {
        second = ["name": o.title, "text": "\(o.title) · \(l.label("onHold", "On hold"))",
                  "label": l.label("swap", "Swap"), "action": "swap"]
      }
    }
    var transfer: [String: Any]?
    if let consult = calls.first(where: { c in c.transferOf.map { t in calls.contains { $0 === t } } ?? false }) {
      let talking = consult.phase == .active
      transfer = [
        "phase": talking ? "talking" : "calling",
        "status": talking ? l.label("xferConnectedTo", "Connected to {name}", ["name": consult.title])
          : l.label("xferCalling", "Calling {name}…", ["name": consult.title]),
        "hint": talking ? l.label("xferHintTalking", "Join & drop connects them and you leave the call.")
          : l.label("xferHintCalling", "Your caller is on hold and can't hear this."),
        "join": l.label("xferJoin", "Join & drop"),
        "back": l.label("xferBack", "Back to caller"),
      ]
    }
    let status: String
    if f.transferring {
      status = l.label("transferring", "Transferring…")
    } else {
      switch f.phase {
      case .outgoing: status = f.remoteRinging ? l.label("ringing", "Ringing") : l.label("calling", "Calling…")
      case .held: status = l.label("onHold", "On hold")
      default:
        status = f.link == "reconnecting" ? l.label("reconnecting", "Reconnecting…")
          : f.link == "weak" ? l.label("poorConnection", "Poor connection")
          : f.recording ? l.label("recordingNow", "This call is being recorded") : ""
      }
    }
    let cfg = f.runtime.cfg
    var details: [[String]] = []
    if let s = s {
      details = [
        [l.label("qJitter", "Jitter"), "\(fmt(s.jitterMs)) ms"],
        [l.label("qLoss", "Packet loss"), "\(fmt(s.lossPct, 1)) %"],
        [l.label("qRtt", "Round trip"), "\(fmt(s.rttMs)) ms"],
        [l.label("qCodec", "Codec"), "\(s.codecName) \(s.codecClockRate / 1000) kHz"],
        [l.label("qSrtp", "Encryption"), f.crypto.isEmpty ? l.label("encNone", "None") : f.crypto],
        [l.label("qIce", "Network path"), "\(s.iceLocalType)"],
        [l.label("qJbuf", "Jitter buffer"), "\(s.jitterBufferMs) ms"],
        [l.label("connection", "Connection"), "\(cfg.transport.uppercased()) · \(cfg.domain)"],
      ]
    }
    var d = base
    d["transfer"] = transfer
    d["phase"] = f.phase.rawValue
    d["callId"] = f.id
    d["name"] = f.name
    d["number"] = f.number
    d["account"] = "\(cfg.label) · \(cfg.user)"
    d["accountId"] = cfg.id
    d["status"] = status
    d["link"] = f.link
    d["canRecord"] = l.recordingMode != "off" || f.recording
    d["startedAt"] = f.answeredAt.map { $0.timeIntervalSince1970 * 1000 } ?? 0
    d["outgoing"] = !f.incoming
    d["muted"] = f.muted
    d["held"] = f.phase == .held
    d["route"] = route
    d["bluetooth"] = routes.contains { $0.kind == .bluetooth || $0.kind == .wiredHeadset }
    d["routes"] = routes.map { r -> [String: Any] in
      let k = kindName(r.kind)
      let name = r.name.isEmpty ? l.label(k == "wired" ? "headset" : k, k) : r.name
      return ["id": r.id, "kind": k, "name": name]
    }
    d["recording"] = f.recording
    var mos = "", mosYou = "", mosThem = ""
    if let s = s {
      mos = fmt(s.mosLQ, 1)
      if s.mosLQ > 0 { mosYou = fmt(s.mosLQ, 1) }
      if s.mosLQRx > 0 { mosThem = fmt(s.mosLQRx, 1) }
    }
    d["mos"] = mos
    d["mosYou"] = mosYou
    d["mosThem"] = mosThem
    d["encrypted"] = !f.crypto.isEmpty
    d["qualityLevel"] = level
    d["qualityWord"] = l.showCallQuality && f.phase == .active ? l.label(Quality.wordKey(level), Quality.wordFallback(level)) : ""
    d["quality"] = level >= 3 ? "good" : level == 2 ? "fair" : level == 1 ? "poor" : ""
    d["details"] = details
    d["second"] = second
    return d
  }

  private var statePosted = false

  /// Sends Flutter what its tabs show, once per main-queue turn at most.
  func pushState() {
    if statePosted { return }
    statePosted = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.statePosted = false
      MedutBridge.shared.toDart("state", self.state())
    }
  }

  func state() -> [String: Any] {
    [
      "accounts": runtimes.mapValues { rt -> [String: Any] in
        ["status": rt.status, "error": rt.error, "sipCode": rt.sipCode, "retryInMs": rt.retryInMs,
         "mwiNew": rt.mwiNew, "mwiOld": rt.mwiOld, "mwiUrgent": rt.mwiUrgent, "probe": rt.probe]
      },
      "calls": calls.map { c -> [String: Any] in
        ["id": c.id, "accountId": c.runtime.cfg.id, "number": c.number, "name": c.name, "phase": c.phase.rawValue,
         "answeredAt": c.answeredAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0]
      },
      "focused": focused?.id as Any,
      "presence": presence,
      "version": sdkUp ? Medut.version : "",
      "connSeq": EngineLog.seq("conn"),
      "sipSeq": EngineLog.seq("sip"),
    ]
  }
}
