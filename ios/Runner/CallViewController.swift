import UIKit

/// Presents the native in-call screen over the Flutter UI.
enum CallScreenPresenter {
  static weak var current: CallViewController?

  static func present() {
    DispatchQueue.main.async {
      guard current == nil, MedutBridge.shared.latest.isLive,
            MedutBridge.shared.latest.phase != "incoming",
            let root = topController() else { return }
      let vc = CallViewController()
      vc.modalPresentationStyle = .fullScreen
      current = vc
      root.present(vc, animated: true)
    }
  }

  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }
}

/// The call screen's colours. The dark theme keeps a black ground, the way
/// most phones show a call; the light theme uses the app's light page. Set
/// [dark] before building views; a change under a live call rebuilds them.
private enum Ink {
  static var dark = true

  static func c(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
  }
  private static func pick(_ d: UIColor, _ l: UIColor) -> UIColor { dark ? d : l }
  /// White on the dark ink, black on the light page, at [a] (or [light] there).
  static func tint(_ a: CGFloat, light: CGFloat? = nil) -> UIColor {
    UIColor(white: dark ? 1 : 0, alpha: dark ? a : (light ?? a))
  }

  static var ground: UIColor { pick(.black, c(0xF6F7F8)) }
  static var text: UIColor { pick(c(0xECEFF2), c(0x111418)) }
  static var text2: UIColor { pick(UIColor(white: 1, alpha: 0.68), c(0x454D56)) }
  static var fill: UIColor { tint(0.12, light: 0.08) }
  static var dock: UIColor { tint(0.07, light: 0.04) }
  static var pill: UIColor { tint(0.10, light: 0.06) }
  static var sheet: UIColor { pick(c(0x131619), .white) }
  static var line: UIColor { tint(0.08) }
  static var good: UIColor { pick(c(0x22C55E), c(0x16A34A)) }
  static var onGood: UIColor { pick(c(0x052E16), .white) }
  static var fair: UIColor { pick(c(0xF59E0B), c(0xD97706)) }
  static var poor: UIColor { pick(c(0xEF4444), c(0xDC2626)) }
  static var rec: UIColor { pick(c(0xF87171), c(0xDC2626)) }
  static var end: UIColor { pick(c(0xEF4444), c(0xDC2626)) }
  static var purple: UIColor { pick(c(0xA855F7), c(0x9333EA)) } // on hold
  static var teal: UIColor { pick(c(0x14B8A6), c(0x0F766E)) } // transfer

  /// (background, initials) per person: the app's avatar colours, picked the same way.
  static var avatars: [(UIColor, UIColor)] {
    dark ? [(c(0x084E65), c(0x9BDCF2)), (c(0x2E1A4A), c(0xC4A2FA)),
            (c(0x38261A), c(0xF4B27A)), (c(0x162A3D), c(0x8EC0F2))]
         : [(c(0xD6ECF4), c(0x0B6886)), (c(0xEFE4FB), c(0x7E22CE)),
            (c(0xFBE8D7), c(0x9A4A12)), (c(0xDBEAFE), c(0x1D4ED8))]
  }

  static func grade(_ level: Int) -> UIColor {
    level >= 3 ? good : level == 2 ? fair : level == 1 ? poor : text2
  }

  static func avatar(_ title: String) -> (UIColor, UIColor) {
    var h = 0
    for u in title.utf16 { h = (h * 31 + Int(u)) & 0x7fffffff }
    return avatars[h % avatars.count]
  }
}

/// Native in-call screen (Pocket). Ringing on iOS is CallKit's own screen;
/// this takes over once the call is dialling or connected. Black ink in the
/// dark theme, the app's light page in the light one: the caller, the quality
/// pill (tap it for every figure), four controls in a dock, then Transfer ·
/// End · More. It holds no call state: it renders [MedutBridge.latest] and
/// sends every tap to [PhoneEngine]. Transfer and Add call pick their number
/// here too.
final class CallViewController: UIViewController {

  private var snap = CallSnapshot()
  private var listener: UUID?
  private var timer: Timer?
  private var sheetOpen = false
  private var dtmfTyped = ""
  private var secondAction = "swap"

  private let stack = UIStackView()
  private let minimize = UIButton(type: .system)
  private let account = UILabel()
  private let secondRow = UIStackView()
  private let secondText = UILabel()
  private let secondSwap = UIButton(type: .system)
  private let avatar = RingAvatar(size: 148, fontSize: 36)
  private let nameLabel = UILabel()
  private let timerLabel = UILabel()
  private let statusLabel = UILabel()
  private let qualityPill = QualityPill(chevron: true)
  private let encryptedTag = UIStackView()
  private let encryptedLabel = UILabel()
  private let recLabel = UILabel()
  private var dock: [String: (UIButton, UILabel)] = [:]
  private let transferLabel = UILabel()
  private let moreLabel = UILabel()
  private var moreButton: UIButton!

  private let dim = UIView()
  private let sheet = UIView()
  private let sheetTitle = UILabel()
  private let sheetPill = QualityPill(chevron: false)
  private let mosYouLabel = UILabel()
  private let mosYou = UILabel()
  private let mosThemLabel = UILabel()
  private let mosThem = UILabel()
  private let sheetRows = UIStackView()

