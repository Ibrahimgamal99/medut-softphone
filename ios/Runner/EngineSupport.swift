import AVFoundation
import Foundation
import Security
import SQLite3
import UIKit
import medut

// The engine's settings, accounts, history and helpers: the Swift twins of
// android/…/engine/*.kt. Keep the two in step.

/// "Numbers matching [pattern] go out through [accountId]": X is any digit, else a prefix.
struct DialRule {
  let pattern: String
  let accountId: String

  func matches(_ number: String) -> Bool {
    let n = Array(number.replacingOccurrences(of: "[\\s\\-()]", with: "", options: .regularExpression))
    let p = Array(pattern)
    if !pattern.contains("X") { return String(n).hasPrefix(pattern) }
    if n.count != p.count { return false }
    for i in 0..<n.count {
      if p[i] == "X" {
        if !n[i].isNumber { return false }
      } else if p[i] != n[i] {
        return false
      }
    }
    return true
  }
}

/// The app settings the engine works from, as Dart last pushed them
/// (`setConfig`) and kept across launches, so a call that rings with no
/// Flutter UI follows the same rules and speaks the same language.
struct EngineConfig {
  let raw: [String: Any]

  init(_ raw: [String: Any] = [:]) { self.raw = raw }

  private func s(_ k: String, _ d: String) -> String { raw[k] as? String ?? d }
  private func b(_ k: String, _ d: Bool) -> Bool { (raw[k] as? NSNumber)?.boolValue ?? (raw[k] as? Bool) ?? d }
  private func i(_ k: String, _ d: Int) -> Int { (raw[k] as? NSNumber)?.intValue ?? d }
  private func strings(_ k: String) -> [String] { (raw[k] as? [Any])?.compactMap { $0 as? String } ?? [] }

