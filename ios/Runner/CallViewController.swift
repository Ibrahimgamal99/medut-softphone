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

/// Native in-call screen (design E). Ringing on iOS is CallKit's own screen;
/// this takes over once the call is dialling or connected. It holds no call
/// state: it renders [MedutBridge.latest] and sends every tap to Dart.
final class CallViewController: UIViewController {

  private struct Palette {
    let bg, surface, border, text, text2, accent, accentSoft, success, successSoft, danger, warn, warnSoft: UIColor
    init(dark: Bool) {
      func c(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
      }
      bg = dark ? c(0x0D1014) : c(0xF6F8FA)
      surface = dark ? c(0x14181E) : c(0xFFFFFF)
      border = dark ? c(0x2A313A) : c(0xD8DEE6)
      text = dark ? c(0xE8EDF3) : c(0x1C2128)
      text2 = dark ? c(0x9AA4B2) : c(0x5A6573)
      accent = dark ? c(0x4493F8) : c(0x1F6FEB)
      accentSoft = dark ? c(0x4493F8, 0.16) : c(0xDDEBFF)
      success = dark ? c(0x3FB950) : c(0x1A7F37)
      successSoft = dark ? c(0x3FB950, 0.12) : c(0xDAF5E1)
      danger = dark ? c(0xF85149) : c(0xCF222E)
      warn = dark ? c(0xD29922) : c(0x9A6700)
      warnSoft = dark ? c(0xD29922, 0.14) : c(0xFFF3D1)
    }
  }

  private var p = Palette(dark: false)
  private var paletteDark: Bool?
  private var snap = CallSnapshot()
  private var listener: UUID?
  private var timer: Timer?
  private var detailsOpen = false
  private var dtmfTyped = ""
  private var secondAction = "swap"

  private let stack = UIStackView()
  private let minimize = UIButton(type: .system)
  private let account = UILabel()
  private let mosPill = UIButton(type: .system)
  private let secondBanner = UIStackView()
  private let secondText = UILabel()
  private let secondSwap = UIButton(type: .system)
  private let avatar = UILabel()
  private var avatarSize: NSLayoutConstraint!
  private let nameLabel = UILabel()
  private let statusLabel = UILabel()
  private let timerLabel = UILabel()
  private let details = UIStackView()
  private let detailsTitle = UILabel()
  private let detailsRows = UIStackView()
  private let grid = UIStackView()
  private var controls: [String: (UIButton, UILabel)] = [:]
  private let hangup = UIButton(type: .system)

  private let keypad = UIStackView()
  private let keypadDigits = UILabel()
  private var keypadKeys: [UIButton] = []
  private let keypadHide = UIButton(type: .system)

  override var preferredStatusBarStyle: UIStatusBarStyle { paletteDark == true ? .lightContent : .darkContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    build()
    listener = MedutBridge.shared.addListener { [weak self] s in
      DispatchQueue.main.async { self?.render(s) }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateTimer() }
  }


  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    UIDevice.current.isProximityMonitoringEnabled = false
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
    if paletteDark != s.dark {
      paletteDark = s.dark
      p = Palette(dark: s.dark)
      applyPalette()
    }
    view.semanticContentAttribute = s.rtl ? .forceRightToLeft : .forceLeftToRight
    stack.semanticContentAttribute = view.semanticContentAttribute

    account.text = s.account
    avatar.text = initials(s.title)
    nameLabel.text = s.title
    statusLabel.text = s.status.isEmpty ? s.number : s.status
    updateTimer()

    if s.mos.isEmpty {
      mosPill.isHidden = true
    } else {
      mosPill.isHidden = false
      let (fg, bg): (UIColor, UIColor) = s.quality == "poor" ? (p.danger, p.danger.withAlphaComponent(0.14))
        : s.quality == "fair" ? (p.warn, p.warnSoft) : (p.success, p.successSoft)
      mosPill.setTitle(s.mos + (detailsOpen ? "  ▴" : "  ▾"), for: .normal)
      mosPill.setTitleColor(fg, for: .normal)
      mosPill.backgroundColor = bg
    }