  private let keypad = UIStackView()
  private let keypadTitle = UILabel()
  private let keypadDigits = UILabel()
  private let keypadHide = UIButton(type: .system)
  private var keypadEnd: UIButton!
  private var keypadCall: UIButton!
  private var keypadBack: UIButton!
  /// The keypad sends DTMF, or dials a second call ("Add call").
  private var addCallMode = false

  // A warm transfer under way: who is being consulted, Back to caller / Join & drop.
  private let xferBar = UIStackView()
  private let xferStatus = UILabel()
  private let xferHint = UILabel()
  private let xferBack = UIButton(type: .system)
  private let xferJoin = UIButton(type: .system)

  // Transfer: who to send the caller to, then blind or warm.
  private let transferSheet = UIView()
  private let transferTitle = UILabel()
  private let transferInput = UITextField()
  private let transferList = UIStackView()
  private var blindOption: UIButton!
  private var warmOption: UIButton!
  private var transferBottom: NSLayoutConstraint!

  override var preferredStatusBarStyle: UIStatusBarStyle { Ink.dark ? .lightContent : .darkContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    Ink.dark = MedutBridge.shared.latest.dark
    build()
    listener = MedutBridge.shared.addListener { [weak self] s in
      DispatchQueue.main.async { self?.render(s) }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateTimer() }
  }

  deinit {
    timer?.invalidate()
    if let l = listener { MedutBridge.shared.removeListener(l) }
  }

  // MARK: Rendering

  private func render(_ s: CallSnapshot) {
    snap = s
    if !s.isLive {
      close()
      return
    }
    if s.dark != Ink.dark {
      // The theme changed under a live call: build again in the other ink.
      Ink.dark = s.dark
      view.subviews.forEach { $0.removeFromSuperview() }
      build()
      setNeedsStatusBarAppearanceUpdate()
    }
    let direction: UISemanticContentAttribute = s.rtl ? .forceRightToLeft : .forceLeftToRight
    view.semanticContentAttribute = direction
    stack.semanticContentAttribute = direction

    account.text = s.account
    avatar.set(title: s.title, initials: initials(s.title))
    nameLabel.text = s.title
    updateTimer()
    // Calling / ringing / on hold, or a connection in trouble; otherwise the
    // number under a name until the call is answered.
    let line: String
    if s.phase == "outgoing" || s.phase == "held" || s.link != "ok" {
      line = s.status
    } else if s.startedAt <= 0 && !s.name.isEmpty {
      line = s.number
    } else {
      line = ""
    }
    statusLabel.text = line
    statusLabel.textColor = s.phase == "held" ? Ink.purple : s.link != "ok" ? Ink.fair : Ink.text2
    statusLabel.isHidden = line.isEmpty

    // Quality pill: 3 bars, the grade word and the MOS, in the grade's colour.
    qualityPill.isHidden = s.qualityWord.isEmpty
    if !s.qualityWord.isEmpty {
      qualityPill.set(level: s.qualityLevel, word: s.qualityWord, mos: s.mos)
      qualityPill.accessibilityLabel = s.label("callQuality", "Call quality") + ": " + s.qualityWord
    }
    encryptedLabel.text = s.label("encrypted", "Encrypted")
    encryptedTag.isHidden = !s.encrypted
    recLabel.text = "● " + s.label("recShort", "Rec")
    recLabel.isHidden = !s.recording

    if let xfer = s.transfer {
      // The bar replaces the "on hold · Complete" pill while it is up.
      xferBar.isHidden = false
      xferStatus.text = xfer["status"] as? String ?? ""
      xferHint.text = xfer["hint"] as? String ?? ""
      xferBack.setTitle(xfer["back"] as? String ?? "Back to caller", for: .normal)
      xferJoin.setTitle(xfer["join"] as? String ?? "Join & drop", for: .normal)
      let talking = (xfer["phase"] as? String) == "talking"
      xferJoin.isEnabled = talking
      xferJoin.alpha = talking ? 1 : 0.45
    } else {
      xferBar.isHidden = true
    }

    if let second = s.second, s.transfer == nil {
      secondRow.isHidden = false
      secondText.text = second["text"] as? String
        ?? "\(second["name"] as? String ?? "") · \(s.label("onHold", "On hold"))"
      secondSwap.setTitle(second["label"] as? String ?? s.label("swap", "Swap"), for: .normal)
      secondAction = second["action"] as? String ?? "swap"
    } else {
      secondRow.isHidden = true
    }

    setDock("mute", s.muted ? "mic.slash.fill" : "mic.fill", s.label("mute", "Mute"), on: s.muted)
    let routeLabel = s.route == "bluetooth" ? s.label("bluetooth", "Bluetooth")
      : s.route == "wired" ? s.label("headset", "Headset") : s.label("speaker", "Speaker")
    setDock("speaker", s.route == "bluetooth" ? "headphones" : "speaker.wave.2.fill", routeLabel,
            on: s.route == "speaker" || s.route == "bluetooth")
    // Record sits in the dock (red while recording), the keypad in More;
    // with recording turned off the keypad keeps its place.
    if s.canRecord {
      setDock("third", "record.circle", s.recording ? s.label("stopRecord", "Stop rec") : s.label("record", "Record"),
              on: s.recording, onBg: Ink.end, onTint: .white)
    } else {
      setDock("third", "circle.grid.3x3.fill", s.label("keypad", "Keypad"), on: false)
    }
    setDock("hold", "pause.fill", s.held ? s.label("resume", "Resume") : s.label("hold", "Hold"), on: s.held)
    transferLabel.text = s.label("transfer", "Transfer")
    moreLabel.text = s.label("more", "More")
    keypadHide.setTitle(s.label("hide", "Hide"), for: .normal)
    renderKeypad(s)
    renderSheet(s)
    if !transferSheet.isHidden { renderTransfer(s) }
    // Screen-off at the ear is the engine's (PhoneEngine.push).
  }

