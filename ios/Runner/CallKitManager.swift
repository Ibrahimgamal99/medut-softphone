import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

/// CallKit + PushKit.
///
/// iOS gives a backgrounded app no time to keep a SIP registration alive, so a
/// closed app is woken by a VoIP push: the PBX (or a proxy in front of it) sends
/// one to the token we put in the REGISTER Contact (RFC 8599 pn-* params).
/// Apple requires every VoIP push to be reported to CallKit at once, before
/// the SIP INVITE has even arrived, so the call starts life as a "pending"
/// CallKit call and is bound to the real SIP call when Dart reports it.
final class CallKitManager: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
  static let shared = CallKitManager()

  private var provider: CXProvider
  private let controller = CXCallController()
  private var registry: PKPushRegistry?

  /// SIP call id ↔ CallKit UUID.
  private var uuids: [String: UUID] = [:]
  /// A push-reported call still waiting for its INVITE.
  private var pendingPush: UUID?
  private var pendingAnswer = false
  private var pendingDecline = false
  private var pendingTimer: Timer?
  private var connectedOutgoing: Set<String> = []

  private(set) var pushToken: String?

  var pushTokenInfo: [String: Any]? {
    guard let t = pushToken else { return nil }
    #if DEBUG
      return ["token": t, "provider": "apnsSandbox"]
    #else
      return ["token": t, "provider": "apns"]
    #endif
  }

  private override init() {
    provider = CXProvider(configuration: CallKitManager.configuration(ringtone: nil))
    super.init()
    provider.setDelegate(self, queue: .main)
  }

  private static func configuration(ringtone: String?) -> CXProviderConfiguration {
    let config = CXProviderConfiguration()
    config.ringtoneSound = ringtone
    config.supportsVideo = false
    config.maximumCallGroups = 2
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic, .phoneNumber]
    config.includesCallsInRecents = true
    if let icon = UIImage(systemName: "phone.fill")?.pngData() {
      config.iconTemplateImageData = icon
    }
    return config
  }

  /// The ringtone picked in Medut. Bundled tones ship in the app bundle as
  /// medut_<id>.wav; a file of the user's own is copied to Library/Sounds.
  func setRingtone(path: String?) {
    var sound: String?
    if let path = path {
      let file = (path as NSString).lastPathComponent
      if path.contains("/tones/"), Bundle.main.path(forResource: "medut_" + file, ofType: nil) != nil {
        sound = "medut_" + file
      } else if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
        let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
        let dest = dir.appendingPathComponent("medut_custom." + (file as NSString).pathExtension)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dest)) != nil {
          sound = dest.lastPathComponent
        }
      }
    }
    provider.configuration = CallKitManager.configuration(ringtone: sound)
  }

  func startPushKit() {
    let r = PKPushRegistry(queue: .main)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    registry = r
  }

  // MARK: Dart snapshots → CallKit

  func sync(prev: CallSnapshot, next: CallSnapshot) {
    let newCall = next.callId != prev.callId && !next.callId.isEmpty
    switch next.phase {
    case "incoming" where newCall:
      reportIncoming(next)
    case "outgoing" where newCall:
      startOutgoing(next)
    case "active":
      if let uuid = uuids[next.callId], next.outgoing, !connectedOutgoing.contains(next.callId) {
        connectedOutgoing.insert(next.callId)
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
      }
    case "ended", "idle":
      endAll(except: next.isLive ? next.callId : nil)
    default:
      break
    }
    if !next.callId.isEmpty, let uuid = uuids[next.callId], next.title != prev.title {
      let update = CXCallUpdate()
      update.localizedCallerName = next.title
      update.remoteHandle = CXHandle(type: .generic, value: next.number.isEmpty ? next.title : next.number)
      provider.reportCall(with: uuid, updated: update)
    }
  }

  private func reportIncoming(_ s: CallSnapshot) {
    // A push already put this call on screen: bind it instead of ringing twice.
    if let uuid = pendingPush {
      pendingPush = nil
      pendingTimer?.invalidate()
      uuids[s.callId] = uuid
      if pendingDecline {
        pendingDecline = false
        MedutBridge.shared.action("decline", callId: s.callId)
      } else if pendingAnswer {
        pendingAnswer = false
        MedutBridge.shared.action("answer", callId: s.callId)
      }
      return
    }
    let uuid = UUID()
    uuids[s.callId] = uuid
    provider.reportNewIncomingCall(with: uuid, update: callUpdate(s)) { error in
      if let error = error {
        NSLog("MEDUT_CALLKIT incoming refused: \(error.localizedDescription)")
        // Do-not-disturb or blocked: CallKit will not ring, so decline the SIP leg.
        MedutBridge.shared.action("decline", callId: s.callId)
      }
    }
  }

  private func startOutgoing(_ s: CallSnapshot) {
    let uuid = UUID()
    uuids[s.callId] = uuid
    let handle = CXHandle(type: .generic, value: s.number.isEmpty ? s.title : s.number)
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.contactIdentifier = s.name
    controller.request(CXTransaction(action: action)) { error in
      if let error = error { NSLog("MEDUT_CALLKIT start refused: \(error.localizedDescription)") }
    }
  }

  private func endAll(except keep: String?) {
    for (callId, uuid) in uuids where callId != keep {
      provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      uuids.removeValue(forKey: callId)
      connectedOutgoing.remove(callId)
    }
  }

  private func callUpdate(_ s: CallSnapshot) -> CXCallUpdate {
    let u = CXCallUpdate()
    u.remoteHandle = CXHandle(type: .generic, value: s.number.isEmpty ? s.title : s.number)
    u.localizedCallerName = s.title
    u.hasVideo = false
    u.supportsHolding = true
    u.supportsDTMF = true
    u.supportsGrouping = false
    u.supportsUngrouping = false
    return u
  }

  private func callId(for uuid: UUID) -> String? {
    uuids.first { $0.value == uuid }?.key
  }

  // MARK: CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {
    for callId in uuids.keys { MedutBridge.shared.action("hangup", callId: callId) }
    uuids.removeAll()
    pendingPush = nil
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    if let id = callId(for: action.callUUID) {
      MedutBridge.shared.action("answer", callId: id)
    } else if action.callUUID == pendingPush {
      pendingAnswer = true  // the INVITE is still on its way
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let id = callId(for: action.callUUID) {
      let ringing = MedutBridge.shared.latest.callId == id && MedutBridge.shared.latest.phase == "incoming"
      MedutBridge.shared.action(ringing ? "decline" : "hangup", callId: id)
      uuids.removeValue(forKey: id)
    } else if action.callUUID == pendingPush {
      pendingDecline = true
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    if let id = callId(for: action.callUUID) {
      MedutBridge.shared.action(action.isOnHold ? "hold" : "unhold", callId: id)
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let id = callId(for: action.callUUID) {
      MedutBridge.shared.action(action.isMuted ? "mute" : "unmute", callId: id)
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    if let id = callId(for: action.callUUID) {
      for ch in action.digits {
        MedutBridge.shared.action("dtmf", callId: id, extra: ["digit": String(ch)])
      }
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    MedutBridge.shared.toDart("callkitAudio", ["active": true])
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    MedutBridge.shared.toDart("callkitAudio", ["active": false])
  }

  // MARK: PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    pushToken = credentials.token.map { String(format: "%02x", $0) }.joined()
    if let info = pushTokenInfo { MedutBridge.shared.toDart("pushToken", info) }
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    pushToken = nil
    MedutBridge.shared.toDart("pushToken", nil)
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                    for type: PKPushType, completion: @escaping () -> Void) {
    let data = payload.dictionaryPayload
    // Push senders differ (PBX module, proxy, gateway): take the caller from
    // the common keys and fall back to a plain "Incoming call".
    func pick(_ keys: [String]) -> String {
      for k in keys {
        if let v = data[k] as? String, !v.isEmpty { return v }
        if let aps = data["aps"] as? [String: Any], let v = aps[k] as? String, !v.isEmpty { return v }
      }
      return ""
    }
    let number = pick(["caller", "from", "caller_id", "number", "handle"])
    let name = pick(["caller_name", "display_name", "name"])
    let shown = name.isEmpty ? (number.isEmpty ? "Incoming call" : number) : name

    // A live SIP call already exists (push arrived late): nothing new to ring.
    if MedutBridge.shared.latest.isLive || pendingPush != nil {
      completion()
      return
    }

    let uuid = UUID()
    pendingPush = uuid
    pendingAnswer = false
    pendingDecline = false
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: number.isEmpty ? shown : number)
    update.localizedCallerName = shown
    update.hasVideo = false
    provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion() }

    // Wake Dart's SIP stack right away so it re-registers and gets the INVITE.
    MedutBridge.shared.toDart("voipPush", data.reduce(into: [String: Any]()) { acc, kv in
      if let k = kv.key as? String { acc[k] = "\(kv.value)" }
    })

    // No INVITE within 25 s (caller hung up, registration failed): stop ringing.
    pendingTimer?.invalidate()
    pendingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
      guard let self = self, self.pendingPush == uuid else { return }
      self.pendingPush = nil
      self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
    }
  }
}