    let rows = s.details
    details.isHidden = !(detailsOpen && !rows.isEmpty)
    if !details.isHidden {
      detailsTitle.text = s.label("callDetails", "Call details")
      detailsRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
      stride(from: 0, to: rows.count, by: 2).forEach { i in
        let line = UIStackView()
        line.axis = .horizontal
        line.distribution = .fillEqually
        line.spacing = 14
        line.addArrangedSubview(detailCell(rows[i]))
        line.addArrangedSubview(i + 1 < rows.count ? detailCell(rows[i + 1]) : UIView())
        detailsRows.addArrangedSubview(line)
      }
    }
    let big = details.isHidden
    avatarSize.constant = big ? 108 : 76
    avatar.layer.cornerRadius = avatarSize.constant / 2
    avatar.font = .systemFont(ofSize: big ? 36 : 26, weight: .bold)

    if let second = s.second {
      secondBanner.isHidden = false
      secondText.text = second["text"] as? String
        ?? "\(second["name"] as? String ?? "") · \(s.label("onHold", "On hold"))"
      secondSwap.setTitle(second["label"] as? String ?? s.label("swap", "Swap"), for: .normal)
      secondAction = second["action"] as? String ?? "swap"
    } else {
      secondBanner.isHidden = true
    }

    setControl("mute", s.muted ? "mic.slash" : "mic",
               s.muted ? s.label("unmute", "Unmute") : s.label("mute", "Mute"), on: s.muted)
    setControl("keypad", "circle.grid.3x3.fill", s.label("keypad", "Keypad"), on: false)
    setControl("speaker", s.route == "bluetooth" ? "headphones" : "speaker.wave.2",
               s.route == "bluetooth" ? s.label("bluetooth", "Bluetooth") : s.label("speaker", "Speaker"),
               on: s.route == "speaker" || s.route == "bluetooth")
    setControl("hold", "pause", s.held ? s.label("resume", "Resume") : s.label("hold", "Hold"), on: s.held)
    setControl("add", "plus", s.label("addCall", "Add call"), on: false)
    setControl("transfer", "arrow.turn.up.right", s.label("transfer", "Transfer"), on: false)
    setControl("record", "record.circle",
               s.recording ? s.label("stopRecord", "Stop rec") : s.label("record", "Record"),
               on: s.recording, danger: true)
    if let (b, l) = controls["record"] {
      b.isHidden = !s.canRecord
      l.isHidden = !s.canRecord
    }
    setControl("message", "message", s.label("message", "Message"), on: false)
    keypadHide.setTitle(s.label("hide", "Hide"), for: .normal)
    // Screen off at the ear only when the sound comes out of the earpiece.
    UIDevice.current.isProximityMonitoringEnabled = s.route == "earpiece" && keypad.isHidden
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

  @objc private func tapMos() {
    detailsOpen.toggle()
    render(snap)
  }

  @objc private func tapSwap() { MedutBridge.shared.action(secondAction) }
  @objc private func tapHangup() { MedutBridge.shared.action("hangup") }

  @objc private func tapControl(_ sender: UIButton) {
    guard let key = sender.accessibilityIdentifier else { return }
    let s = snap
    switch key {
    case "mute": MedutBridge.shared.action(s.muted ? "unmute" : "mute")
    case "keypad": showKeypad(true)
    case "speaker": chooseRoute(s)
    case "hold": MedutBridge.shared.action(s.held ? "unhold" : "hold")
    case "record": MedutBridge.shared.action("record")
    case "add", "transfer", "message":
      // These flows live in the Flutter UI: show it on the right screen.
      MedutBridge.shared.action(key)
      MedutBridge.shared.toDart("openRoute", ["route": key])
      tapMinimize()
    default: break
    }
  }