  /// Translated text from Dart's string table, so native and Flutter share one.
  func label(_ key: String, _ fallback: String, _ args: [String: String] = [:]) -> String {
    var t = (raw["labels"] as? [String: Any])?[key] as? String ?? ""
    if t.isEmpty { t = fallback }
    for (k, v) in args { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
    return t
  }

  var dark: Bool { b("dark", false) }
  var rtl: Bool { b("rtl", false) }
  var codecs: [String] { strings("codecs").isEmpty ? ["alaw", "ulaw", "opus"] : strings("codecs") }
  var jitterMode: String { s("jitterMode", "auto") }
  var aecMode: Int { i("aecMode", 2) }
  var noiseSuppression: Bool { b("ns", true) }
  var autoGain: Bool { b("agc", true) }
  var forceRelay: Bool { b("forceRelay", false) }
  var regExpires: Int { i("regExpires", 300) }
  var keepaliveSec: Int { i("keepaliveSec", 30) }
  var debugLogging: Bool { b("debugLogging", false) }
  var traceSip: Bool { b("traceSip", true) }
  var iceServers: [ICEServer] {
    (raw["iceServers"] as? [[String: Any]] ?? []).compactMap { o in
      let url = (o["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      if url.isEmpty { return nil }
      func opt(_ k: String) -> String? {
        let v = (o[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
      }
      return ICEServer(url: url, username: opt("user"), password: opt("pass"))
    }
  }
  /// A file path, or "system".
  var ringtone: String { s("ringtone", "system") }
  var vibrate: Bool { b("vibrate", true) }
  var ringback: Bool { b("ringback", true) }
  var autoAnswer: Bool { b("autoAnswer", false) }
  var autoAnswerDelay: Int { i("autoAnswerDelay", 3) }
  var showCallQuality: Bool { b("showCallQuality", true) }
  var blocked: Set<String> { Set(strings("blocked")) }
  var status: String { s("status", "available") }
  var officeHours: Bool { b("officeHours", false) }
  var officeDays: [Int] { s("officeDays", "7,1,2,3,4").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
  var officeStart: String { s("officeStart", "09:00") }
  var officeEnd: String { s("officeEnd", "17:00") }
  var letFavourites: Bool { b("letFavourites", true) }
  var letRepeat: Bool { b("letRepeat", true) }
  var favourites: Set<String> { Set(strings("favourites")) }
  /// Colleagues on the Team list: (name, extension).
  var watched: [(String, String)] {
    (raw["watched"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["ext"] as? String ?? "") }
  }
  var recordingMode: String { s("recordingMode", "manual") }
  var recordingDir: String { s("recordingDir", "") }
  var dialRules: [DialRule] {
    (raw["dialRules"] as? [[String: Any]] ?? []).map {
      DialRule(pattern: $0["pattern"] as? String ?? "", accountId: $0["accountId"] as? String ?? "")
    }
  }
  var activitySeenAt: Double { (raw["activitySeenAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000 }

  /// The status in force now: Do not disturb outside office hours when that
  /// switch is on, otherwise the one the user picked.
  func effectiveStatus(_ now: Date = Date()) -> String {
    if !officeHours { return status }
    func mins(_ hhmm: String) -> Int {
      let p = hhmm.split(separator: ":").map { Int($0) ?? 0 }
      return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
    // Calendar: Sunday 1 … Saturday 7; Dart: Monday 1 … Sunday 7.
    let weekday = (c.weekday ?? 1) == 1 ? 7 : (c.weekday ?? 1) - 1
    let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    let inHours = m >= mins(officeStart) && m < mins(officeEnd)
    return officeDays.contains(weekday) && inHours ? status : "dnd"
  }

  private static let defaultsKey = "medut.engine.config"

  static func load() -> EngineConfig {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return EngineConfig() }
    return EngineConfig(raw)
  }

  static func save(_ raw: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: raw) {
      UserDefaults.standard.set(data, forKey: defaultsKey)
    }
  }
}

/// Status feature codes as each PBX ships them (kPbxPresets in lib/core/accounts.dart).
private let pbxPresets: [String: [String: String]] = [
  "freepbx": ["dndOn": "*78", "dndOff": "*79", "queueLogin": "*45", "queueLogout": "*45"],
  "fusionpbx": ["dndOn": "*78", "dndOff": "*79", "queueLogin": "*22", "queueLogout": "*22"],
  "3cx": ["dndOn": "", "dndOff": "", "queueLogin": "*62", "queueLogout": "*63"],
]

/// One SIP account as the user configured it: the JSON of Dart's
/// `SipAccountConfig.toJson()` plus `password` and `turnPass`.
struct AccountCfg {
  let json: [String: Any]

  private func s(_ k: String, _ d: String = "") -> String { json[k] as? String ?? d }
  private func b(_ k: String, _ d: Bool) -> Bool { (json[k] as? NSNumber)?.boolValue ?? (json[k] as? Bool) ?? d }

  var id: String { s("id") }
  var name: String { s("name") }
  var user: String { s("user") }
  var domain: String { s("domain") }
  var password: String { s("password") }
  var transport: String { s("transport", "udp") }
  var port: Int { (json["port"] as? NSNumber)?.intValue ?? 0 }
  var serverUrl: String { s("serverUrl") }
  var authUser: String { s("authUser") }
  var displayName: String { s("displayName") }
  var outboundProxy: String { s("outboundProxy") }
  var mediaEnc: String { s("mediaEnc", "none") }
  var ice: Bool { b("ice", false) }
  var stun: String { s("stun") }
  var turn: String { s("turn") }
  var turnUser: String { s("turnUser") }
  var turnPass: String { s("turnPass") }
  var verifyTls: Bool { b("verifyTls", true) }
  var enabled: Bool { b("enabled", true) }
  var isDefault: Bool { b("isDefault", false) }
  var push: Bool { b("push", true) }
  var dtmf: String { s("dtmf", "rfc4733") }
  var recordCalls: Bool { b("recordCalls", true) }
  var dialPrefix: String { s("dialPrefix") }
  var plusReplace: String { s("plusReplace") }
  var headers: String { s("headers") }
  var pbx: String { s("pbx", "freepbx") }

  var aor: String { port > 0 ? "\(user)@\(domain):\(port)" : "\(user)@\(domain)" }
  var label: String { name.isEmpty ? domain : name }

  func code(_ key: String) -> String {
    if let own = json["codes"] as? [String: Any], let v = own[key] as? String { return v }
    return pbxPresets[pbx]?[key] ?? ""
  }

  /// The app-wide codec order, except that a web link puts Opus first.
  func codecsFrom(_ order: [String]) -> [String] {
    transport == "ws" || transport == "wss" ? ["opus"] + order.filter { $0 != "opus" } : order
  }

  /// What the SDK account is built from: a change here re-creates it.
  func signature(_ config: EngineConfig, pushProvider: String) -> String {
    var j = json
    for k in ["name", "isDefault", "voicemail", "recordCalls", "dialPrefix", "plusReplace", "pbx", "codes"] {
      j.removeValue(forKey: k)
    }
    let body = (try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let ice = config.iceServers.map { "\($0.url)|\($0.username ?? "")|\($0.password ?? "")" }.joined(separator: ",")
    return "\(body)|\(push ? pushProvider : "")|\(ice)|\(config.forceRelay)|\(config.codecs)"
  }

  func toSDK(_ config: EngineConfig, pushProvider: PushProvider, pushToken: String?) -> AccountConfig {
    func opt(_ v: String) -> String? {
      let t = v.trimmingCharacters(in: .whitespaces)
      return t.isEmpty ? nil : t
    }
    var c = AccountConfig(uri: aor, password: password)
    let transports: [String: Transport] = ["tcp": .tcp, "tls": .tls, "ws": .ws, "wss": .wss]
    c.transport = transports[transport] ?? .udp
    c.serverURL = transport == "ws" || transport == "wss" ? opt(serverUrl) : nil
    c.authUser = opt(authUser)
    c.displayName = opt(displayName)
    c.outboundProxy = opt(outboundProxy)
    c.mediaEncryption = mediaEnc == "sdes" ? .sdes : mediaEnc == "dtls" ? .dtlsSRTP : .none
    c.iceEnabled = ice
    c.stunServer = opt(stun)
    c.turnServer = opt(turn)
    c.turnUser = opt(turnUser)
    c.turnPass = opt(turnPass)
    c.iceServers = config.iceServers
    c.iceTransportPolicy = config.forceRelay ? .relay : .all
    c.verifyTLS = verifyTls
    let usePush = push && pushToken != nil && pushProvider != .none
    c.pushProvider = usePush ? pushProvider : .none
    c.pushToken = usePush ? pushToken : nil
    c.audioCodecs = codecsFrom(config.codecs)
    c.dtmfMode = dtmf == "info" ? .sipInfo : dtmf == "auto" ? .auto : .rfc4733
    return c
  }

  /// "Name: value" lines of [headers].
  func headerPairs() -> [(String, String)] {
    headers.split(separator: "\n").compactMap { line in
      guard let i = line.firstIndex(of: ":"), i != line.startIndex else { return nil }
      return (line[..<i].trimmingCharacters(in: .whitespaces),
              line[line.index(after: i)...].trimmingCharacters(in: .whitespaces))
    }
  }
}

/// The accounts, kept by native so a VoIP push can register them with no
/// Flutter UI: one Keychain item (the SIP and TURN passwords are in it).
final class AccountRepository {
  private let service = "com.medut.app.accounts"
  private var cache: [AccountCfg]?

  func all() -> [AccountCfg] {
    if let c = cache { return c }
    let list = read()
    cache = list
    return list
  }

  func replace(_ list: [AccountCfg]) {
    write(list.map { $0.json })
    cache = list
  }

  func byId(_ id: String?) -> AccountCfg? { all().first { $0.id == id } }

  func defaultAccount() -> AccountCfg? {
    let enabled = all().filter { $0.enabled }
    return enabled.first { $0.isDefault } ?? enabled.first
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: "accounts"]
  }

  private func read() -> [AccountCfg] {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list.map(AccountCfg.init(json:))
  }

  private func write(_ list: [[String: Any]]) {
    guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
    let attrs: [String: Any] = [kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
      var add = query
      add.merge(attrs) { $1 }
      SecItemAdd(add as CFDictionary, nil)
    }
  }
}

/// Writes finished calls and SIP messages into `medut.db`, the database the
/// Flutter history screens read (lib/core/db.dart, sqflite's Documents/).
/// Dart owns the schema; the app is opened before any account exists, so the
/// file is there by the time a call can be written.
final class HistoryWriter {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private func open() -> OpaquePointer? {
    if let db = db { return db }
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let path = docs.appendingPathComponent("medut.db").path
    guard FileManager.default.fileExists(atPath: path) else {
      NSLog("Medut: medut.db not created yet; nothing written")
      return nil
    }
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      sqlite3_close(handle)
      return nil
    }
    // sqflite holds its own connection to the same file.
    sqlite3_busy_timeout(handle, 3000)
    db = handle
    return handle
  }

  /// Inserts [row] (column → Int, Double, String or nil) into [table].
  @discardableResult
  func insert(_ table: String, _ row: [String: Any?]) -> Bool {
    guard let db = open() else { return false }
    let cols = Array(row.keys)
    let sql = "INSERT INTO \(table) (\(cols.joined(separator: ","))) VALUES (\(cols.map { _ in "?" }.joined(separator: ",")))"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    for (i, k) in cols.enumerated() {
      let idx = Int32(i + 1)
      switch row[k] ?? nil {
      case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
      case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
      case let v as Double: sqlite3_bind_double(stmt, idx, v)
      case let v as Float: sqlite3_bind_double(stmt, idx, Double(v))
      case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
      default: sqlite3_bind_null(stmt, idx)
      }
    }
    return sqlite3_step(stmt) == SQLITE_DONE
  }

  func addMessage(accountId: String, peer: String, body: String, outgoing: Bool) {
    insert("messages", ["account_id": accountId, "peer": peer, "body": body, "outgoing": outgoing ? 1 : 0,
                        "at": Int(Date().timeIntervalSince1970 * 1000), "read": outgoing ? 1 : 0])
  }

  private func count(_ sql: String, _ args: [String]) -> Int {
    guard let db = open() else { return 0 }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) }
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
  }

  func missedSince(_ since: Double) -> Int {
    count("SELECT COUNT(*) FROM calls WHERE result='missed' AND started_at > ?", [String(Int64(since))])
  }

  /// [calledRecently] on a connection of its own, for the SDK's event
  /// thread (the incoming-call filter).
  static func calledRecentlyReadOnly(_ number: String) -> Bool {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
    var db: OpaquePointer?
    guard sqlite3_open_v2(docs.appendingPathComponent("medut.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return false
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 1000)
    var stmt: OpaquePointer?
    let sql = "SELECT COUNT(*) FROM calls WHERE number = ? AND started_at > ?"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, number, -1, transient)
    sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000) - 3 * 60 * 1000)
    return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) > 0
  }

  /// Two calls from the same number within 3 minutes: "repeat caller".
  func calledRecently(_ number: String) -> Bool {
    let since = Int64(Date().timeIntervalSince1970 * 1000) - 3 * 60 * 1000
    return count("SELECT COUNT(*) FROM calls WHERE number = ? AND started_at > ?", [number, String(since)]) > 0
  }
}

/// Call quality grade 0–4 (lib/sip/quality.dart and Quality.kt: keep the three the same).
enum Quality {
  static func level(mos: Double?, rtt: Double?, jitter: Double?, loss: Double?) -> Int {
    var byMos: Int?
    if let m = mos, m > 0 { byMos = m >= 4.3 ? 4 : m >= 3.6 ? 3 : m >= 3.1 ? 2 : 1 }
    var measured = 0
    var misses = 0
    func judge(_ v: Double?, _ target: Double) {
      guard let v = v else { return }
      measured += 1
      if v >= target * 2 { misses += 2 } else if v >= target { misses += 1 }
    }
    judge(rtt, 150)
    judge(jitter, 20)
    judge(loss, 1)
    let byNetwork: Int? = measured == 0 ? nil : (misses == 0 ? 4 : misses == 1 ? 2 : 1)
    // Excellent needs a MOS: clean counters alone are not evidence of one.
    guard let mosGrade = byMos else { return byNetwork.map { min($0, 3) } ?? 0 }
    guard let net = byNetwork else { return mosGrade }
    return min(mosGrade, net)
  }

  static func wordKey(_ level: Int) -> String {
    ["signalChecking", "signalPoor", "signalFair", "signalGood", "signalExcellent"][max(0, min(4, level))]
  }

  static func wordFallback(_ level: Int) -> String {
    ["Checking…", "Poor", "Fair", "Good", "Excellent"][max(0, min(4, level))]
  }
}

/// Numbers and SIP addresses, written the way lib/sip/sip_service.dart does.
enum Numbers {
  private static func replacing(_ s: String, _ pattern: String, _ with: String = "") -> String {
    s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
  }

  /// "sip:201@pbx;transport=tls" or "Sara <sip:201@pbx>" -> "201".
  static func userPart(_ uri: String) -> String {
    var s = replacing(replacing(uri, "^.*<"), ">.*$")
    s = replacing(s, "^sips?:")
    if let at = s.firstIndex(of: "@"), at != s.startIndex { return String(s[..<at]) }
    return s
  }

  static func uriFor(_ input: String, domain: String, port: Int, plusReplace: String, dialPrefix: String) -> String {
    var s = replacing(input.trimmingCharacters(in: .whitespaces), "^sips?:")
    if s.contains("@") { return s }
    s = replacing(s, "[\\s\\-().]")
    if s.hasPrefix("+") && !plusReplace.isEmpty { s = plusReplace + s.dropFirst() }
    // The line-out prefix is for outside numbers, not extensions or codes.
    if !dialPrefix.isEmpty && s.range(of: "^\\+?\\d{7,}$", options: .regularExpression) != nil { s = dialPrefix + s }
    return port > 0 ? "\(s)@\(domain):\(port)" : "\(s)@\(domain)"
  }

  /// The Refer-To of a transfer: a full sip: URI.
  static func referUri(_ uri: String) -> String {
    uri.range(of: "^sips?:", options: [.regularExpression, .caseInsensitive]) != nil ? uri : "sip:\(uri)"
  }

  /// The same number however it is written: the last nine digits.
  static func sameNumber(_ a: String, _ b: String) -> Bool {
    func tail(_ n: String) -> String {
      let d = n.filter { $0.isNumber }
      return d.count > 9 ? String(d.suffix(9)) : d
    }
    let x = tail(a)
    return !x.isEmpty && x == tail(b)
  }
}

/// Call recordings: names, and fixing the WAV header of one the SDK left unfinished.
enum Recordings {
  static func dir(_ config: EngineConfig) -> URL {
    if !config.recordingDir.isEmpty { return URL(fileURLWithPath: config.recordingDir) }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("Recordings", isDirectory: true)
  }

  /// `201 Sara_261013_182405.wav`, the way the phone's own recorder names them.
  static func name(number: String, name: String, at: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyMMdd_HHmmss"
    var who: [String] = []
    for p in [number.trimmingCharacters(in: .whitespaces), name.trimmingCharacters(in: .whitespaces)]
      where !p.isEmpty && !who.contains(p) { who.append(p) }
    var safe = who.joined(separator: " ")
      .replacingOccurrences(of: "[\\\\/:*?\"<>|\\x00-\\x1f]+", with: "_", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "^[_\\s]+|[_\\s]+$", with: "", options: .regularExpression)
    return "\(safe.isEmpty ? "call" : safe)_\(f.string(from: at)).wav"
  }

  static func repairWav(_ path: String) {
    guard !path.isEmpty, let h = FileHandle(forUpdatingAtPath: path) else { return }
    defer { try? h.close() }
    let len = h.seekToEndOfFile()
    guard len >= 44 else { return }
    h.seek(toFileOffset: 0)
    let head = [UInt8](h.readData(ofLength: 44))
    func tag(_ at: Int) -> String { String(bytes: head[at..<at + 4], encoding: .ascii) ?? "" }
    guard head.count == 44, tag(0) == "RIFF", tag(8) == "WAVE", tag(36) == "data" else { return }
    func u32(_ at: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(head[at + $1]) << (8 * UInt64($1)) } }
    let align = UInt64(max(1, min(64, Int(head[32]) | Int(head[33]) << 8)))
    let data = ((len - 44) / align) * align
    if u32(40) == data && u32(4) == 36 + data { return }
    func le(_ v: UInt64) -> Data { Data((0..<4).map { UInt8((v >> (8 * UInt64($0))) & 0xff) }) }
    h.seek(toFileOffset: 4)
    h.write(le(36 + data))
    h.seek(toFileOffset: 40)
    h.write(le(data))
  }

  static func wavSeconds(_ path: String) -> Int? {
    guard !path.isEmpty, let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let head = [UInt8](h.readData(ofLength: 44))
    guard head.count == 44 else { return nil }
    let byteRate = Int(head[28]) | Int(head[29]) << 8 | Int(head[30]) << 16 | Int(head[31]) << 24
    let len = Int(h.seekToEndOfFile())
    return byteRate > 0 ? (len - 44) / byteRate : nil
  }
}

/// The connection log and the SIP trace (Settings → Diagnostics), with
/// sequence numbers so Flutter fetches only what it has not seen.
enum EngineLog {
  private final class Ring {
    let max: Int
    var lines: [String] = []
    var seq = 0
    init(_ max: Int) { self.max = max }
    func add(_ l: String) {
      lines.append(l)
      seq += 1
      if lines.count > max { lines.removeFirst(lines.count - max) }
    }
  }