  private func renderSheet(_ s: CallSnapshot) {
    if sheetOpen && s.details.isEmpty { sheetOpen = false }
    dim.isHidden = !sheetOpen && transferSheet.isHidden
    sheet.isHidden = !sheetOpen
    guard sheetOpen else { return }
    sheetTitle.text = s.label("callQuality", "Call quality")
    sheetPill.set(level: s.qualityLevel, word: s.qualityWord, mos: s.mos)
    mosYouLabel.text = s.label("youHear", "You hear")
    mosYou.text = s.mosYou.isEmpty ? "—" : s.mosYou
    mosThemLabel.text = s.label("theyHear", "They hear")
    mosThem.text = s.mosThem.isEmpty ? "—" : s.mosThem
    sheetRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (i, row) in s.details.enumerated() {
      if i > 0 {
        let sep = UIView()
        sep.backgroundColor = Ink.line
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        sheetRows.addArrangedSubview(sep)
      }
      sheetRows.addArrangedSubview(detailRow(row))
    }
  }

  private func updateTimer() {
    guard snap.startedAt > 0 else {
      timerLabel.isHidden = true
      return
    }
    timerLabel.isHidden = false
    let sec = max(0, Int(Date().timeIntervalSince1970 - snap.startedAt / 1000))
    timerLabel.text = sec >= 3600
      ? String(format: "%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60)
      : String(format: "%02d:%02d", sec / 60, sec % 60)
  }

  private func close() {
    timer?.invalidate()
    if presentingViewController != nil { dismiss(animated: true) }
    CallScreenPresenter.current = nil
  }

  // MARK: Actions

  @objc private func tapMinimize() {
    dismiss(animated: true)
    CallScreenPresenter.current = nil
  }

  @objc private func tapQuality() {
    sheetOpen = true
    render(snap)
  }

  @objc private func closeSheet() {
    sheetOpen = false
    if !transferSheet.isHidden { closeTransfer() }
    render(snap)
  }

  @objc private func tapSwap() { PhoneEngine.shared.action(secondAction) }
  @objc private func tapHangup() { PhoneEngine.shared.action("hangup") }
  @objc private func tapXferBack() { PhoneEngine.shared.action("cancelTransfer") }
  @objc private func tapXferJoin() { PhoneEngine.shared.action("completeTransfer") }

  @objc private func tapDock(_ sender: UIButton) {
    guard let key = sender.accessibilityIdentifier else { return }
    let s = snap
    switch key {
    case "mute": PhoneEngine.shared.action(s.muted ? "unmute" : "mute")
    case "speaker": chooseRoute(s, from: sender)
    case "third": if s.canRecord { PhoneEngine.shared.action("record") } else { showKeypad(true) }
    case "hold": PhoneEngine.shared.action(s.held ? "unhold" : "hold")
    default: break
    }
  }

  /// What doesn't fit in the dock.
  @objc private func tapMore() {
    let s = snap
    let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    menu.overrideUserInterfaceStyle = Ink.dark ? .dark : .light
    menu.addAction(UIAlertAction(title: s.label("addCall", "Add call"), style: .default) { [weak self] _ in
      self?.showKeypad(true, addCall: true)
    })
    if s.canRecord {
      menu.addAction(UIAlertAction(title: s.label("keypad", "Keypad"), style: .default) { [weak self] _ in
        self?.showKeypad(true)
      })
    }
    menu.addAction(UIAlertAction(title: s.label("message", "Message"), style: .default) { [weak self] _ in
      // The conversation is in the app.
      PhoneEngine.shared.action("message")
      self?.tapMinimize()
    })
    menu.addAction(UIAlertAction(title: s.label("cancel", "Cancel"), style: .cancel))
    menu.popoverPresentationController?.sourceView = moreButton
    menu.popoverPresentationController?.sourceRect = moreButton.bounds
    present(menu, animated: true)
  }


  private func chooseRoute(_ s: CallSnapshot, from button: UIButton) {
    // One tap toggles the speaker; with a headset connected, pick the output.
    guard s.bluetooth, !s.routes.isEmpty else {
      PhoneEngine.shared.action("toggleSpeaker")
      return
    }
    let menu = UIAlertController(title: s.label("audioOutput", "Audio output"), message: nil, preferredStyle: .actionSheet)
    menu.overrideUserInterfaceStyle = Ink.dark ? .dark : .light
    for r in s.routes {
      let id = r["id"] as? String ?? ""
      let name = r["name"] as? String ?? id
      let active = (r["kind"] as? String) == s.route
      menu.addAction(UIAlertAction(title: (active ? "✓ " : "") + name, style: .default) { _ in
        PhoneEngine.shared.action("route", ["routeId": id])
      })
    }
    menu.addAction(UIAlertAction(title: s.label("cancel", "Cancel"), style: .cancel))
    menu.popoverPresentationController?.sourceView = button
    menu.popoverPresentationController?.sourceRect = button.bounds
    present(menu, animated: true)
  }

  private func showKeypad(_ show: Bool, addCall: Bool = false) {
    keypad.isHidden = !show
    stack.isHidden = show
    addCallMode = show && addCall
    if show {
      dtmfTyped = ""
      keypadDigits.text = " "
    }
    renderKeypad(snap)
  }

  private func renderKeypad(_ s: CallSnapshot) {
    keypadTitle.text = "\(s.label("addCallTitle", "Add call")) · \(s.title) \(s.label("onHold", "On hold"))"
    keypadTitle.isHidden = !addCallMode
    keypadEnd.isHidden = addCallMode
    keypadCall.isHidden = !addCallMode
    keypadCall.alpha = dtmfTyped.isEmpty ? 0.45 : 1
    keypadBack.alpha = addCallMode && !dtmfTyped.isEmpty ? 1 : 0
  }

  @objc private func tapKey(_ sender: UIButton) {
    guard let d = sender.title(for: .normal) else { return }
    dtmfTyped = String((dtmfTyped + d).suffix(addCallMode ? 40 : 24))
    keypadDigits.text = dtmfTyped
    if !addCallMode { PhoneEngine.shared.action("dtmf", ["digit": d]) }
    renderKeypad(snap)
  }

  @objc private func tapBackspace() {
    dtmfTyped = String(dtmfTyped.dropLast())
    keypadDigits.text = dtmfTyped.isEmpty ? " " : dtmfTyped
    renderKeypad(snap)
  }

  @objc private func tapAddCall() {
    let number = dtmfTyped.trimmingCharacters(in: .whitespaces)
    guard !number.isEmpty else { return }
    showKeypad(false)
    PhoneEngine.shared.action("addCall", ["number": number])
  }

  @objc private func tapHideKeypad() { showKeypad(false) }

  // MARK: Transfer

  @objc private func tapTransfer() {
    transferInput.text = ""
    transferSheet.isHidden = false
    dim.isHidden = false
    renderTransfer(snap)
    transferInput.becomeFirstResponder()
  }

  private func closeTransfer() {
    transferInput.resignFirstResponder()
    transferSheet.isHidden = true
    dim.isHidden = !sheetOpen
  }

  private func transferTo(warm: Bool) {
    let target = (transferInput.text ?? "").trimmingCharacters(in: .whitespaces)
    guard !target.isEmpty else { return }
    closeTransfer()
    PhoneEngine.shared.action(warm ? "transferWarm" : "transferBlind", ["target": target])
  }

  @objc private func tapBlind() { transferTo(warm: false) }
  @objc private func tapWarm() { transferTo(warm: true) }
  @objc private func transferTyped() { renderTransfer(snap) }

  @objc private func tapTarget(_ sender: UIButton) {
    transferInput.text = sender.accessibilityIdentifier
    renderTransfer(snap)
  }

  /// Title, the matching Team list with presence, and the two ways to transfer.
  private func renderTransfer(_ s: CallSnapshot) {
    transferTitle.text = s.label("transferWho", "Transfer {a}").replacingOccurrences(of: "{a}", with: s.title)
    transferInput.attributedPlaceholder = NSAttributedString(
      string: s.label("transferTo", "Transfer to (extension or number)"),
      attributes: [.foregroundColor: Ink.text2])
    let typed = (transferInput.text ?? "").trimmingCharacters(in: .whitespaces)
    let q = typed.lowercased()
    let matches = PhoneEngine.shared.config.watched
      .filter { q.isEmpty || $0.0.lowercased().contains(q) || $0.1.contains(q) }
      .prefix(5)
    transferList.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (name, ext) in matches { transferList.addArrangedSubview(targetRow(s, name: name, ext: ext, selected: typed == ext)) }
    for (b, title, hint) in [(blindOption!, s.label("blindTransfer", "Blind transfer"),
                              s.label("blindTransferSub", "Sends the caller straight there. You leave the call now.")),
                             (warmOption!, s.label("warmTransfer", "Warm transfer"),
                              s.label("warmTransferSub", "The caller waits on hold while you talk to them, then you join them."))] {
      let text = NSMutableAttributedString(string: title + "\n", attributes: [
        .font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: Ink.text])
      text.append(NSAttributedString(string: hint, attributes: [
        .font: UIFont.systemFont(ofSize: 12.5), .foregroundColor: Ink.text2]))
      b.setAttributedTitle(text, for: .normal)
      b.isEnabled = !typed.isEmpty
      b.alpha = typed.isEmpty ? 0.5 : 1
    }
  }

  private func targetRow(_ s: CallSnapshot, name: String, ext: String, selected: Bool) -> UIView {
    let presence = PhoneEngine.shared.presence[ext]
    var word = s.label("presenceUnknown", "Unknown")
    var dot = Ink.text2
    switch presence {
    case "open":
      word = s.label("presenceOpen", "Available")
      dot = Ink.good
    case "busy":
      word = s.label("presenceBusy", "On a call")
      dot = Ink.poor
    case "closed":
      word = s.label("presenceClosed", "Offline / do not disturb")
      dot = Ink.purple
    default:
      break
    }
    let b = UIButton(type: .system)
    b.accessibilityIdentifier = ext
    b.contentHorizontalAlignment = .leading
    b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    b.backgroundColor = selected ? Ink.good.withAlphaComponent(0.16) : .clear
    b.layer.cornerRadius = 12
    let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: dot, .font: UIFont.systemFont(ofSize: 13)])
    text.append(NSAttributedString(string: (name.isEmpty ? ext : name) + "\n", attributes: [
      .font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: Ink.text]))
    text.append(NSAttributedString(string: "    \(ext) · \(word)", attributes: [
      .font: UIFont.systemFont(ofSize: 12), .foregroundColor: Ink.text2]))
    b.setAttributedTitle(text, for: .normal)
    b.titleLabel?.numberOfLines = 2
    b.addTarget(self, action: #selector(tapTarget(_:)), for: .touchUpInside)
    return b
  }