  private func chooseRoute(_ s: CallSnapshot) {
    // One tap toggles the speaker; with a headset connected, pick the output.
    guard s.bluetooth, !s.routes.isEmpty else {
      MedutBridge.shared.action("toggleSpeaker")
      return
    }
    let sheet = UIAlertController(title: s.label("audioOutput", "Audio output"), message: nil, preferredStyle: .actionSheet)
    for r in s.routes {
      let id = r["id"] as? String ?? ""
      let name = r["name"] as? String ?? id
      let active = (r["kind"] as? String) == s.route
      sheet.addAction(UIAlertAction(title: (active ? "✓ " : "") + name, style: .default) { _ in
        MedutBridge.shared.action("route", extra: ["routeId": id])
      })
    }
    sheet.addAction(UIAlertAction(title: s.label("cancel", "Cancel"), style: .cancel))
    present(sheet, animated: true)
  }

  private func showKeypad(_ show: Bool) {
    keypad.isHidden = !show
    stack.isHidden = show
    if show {
      dtmfTyped = ""
      keypadDigits.text = " "
    }
  }

  @objc private func tapKey(_ sender: UIButton) {
    guard let d = sender.title(for: .normal) else { return }
    dtmfTyped = String((dtmfTyped + d).suffix(24))
    keypadDigits.text = dtmfTyped
    MedutBridge.shared.action("dtmf", extra: ["digit": d])
  }

  @objc private func tapHideKeypad() { showKeypad(false) }

  // MARK: Construction

  private func label(_ size: CGFloat, _ weight: UIFont.Weight = .regular, mono: Bool = false) -> UILabel {
    let l = UILabel()
    l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textAlignment = .center
    l.adjustsFontForContentSizeCategory = true
    return l
  }