  private static let conn = Ring(500)
  private static let sip = Ring(400)
  private static let lock = NSLock()

  static func conn(_ line: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    lock.lock()
    defer { lock.unlock() }
    conn.add("\(f.string(from: Date()))  \(line)")
  }

  static func sip(_ entry: String) {
    lock.lock()
    defer { lock.unlock() }
    sip.add(entry)
  }

  static func seq(_ kind: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return (kind == "sip" ? sip : conn).seq
  }

  static func read(_ kind: String, since: Int) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let r = kind == "sip" ? sip : conn
    let reset = since <= 0 || since > r.seq || r.seq - since > r.lines.count
    return ["seq": r.seq, "lines": reset ? r.lines : Array(r.lines.suffix(r.seq - since)), "reset": reset]
  }
}

/// The ringback while the far end rings, in the call's own audio session.
enum Ringback {
  private static var player: AVAudioPlayer?

  static func start() {
    guard player == nil, let url = Bundle.main.url(forResource: "ringback", withExtension: "wav") else { return }
    let p = try? AVAudioPlayer(contentsOf: url)
    p?.numberOfLoops = -1
    p?.play()
    player = p
  }

  static func stop() {
    player?.stop()
    player = nil
  }
}

/// What the app keeps, on Android's terms (allowBackup off,
/// res/xml/data_extraction_rules.xml): nothing goes into an iCloud or
/// computer backup, and a new install starts empty.
enum AppData {
  private static let installedKey = "medut.installed"