  @objc private func keyboardChanged(_ n: Notification) {
    guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
    let overlap = max(0, view.bounds.maxY - view.convert(end, from: nil).minY)
    transferBottom.constant = -overlap
    UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
  }

  // MARK: Construction

  private func label(_ size: CGFloat, _ weight: UIFont.Weight = .regular, color: UIColor = Ink.text) -> UILabel {
    let l = UILabel()
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.textAlignment = .center
    return l
  }

  private func style(_ l: UILabel, _ size: CGFloat, _ weight: UIFont.Weight = .regular, color: UIColor = Ink.text) {
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.textAlignment = .center
  }

  private func roundButton(_ size: CGFloat, symbol: String, bg: UIColor, tint: UIColor, action: Selector) -> UIButton {
    let b = UIButton(type: .system)
    b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.36, weight: .medium)), for: .normal)
    b.tintColor = tint
    b.backgroundColor = bg
    b.layer.cornerRadius = size / 2
    b.widthAnchor.constraint(equalToConstant: size).isActive = true
    b.heightAnchor.constraint(equalToConstant: size).isActive = true
    b.addTarget(self, action: action, for: .touchUpInside)
    return b
  }

  /// A round button with its label under it.
  private func cell(_ b: UIButton, _ l: UILabel) -> UIStackView {
    style(l, 11.5, .medium, color: Ink.text2)
    let s = UIStackView(arrangedSubviews: [b, l])
    s.axis = .vertical
    s.alignment = .center
    s.spacing = 6
    return s
  }

  /// Keeps a view at its own size inside a filling stack.
  private func centered(_ v: UIView) -> UIStackView {
    let s = UIStackView(arrangedSubviews: [v])
    s.axis = .vertical
    s.alignment = .center
    return s
  }

  private func build() {
    view.backgroundColor = Ink.ground
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    // Minimise · account
    minimize.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    minimize.tintColor = Ink.text2
    minimize.accessibilityLabel = "Minimise"
    minimize.addTarget(self, action: #selector(tapMinimize), for: .touchUpInside)
    minimize.widthAnchor.constraint(equalToConstant: 44).isActive = true
    minimize.heightAnchor.constraint(equalToConstant: 44).isActive = true
    style(account, 12.5, color: Ink.text2)
    let balance = UIView()
    balance.widthAnchor.constraint(equalToConstant: 44).isActive = true
    let header = UIStackView(arrangedSubviews: [minimize, account, balance])
    header.axis = .horizontal
    header.alignment = .center

    // The other call: on hold, waiting, or the transfer to complete.
    style(secondText, 13, .semibold)
    secondSwap.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .bold)
    secondSwap.setTitleColor(Ink.text, for: .normal)
    secondSwap.backgroundColor = Ink.tint(0.16)
    secondSwap.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
    secondSwap.layer.cornerRadius = 14
    secondSwap.addTarget(self, action: #selector(tapSwap), for: .touchUpInside)
    let secondPill = UIStackView(arrangedSubviews: [secondText, secondSwap])
    secondPill.axis = .horizontal
    secondPill.alignment = .center
    secondPill.spacing = 8
    secondPill.isLayoutMarginsRelativeArrangement = true
    secondPill.layoutMargins = UIEdgeInsets(top: 5, left: 14, bottom: 5, right: 5)
    secondPill.backgroundColor = Ink.pill
    secondPill.layer.cornerRadius = 19
    secondRow.axis = .vertical
    secondRow.alignment = .center
    secondRow.addArrangedSubview(secondPill)

    // Caller, time, quality, tags
    style(nameLabel, 30, .heavy)
    nameLabel.adjustsFontSizeToFitWidth = true
    nameLabel.minimumScaleFactor = 0.6
    timerLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
    timerLabel.textColor = Ink.text2
    style(statusLabel, 14, color: Ink.text2)
    statusLabel.numberOfLines = 2
    qualityPill.addTarget(self, action: #selector(tapQuality), for: .touchUpInside)
    let lock = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    lock.tintColor = Ink.text2
    style(encryptedLabel, 12.5, color: Ink.text2)
    encryptedTag.addArrangedSubview(lock)
    encryptedTag.addArrangedSubview(encryptedLabel)
    encryptedTag.axis = .horizontal
    encryptedTag.alignment = .center
    encryptedTag.spacing = 5
    style(recLabel, 12.5, .semibold, color: Ink.rec)
    let tags = UIStackView(arrangedSubviews: [encryptedTag, recLabel])
    tags.axis = .horizontal
    tags.spacing = 14
    let caller = UIStackView(arrangedSubviews: [avatar, nameLabel, timerLabel, statusLabel, qualityPill, tags])
    caller.axis = .vertical
    caller.alignment = .center
    caller.spacing = 3
    caller.setCustomSpacing(14, after: avatar)
    caller.setCustomSpacing(14, after: statusLabel)
    caller.setCustomSpacing(12, after: qualityPill)

    // The dock: Mute, Speaker, Keypad, Hold.
    let dockRow = UIStackView()
    dockRow.axis = .horizontal
    dockRow.distribution = .fillEqually
    dockRow.isLayoutMarginsRelativeArrangement = true
    dockRow.layoutMargins = UIEdgeInsets(top: 14, left: 6, bottom: 12, right: 6)
    dockRow.backgroundColor = Ink.dock
    dockRow.layer.cornerRadius = 28
    for key in ["mute", "speaker", "third", "hold"] {
      let b = roundButton(54, symbol: "mic.fill", bg: Ink.fill, tint: Ink.text, action: #selector(tapDock(_:)))
      b.accessibilityIdentifier = key
      let l = UILabel()
      dock[key] = (b, l)
      dockRow.addArrangedSubview(cell(b, l))
    }

    // Transfer · End · More
    let transferButton = roundButton(46, symbol: "arrow.turn.up.right", bg: Ink.fill, tint: Ink.text, action: #selector(tapTransfer))
    let hang = UIButton(type: .system)
    hang.setImage(UIImage(systemName: "phone.down.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
    hang.tintColor = .white
    hang.backgroundColor = Ink.end
    hang.layer.cornerRadius = 30
    hang.accessibilityLabel = "Hang up"
    hang.widthAnchor.constraint(equalToConstant: 88).isActive = true
    hang.heightAnchor.constraint(equalToConstant: 60).isActive = true
    hang.addTarget(self, action: #selector(tapHangup), for: .touchUpInside)
    moreButton = roundButton(46, symbol: "ellipsis", bg: Ink.fill, tint: Ink.text, action: #selector(tapMore))
    let bottom = UIStackView(arrangedSubviews: [cell(transferButton, transferLabel), centered(hang), cell(moreButton, moreLabel)])
    bottom.axis = .horizontal
    bottom.distribution = .fillEqually
    bottom.alignment = .center

    // Warm transfer: who is being consulted, Back to caller / Join & drop.
    style(xferStatus, 14.5, .bold)
    style(xferHint, 12, color: Ink.text2)
    xferHint.numberOfLines = 2
    for (b, bg, fg, sel) in [(xferBack, Ink.fill, Ink.text, #selector(tapXferBack)),
                             (xferJoin, Ink.teal, Ink.onGood, #selector(tapXferJoin))] {
      b.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
      b.setTitleColor(fg, for: .normal)
      b.backgroundColor = bg
      b.layer.cornerRadius = 22
      b.heightAnchor.constraint(equalToConstant: 44).isActive = true
      b.addTarget(self, action: sel, for: .touchUpInside)
    }
    let xferButtons = UIStackView(arrangedSubviews: [xferBack, xferJoin])
    xferButtons.axis = .horizontal
    xferButtons.distribution = .fillEqually
    xferButtons.spacing = 8
    [xferStatus, xferHint, xferButtons].forEach { xferBar.addArrangedSubview($0) }
    xferBar.axis = .vertical
    xferBar.spacing = 6
    xferBar.isLayoutMarginsRelativeArrangement = true
    xferBar.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
    xferBar.backgroundColor = Ink.pill
    xferBar.layer.cornerRadius = 22
    xferBar.isHidden = true

    let spacerTop = UIView()
    let spacerMid = UIView()
    stack.addArrangedSubview(header)
    stack.addArrangedSubview(secondRow)
    stack.addArrangedSubview(spacerTop)
    stack.addArrangedSubview(caller)
    stack.addArrangedSubview(xferBar)
    stack.setCustomSpacing(12, after: caller)
    stack.addArrangedSubview(spacerMid)
    stack.addArrangedSubview(dockRow)
    stack.setCustomSpacing(18, after: dockRow)
    stack.addArrangedSubview(bottom)
    spacerMid.heightAnchor.constraint(equalTo: spacerTop.heightAnchor).isActive = true

    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: g.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -14),
      stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14),
    ])

    buildKeypad()
    buildSheet()
    buildTransferSheet()
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
  }

  private func buildTransferSheet() {
    transferSheet.backgroundColor = Ink.sheet
    transferSheet.layer.cornerRadius = 26
    transferSheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    transferSheet.isHidden = true
    transferSheet.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(transferSheet)

    style(transferTitle, 19, .heavy)
    transferTitle.textAlignment = .natural
    transferInput.keyboardType = .phonePad
    transferInput.textColor = Ink.text
    transferInput.keyboardAppearance = Ink.dark ? .dark : .light
    transferInput.font = .systemFont(ofSize: 18)
    transferInput.backgroundColor = Ink.fill
    transferInput.layer.cornerRadius = 16
    transferInput.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 1))
    transferInput.leftViewMode = .always
    transferInput.heightAnchor.constraint(equalToConstant: 50).isActive = true
    transferInput.addTarget(self, action: #selector(transferTyped), for: .editingChanged)
    transferList.axis = .vertical
    transferList.spacing = 2
    func option(_ symbol: String, _ sel: Selector) -> UIButton {
      let b = UIButton(type: .system)
      b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
      b.tintColor = Ink.good
      b.contentHorizontalAlignment = .leading
      b.titleLabel?.numberOfLines = 0
      b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
      b.titleEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: -14)
      b.backgroundColor = Ink.tint(0.06)
      b.layer.cornerRadius = 16
      b.addTarget(self, action: sel, for: .touchUpInside)
      return b
    }
    blindOption = option("arrow.turn.up.right", #selector(tapBlind))
    warmOption = option("person.2.fill", #selector(tapWarm))
    let content = UIStackView(arrangedSubviews: [transferTitle, transferInput, transferList, blindOption, warmOption])
    content.axis = .vertical
    content.spacing = 10
    content.translatesAutoresizingMaskIntoConstraints = false
    transferSheet.addSubview(content)
    transferBottom = transferSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    NSLayoutConstraint.activate([
      transferSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      transferSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      transferBottom,
      content.topAnchor.constraint(equalTo: transferSheet.topAnchor, constant: 18),
      content.leadingAnchor.constraint(equalTo: transferSheet.leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: transferSheet.trailingAnchor, constant: -20),
      content.bottomAnchor.constraint(equalTo: transferSheet.bottomAnchor, constant: -24),
    ])
  }

  private func buildKeypad() {
    keypad.axis = .vertical
    keypad.alignment = .center
    keypad.spacing = 14
    keypad.isHidden = true
    keypad.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(keypad)
    style(keypadTitle, 13, color: Ink.text2)
    keypadTitle.isHidden = true
    keypad.addArrangedSubview(keypadTitle)
    keypadDigits.font = .systemFont(ofSize: 34)
    keypadDigits.textColor = Ink.text
    keypadDigits.lineBreakMode = .byTruncatingHead
    keypadDigits.text = " "
    keypad.addArrangedSubview(keypadDigits)
    for row in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]] {
      let r = UIStackView()
      r.axis = .horizontal
      r.spacing = 20
      for d in row {
        let b = UIButton(type: .system)
        b.setTitle(d, for: .normal)
        b.setTitleColor(Ink.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 28, weight: .medium)
        b.backgroundColor = Ink.fill
        b.widthAnchor.constraint(equalToConstant: 74).isActive = true
        b.heightAnchor.constraint(equalToConstant: 74).isActive = true
        b.layer.cornerRadius = 37
        b.addTarget(self, action: #selector(tapKey(_:)), for: .touchUpInside)
        r.addArrangedSubview(b)
      }
      keypad.addArrangedSubview(r)
    }
    let bottom = UIStackView()
    bottom.axis = .horizontal
    bottom.spacing = 40
    bottom.alignment = .center
    keypadHide.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
    keypadHide.setTitleColor(Ink.text2, for: .normal)
    keypadHide.addTarget(self, action: #selector(tapHideKeypad), for: .touchUpInside)
    keypadEnd = roundButton(74, symbol: "phone.down.fill", bg: Ink.end, tint: .white, action: #selector(tapHangup))
    keypadCall = roundButton(74, symbol: "phone.fill", bg: Ink.good, tint: Ink.onGood, action: #selector(tapAddCall))
    keypadCall.isHidden = true
    keypadBack = UIButton(type: .system)
    keypadBack.setImage(UIImage(systemName: "delete.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
    keypadBack.tintColor = Ink.text2
    keypadBack.widthAnchor.constraint(equalToConstant: 56).isActive = true
    keypadBack.addTarget(self, action: #selector(tapBackspace), for: .touchUpInside)
    keypadBack.alpha = 0
    bottom.addArrangedSubview(keypadHide)
    bottom.addArrangedSubview(keypadEnd)
    bottom.addArrangedSubview(keypadCall)
    bottom.addArrangedSubview(keypadBack)
    keypad.addArrangedSubview(bottom)
    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      keypad.centerXAnchor.constraint(equalTo: g.centerXAnchor),
      keypad.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -24),
    ])
  }

  /// Call quality: the pill again, each direction's MOS, then every figure.
  private func buildSheet() {
    dim.backgroundColor = UIColor(white: 0, alpha: 0.5)
    dim.isHidden = true
    dim.translatesAutoresizingMaskIntoConstraints = false
    dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeSheet)))
    view.addSubview(dim)

    sheet.backgroundColor = Ink.sheet
    sheet.layer.cornerRadius = 26
    sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    sheet.isHidden = true
    sheet.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(sheet)

    let handle = UIView()
    handle.backgroundColor = Ink.tint(0.2)
    handle.layer.cornerRadius = 2.5
    handle.widthAnchor.constraint(equalToConstant: 38).isActive = true
    handle.heightAnchor.constraint(equalToConstant: 5).isActive = true

    style(sheetTitle, 19, .heavy)
    sheetTitle.textAlignment = .natural
    let head = UIStackView(arrangedSubviews: [sheetTitle, sheetPill])
    head.axis = .horizontal
    head.alignment = .center
    head.spacing = 10

    func mosBox(_ title: UILabel, _ value: UILabel) -> UIStackView {
      style(title, 11.5, color: Ink.text2)
      title.textAlignment = .natural
      value.font = .monospacedDigitSystemFont(ofSize: 24, weight: .heavy)
      value.textColor = Ink.text
      value.textAlignment = .natural
      let box = UIStackView(arrangedSubviews: [title, value])
      box.axis = .vertical
      box.isLayoutMarginsRelativeArrangement = true
      box.layoutMargins = UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
      box.backgroundColor = Ink.tint(0.06)
      box.layer.cornerRadius = 16
      return box
    }
    let mosRow = UIStackView(arrangedSubviews: [mosBox(mosYouLabel, mosYou), mosBox(mosThemLabel, mosThem)])
    mosRow.axis = .horizontal
    mosRow.distribution = .fillEqually
    mosRow.spacing = 8
    sheetRows.axis = .vertical

    let content = UIStackView(arrangedSubviews: [centered(handle), head, mosRow, sheetRows])
    content.axis = .vertical
    content.setCustomSpacing(14, after: content.arrangedSubviews[0])
    content.setCustomSpacing(12, after: head)
    content.setCustomSpacing(6, after: mosRow)
    content.translatesAutoresizingMaskIntoConstraints = false
    sheet.addSubview(content)

    NSLayoutConstraint.activate([
      dim.topAnchor.constraint(equalTo: view.topAnchor),
      dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      content.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 10),
      content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -20),
      content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
  }

  private func detailRow(_ row: [String]) -> UIView {
    let k = label(13, color: Ink.text2)
    k.text = row.first ?? ""
    k.textAlignment = .natural
    let v = UILabel()
    v.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    v.textColor = Ink.text
    v.text = row.count > 1 ? row[1] : ""
    v.textAlignment = .right
    let s = UIStackView(arrangedSubviews: [k, v])
    s.axis = .horizontal
    s.spacing = 12
    s.isLayoutMarginsRelativeArrangement = true
    s.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    return s
  }

  private func setDock(_ key: String, _ symbol: String, _ title: String, on: Bool,
                       onBg: UIColor? = nil, onTint: UIColor? = nil) {
    guard let (b, l) = dock[key] else { return }
    b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
    b.accessibilityLabel = title
    b.backgroundColor = on ? (onBg ?? Ink.text) : Ink.fill
    b.tintColor = on ? (onTint ?? Ink.ground) : Ink.text
    l.text = title
  }

  private func initials(_ s: String) -> String {
    let parts = s.split(separator: " ").filter { !$0.isEmpty }
    guard let first = parts.first else { return "?" }
    if !(first.first?.isLetter ?? false) { return String(first.suffix(2)) }
    return (String(first.prefix(1)) + (parts.count > 1 ? String(parts[1].prefix(1)) : "")).uppercased()
  }
}

/// The caller's initials on their colour, inside two faint rings; the view is
/// 44 pt wider than the disc.
final class RingAvatar: UIView {
  private let middle = UIView()
  private let disc = UILabel()

  init(size: CGFloat, fontSize: CGFloat) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Ink.tint(0.03)
    layer.cornerRadius = size / 2
    middle.backgroundColor = Ink.tint(0.05)
    middle.layer.cornerRadius = size / 2 - 10
    middle.translatesAutoresizingMaskIntoConstraints = false
    disc.textAlignment = .center
    disc.font = .systemFont(ofSize: fontSize, weight: .bold)
    disc.clipsToBounds = true
    disc.layer.cornerRadius = size / 2 - 22
    disc.translatesAutoresizingMaskIntoConstraints = false
    addSubview(middle)
    addSubview(disc)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
      middle.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      middle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      middle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      middle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      disc.topAnchor.constraint(equalTo: topAnchor, constant: 22),
      disc.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
      disc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
      disc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  func set(title: String, initials: String) {
    let (bg, fg) = Ink.avatar(title)
    disc.backgroundColor = bg
    disc.textColor = fg
    disc.text = initials
  }
}

/// Three bars, the grade word and the MOS on the grade's colour; a control,
/// so the in-call one opens the quality sheet.
final class QualityPill: UIControl {
  private let bars = QualityBarsView()
  private let word = UILabel()
  private let mos = UILabel()

  init(chevron: Bool) {
    super.init(frame: .zero)
    layer.cornerRadius = 17
    word.font = .systemFont(ofSize: 13, weight: .bold)
    mos.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    mos.textColor = Ink.text2
    let arrow = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    arrow.tintColor = Ink.text2
    arrow.isHidden = !chevron
    let row = UIStackView(arrangedSubviews: [bars, word, mos, arrow])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 6
    row.isUserInteractionEnabled = false
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  func set(level: Int, word w: String, mos m: String) {
    let fg = Ink.grade(level)
    backgroundColor = fg.withAlphaComponent(0.15)
    bars.setQuality(level: level, litColor: fg, offColor: Ink.tint(0.25))
    word.text = w
    word.textColor = fg
    mos.text = m
    mos.isHidden = m.isEmpty
  }
}

/// Three rising signal bars for call quality.
final class QualityBarsView: UIView {
  private let barWidth: CGFloat = 4
  private var gap: CGFloat { barWidth * 0.7 }
  private var level = 0
  private var litColor = UIColor.clear
  private var offColor = UIColor.gray.withAlphaComponent(0.25)

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  func setQuality(level: Int, litColor: UIColor, offColor: UIColor) {
    self.level = max(0, min(3, level))
    self.litColor = litColor
    self.offColor = offColor
    setNeedsDisplay()
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: barWidth * 3 + gap * 2, height: barWidth * 1.75 + 2 * barWidth * 1.25)
  }

  override func draw(_ rect: CGRect) {
    var x: CGFloat = 0
    for i in 0..<3 {
      let h = barWidth * 1.75 + CGFloat(i) * barWidth * 1.25
      let r = CGRect(x: x, y: bounds.height - h, width: barWidth, height: h)
      (i < level ? litColor : offColor).setFill()
      UIBezierPath(roundedRect: r, cornerRadius: barWidth / 2).fill()
      x += barWidth + gap
    }
  }
}