  private func build() {
    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    // Header
    let header = UIStackView()
    header.axis = .horizontal
    header.alignment = .center
    minimize.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    minimize.accessibilityLabel = "Minimise"
    minimize.addTarget(self, action: #selector(tapMinimize), for: .touchUpInside)
    minimize.widthAnchor.constraint(equalToConstant: 44).isActive = true
    minimize.heightAnchor.constraint(equalToConstant: 44).isActive = true
    account.font = .systemFont(ofSize: 12)
    mosPill.titleLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    mosPill.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    mosPill.layer.cornerRadius = 15
    mosPill.addTarget(self, action: #selector(tapMos), for: .touchUpInside)
    header.addArrangedSubview(minimize)
    header.addArrangedSubview(account)
    header.addArrangedSubview(mosPill)

    // Second line on hold
    secondBanner.axis = .horizontal
    secondBanner.alignment = .center
    secondBanner.isLayoutMarginsRelativeArrangement = true
    secondBanner.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
    secondBanner.layer.cornerRadius = 14
    secondBanner.layer.borderWidth = 1
    secondText.font = .systemFont(ofSize: 14)
    secondText.textAlignment = .natural
    secondSwap.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
    secondSwap.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    secondSwap.layer.cornerRadius = 16
    secondSwap.addTarget(self, action: #selector(tapSwap), for: .touchUpInside)
    secondBanner.addArrangedSubview(secondText)
    secondBanner.addArrangedSubview(secondSwap)

    // Caller
    let caller = UIStackView()
    caller.axis = .vertical
    caller.alignment = .center
    caller.spacing = 4
    avatar.textAlignment = .center
    avatar.clipsToBounds = true
    avatar.translatesAutoresizingMaskIntoConstraints = false
    avatarSize = avatar.widthAnchor.constraint(equalToConstant: 108)
    avatarSize.isActive = true
    avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor).isActive = true
    nameLabel.font = .systemFont(ofSize: 26, weight: .bold)
    nameLabel.textAlignment = .center
    statusLabel.font = .systemFont(ofSize: 14)
    timerLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
    caller.addArrangedSubview(avatar)
    caller.setCustomSpacing(10, after: avatar)
    caller.addArrangedSubview(nameLabel)
    caller.addArrangedSubview(statusLabel)
    caller.addArrangedSubview(timerLabel)

    // Details
    details.axis = .vertical
    details.spacing = 8
    details.isLayoutMarginsRelativeArrangement = true
    details.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    details.layer.cornerRadius = 16
    details.layer.borderWidth = 1
    detailsTitle.font = .systemFont(ofSize: 13, weight: .bold)
    detailsTitle.textAlignment = .natural
    detailsRows.axis = .vertical
    detailsRows.spacing = 6
    details.addArrangedSubview(detailsTitle)
    details.addArrangedSubview(detailsRows)

    // Controls
    grid.axis = .vertical
    grid.spacing = 14
    let keys = ["mute", "keypad", "speaker", "hold", "add", "transfer", "record", "message"]
    for rowKeys in [Array(keys[0..<4]), Array(keys[4..<8])] {
      let row = UIStackView()
      row.axis = .horizontal
      row.distribution = .fillEqually
      for key in rowKeys {
        let cell = UIStackView()
        cell.axis = .vertical
        cell.alignment = .center
        cell.spacing = 6
        let b = UIButton(type: .system)
        b.accessibilityIdentifier = key
        b.widthAnchor.constraint(equalToConstant: 62).isActive = true
        b.heightAnchor.constraint(equalToConstant: 62).isActive = true
        b.layer.cornerRadius = 31
        b.layer.borderWidth = 1
        b.addTarget(self, action: #selector(tapControl(_:)), for: .touchUpInside)
        let l = label(12, .semibold)
        cell.addArrangedSubview(b)
        cell.addArrangedSubview(l)
        row.addArrangedSubview(cell)
        controls[key] = (b, l)
      }
      grid.addArrangedSubview(row)
    }

    hangup.setImage(UIImage(systemName: "phone.down.fill"), for: .normal)
    hangup.accessibilityLabel = "Hang up"
    hangup.layer.cornerRadius = 37
    hangup.addTarget(self, action: #selector(tapHangup), for: .touchUpInside)
    let hangupRow = UIStackView(arrangedSubviews: [hangup])
    hangupRow.axis = .vertical
    hangupRow.alignment = .center
    hangup.widthAnchor.constraint(equalToConstant: 74).isActive = true
    hangup.heightAnchor.constraint(equalToConstant: 74).isActive = true

    let spacerTop = UIView()
    let spacerMid = UIView()
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(8, after: header)
    stack.addArrangedSubview(secondBanner)
    stack.addArrangedSubview(spacerTop)
    stack.addArrangedSubview(caller)
    stack.setCustomSpacing(16, after: caller)
    stack.addArrangedSubview(details)
    stack.addArrangedSubview(spacerMid)
    stack.addArrangedSubview(grid)
    stack.setCustomSpacing(18, after: grid)
    stack.addArrangedSubview(hangupRow)
    spacerMid.heightAnchor.constraint(equalTo: spacerTop.heightAnchor, multiplier: 2).isActive = true

    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
      stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
    ])

    buildKeypad()
    applyPalette()
  }

  private func buildKeypad() {
    keypad.axis = .vertical
    keypad.alignment = .center
    keypad.spacing = 14
    keypad.isHidden = true
    keypad.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(keypad)
    keypadDigits.font = .systemFont(ofSize: 34)
    keypadDigits.text = " "
    keypad.addArrangedSubview(keypadDigits)
    for row in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]] {
      let r = UIStackView()
      r.axis = .horizontal
      r.spacing = 20
      for d in row {
        let b = UIButton(type: .system)
        b.setTitle(d, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 28)
        b.widthAnchor.constraint(equalToConstant: 74).isActive = true
        b.heightAnchor.constraint(equalToConstant: 74).isActive = true
        b.layer.cornerRadius = 37
        b.layer.borderWidth = 1
        b.addTarget(self, action: #selector(tapKey(_:)), for: .touchUpInside)
        keypadKeys.append(b)
        r.addArrangedSubview(b)
      }
      keypad.addArrangedSubview(r)
    }
    let bottom = UIStackView()
    bottom.axis = .horizontal
    bottom.spacing = 40
    bottom.alignment = .center
    keypadHide.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
    keypadHide.addTarget(self, action: #selector(tapHideKeypad), for: .touchUpInside)
    let end = UIButton(type: .system)
    end.setImage(UIImage(systemName: "phone.down.fill"), for: .normal)
    end.tintColor = .white
    end.backgroundColor = UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 1)
    end.layer.cornerRadius = 37
    end.widthAnchor.constraint(equalToConstant: 74).isActive = true
    end.heightAnchor.constraint(equalToConstant: 74).isActive = true
    end.addTarget(self, action: #selector(tapHangup), for: .touchUpInside)
    bottom.addArrangedSubview(keypadHide)
    bottom.addArrangedSubview(end)
    keypad.addArrangedSubview(bottom)
    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      keypad.centerXAnchor.constraint(equalTo: g.centerXAnchor),
      keypad.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -24),
    ])
  }

  private func detailCell(_ row: [String]) -> UIView {
    let k = label(11, mono: true)
    k.text = row.first ?? ""
    k.textColor = p.text2
    k.textAlignment = .natural
    let v = label(11, mono: true)
    v.text = row.count > 1 ? row[1] : ""
    v.textColor = p.text
    v.textAlignment = .right
    let s = UIStackView(arrangedSubviews: [k, v])
    s.axis = .horizontal
    return s
  }

  private func setControl(_ key: String, _ symbol: String, _ title: String, on: Bool, danger: Bool = false) {
    guard let (b, l) = controls[key] else { return }
    b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
    b.accessibilityLabel = title
    l.text = title
    l.textColor = p.text
    if on {
      b.backgroundColor = danger ? p.danger : p.text
      b.tintColor = danger ? .white : p.bg
      b.layer.borderColor = UIColor.clear.cgColor
    } else {
      b.backgroundColor = p.surface
      b.tintColor = p.text
      b.layer.borderColor = p.border.cgColor
    }
  }

  private func applyPalette() {
    view.backgroundColor = p.bg
    setNeedsStatusBarAppearanceUpdate()
    minimize.tintColor = p.text2
    account.textColor = p.text2
    secondBanner.backgroundColor = p.surface
    secondBanner.layer.borderColor = p.border.cgColor
    secondText.textColor = p.text
    secondSwap.setTitleColor(p.accent, for: .normal)
    secondSwap.backgroundColor = p.accentSoft
    avatar.textColor = p.accent
    avatar.backgroundColor = p.accentSoft
    nameLabel.textColor = p.text
    statusLabel.textColor = p.text2
    timerLabel.textColor = p.text
    details.backgroundColor = p.surface
    details.layer.borderColor = p.border.cgColor
    detailsTitle.textColor = p.text
    hangup.backgroundColor = p.danger
    hangup.tintColor = .white
    keypadDigits.textColor = p.text
    keypadHide.setTitleColor(p.accent, for: .normal)
    for k in keypadKeys {
      k.setTitleColor(p.text, for: .normal)
      k.backgroundColor = p.surface
      k.layer.borderColor = p.border.cgColor
    }
  }

  private func initials(_ s: String) -> String {
    let parts = s.split(separator: " ").filter { !$0.isEmpty }
    guard let first = parts.first else { return "?" }
    if !(first.first?.isLetter ?? false) { return String(first.suffix(2)) }
    return (String(first.prefix(1)) + (parts.count > 1 ? String(parts[1].prefix(1)) : "")).uppercased()
  }
}