  /// didFinishLaunching, before the engine reads the accounts.
  static func prepare() {
    // Before the first unlock after a restart (a VoIP push can launch the app
    // then) neither the defaults nor the Keychain can be read: leave both be.
    guard UIApplication.shared.isProtectedDataAvailable else { return }
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: installedKey) {
      // The Keychain outlives an uninstall on iOS, so an earlier install's
      // accounts and passwords would come back. The defaults and Documents go
      // with the app: both empty is a new install, not an update from a build
      // without this mark.
      if !hasLocalData() { wipeKeychain() }
      defaults.set(true, forKey: installedKey)
    }
    excludeFromBackup()
  }

  private static func hasLocalData() -> Bool {
    if let id = Bundle.main.bundleIdentifier,
       let d = UserDefaults.standard.persistentDomain(forName: id), !d.isEmpty { return true }
    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
          let items = try? fm.contentsOfDirectory(atPath: docs.path) else { return false }
    return !items.isEmpty
  }

  private static func wipeKeychain() {
    for cls in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey,
                kSecClassCertificate, kSecClassIdentity] {
      SecItemDelete([kSecClass as String: cls] as CFDictionary)
    }
  }

  /// Documents (history, messages, recordings) and Library (settings) stay
  /// out of backups; the Keychain items are ThisDeviceOnly already.
  private static func excludeFromBackup() {
    let fm = FileManager.default
    let dirs = fm.urls(for: .documentDirectory, in: .userDomainMask)
      + fm.urls(for: .libraryDirectory, in: .userDomainMask)
    for dir in dirs {
      var url = dir
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
  }
}
