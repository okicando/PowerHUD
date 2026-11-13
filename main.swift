import Cocoa

// MARK: - Data

struct Reading {
    let watts: Double          // adapter input W, or battery discharge W
    let volts: Double
    let amps: Double
    let sourceIsAC: Bool       // which rail the numbers came from
    let batteryPercent: Int?
}

struct HUDStyle {
    var width: CGFloat = 173
    var height: CGFloat = 84
    var heroFont: CGFloat = 17.4
    var unitFont: CGFloat = 12.8
    var modeFont: CGFloat = 12.1
    var detailFont: CGFloat = 9.7
    var sidePadding: CGFloat = 18
    var topPadding: CGFloat = 12
    var rowGap: CGFloat = 11
    var cornerRadius: CGFloat = 34
}

final class PowerReader {
    private let queue = DispatchQueue(label: "powerhud.reader")
    private var inFlight = false
    private var timer: Timer?

    func start(_ handler: @escaping (Reading?) -> Void) {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.inFlight else { return }
            self.inFlight = true
            self.queue.async {
                let reading = PowerReader.sample()
                DispatchQueue.main.async {
                    self.inFlight = false
                    handler(reading)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        queue.async {
            let reading = PowerReader.sample()
            DispatchQueue.main.async { handler(reading) }
        }
    }

    static func sample() -> Reading? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-rn", "AppleSmartBattery", "-w0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let onAC = boolValue(in: text, key: "ExternalConnected") ?? true
        let isCharging = boolValue(in: text, key: "IsCharging") ?? false
        let percent = value(in: text, key: "CurrentCapacity").map { Int($0) }
        let sp = value(in: text, key: "SystemPowerIn") ?? 0
        let bp = value(in: text, key: "BatteryPower") ?? 0
        let mV = value(in: text, key: "Voltage") ?? 0
        let mA = abs(value(in: text, key: "InstantAmperage")
                     ?? value(in: text, key: "Amperage") ?? 0)

        // The battery can discharge even while plugged in: when the charge is
        // above the charge limit, macOS deliberately runs off the battery until
        // it drops to the limit. Judge by real power flow, not just the adapter flag.
        let batteryFed = bp < -100 && !isCharging

        if onAC && !batteryFed && sp > 0 {
            let mv = value(in: text, key: "SystemVoltageIn") ?? 0
            let ma = value(in: text, key: "SystemCurrentIn") ?? 0
            return Reading(watts: sp / 1000.0, volts: mv / 1000.0, amps: ma / 1000.0,
                           sourceIsAC: true, batteryPercent: percent)
        }
        // Battery-powered (unplugged, above charge limit, or adapter telemetry
        // lagging right after unplug). Prefer the BatteryPower telemetry
        // (mW, negative = discharging); fall back to voltage x current.
        var watts = abs(bp) / 1000.0
        if watts == 0, mA > 0 {
            watts = mV * mA / 1_000_000.0
        }
        return Reading(watts: watts, volts: mV / 1000.0, amps: mA / 1000.0,
                       sourceIsAC: false, batteryPercent: percent)
    }

    private static func value(in text: String, key: String) -> Double? {
        guard let r = text.range(of: "\"\(key)\"") else { return nil }
        var rest = text[r.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        var digits = ""
        var negative = false
        if rest.first == "-" {
            negative = true
            rest = rest.dropFirst()
        }
        digits = String(rest.prefix { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        if negative, let d = Double(digits) { return -d }
        // ioreg prints 64-bit signed values as unsigned when negative
        // (e.g. battery current while discharging), so unwrap the two's complement.
        if let u = UInt64(digits) {
            if u > UInt64(Int64.max) {
                return Double(Int64(bitPattern: u))
            }
            return Double(u)
        }
        return Double(digits)
    }

    private static func boolValue(in text: String, key: String) -> Bool? {
        guard let r = text.range(of: "\"\(key)\"") else { return nil }
        let rest = text[r.upperBound...].prefix(40)
        if rest.contains("= Yes") { return true }
        if rest.contains("= No") { return false }
        return nil
    }
}

// MARK: - UI

final class HUDView: NSView {
    var menuHandler: (() -> NSMenu?)?

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSColor(calibratedWhite: 0.04, alpha: 0.5).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuHandler?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var wattsLabel: NSTextField!
    private var voltageLabel: NSTextField!
    private var currentLabel: NSTextField!
    private var modeLabel: NSTextField!
    private let reader = PowerReader()
    private var activity: NSObjectProtocol?
    private var style = HUDStyle()
    private var effectView: NSVisualEffectView!
    private var lastReading: Reading?
    private var wattsTop: NSLayoutConstraint!
    private var wattsTrailing: NSLayoutConstraint!
    private var modeLeading: NSLayoutConstraint!
    private var dividerLeading: NSLayoutConstraint!
    private var dividerTrailing: NSLayoutConstraint!
    private var dividerTop: NSLayoutConstraint!
    private var voltageLeading: NSLayoutConstraint!
    private var voltageTop: NSLayoutConstraint!
    private var currentTrailing: NSLayoutConstraint!
    private var tunerPanel: NSPanel?
    private var sliders: [Int: NSSlider] = [:]
    private var valueLabels: [Int: NSTextField] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "PowerHUD power monitoring")
        buildUI()
        reader.start { [weak self] reading in self?.render(reading) }
        if CommandLine.arguments.contains("--tuner") {
            showTuner()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private func buildUI() {
        let w: CGFloat = style.width, h: CGFloat = style.height
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        // Frosted-glass backdrop, clipped to rounded corners.
        // NSVisualEffectView paints its own material edge along its rectangular
        // bounds; layer.cornerRadius does not clip that, so use a rounded mask.
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = style.cornerRadius
        effect.layer?.masksToBounds = true
        effect.maskImage = roundedMaskImage(radius: style.cornerRadius)
        panel.contentView = effect
        effectView = effect

        // Tint + hairline border on top of the blur; hosts the labels.
        let overlay = HUDView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        overlay.menuHandler = { [weak self] in self?.buildMenu() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: effect.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        modeLabel = NSTextField(labelWithString: "读取中…")
        modeLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        modeLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(modeLabel)

        wattsLabel = NSTextField(labelWithString: "")
        wattsLabel.alignment = .right
        wattsLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(wattsLabel)

        let divider1 = NSView()
        divider1.wantsLayer = true
        divider1.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        divider1.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(divider1)

        voltageLabel = NSTextField(labelWithString: "电压：—")
        voltageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        voltageLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.65)
        voltageLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(voltageLabel)

        currentLabel = NSTextField(labelWithString: "电流：—")
        currentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        currentLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.65)
        currentLabel.alignment = .right
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(currentLabel)

        wattsTop = wattsLabel.topAnchor.constraint(equalTo: overlay.topAnchor, constant: style.topPadding)
        wattsTrailing = wattsLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor,
                                                             constant: -style.sidePadding)
        modeLeading = modeLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor,
                                                         constant: style.sidePadding)
        dividerLeading = divider1.leadingAnchor.constraint(equalTo: overlay.leadingAnchor,
                                                           constant: style.sidePadding)
        dividerTrailing = divider1.trailingAnchor.constraint(equalTo: overlay.trailingAnchor,
                                                             constant: -style.sidePadding)
        dividerTop = divider1.topAnchor.constraint(equalTo: wattsLabel.bottomAnchor,
                                                   constant: style.rowGap)
        voltageLeading = voltageLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor,
                                                               constant: style.sidePadding)
        voltageTop = voltageLabel.topAnchor.constraint(equalTo: divider1.bottomAnchor,
                                                       constant: style.rowGap)
        currentTrailing = currentLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor,
                                                                 constant: -style.sidePadding)

        NSLayoutConstraint.activate([
            wattsTop, wattsTrailing, modeLeading,
            modeLabel.centerYAnchor.constraint(equalTo: wattsLabel.centerYAnchor),
            dividerLeading, dividerTrailing, dividerTop,
            divider1.heightAnchor.constraint(equalToConstant: 1),
            voltageLeading, voltageTop, currentTrailing,
            currentLabel.centerYAnchor.constraint(equalTo: voltageLabel.centerYAnchor),
        ])

        applyStyle()
        restorePosition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "hudOrigin")
        }
    }

    private func restorePosition() {
        let screens = NSScreen.screens
        if let saved = UserDefaults.standard.string(forKey: "hudOrigin") {
            let origin = NSPointFromString(saved)
            let rect = NSRect(origin: origin, size: panel.frame.size)
            if screens.contains(where: { $0.visibleFrame.contains(rect) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        guard let vf = (NSScreen.main ?? screens.first)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 24,
                                     y: vf.maxY - panel.frame.height - 24))
    }

    private func roundedMaskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                     xRadius: radius, yRadius: radius).fill()
        image.unlockFocus()
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func render(_ reading: Reading?) {
        lastReading = reading
        guard let r = reading else { return }

        // Follow the real power flow, updating the label on every sample: during
        // the handover right after plugging in, the battery is still supplying,
        // so keep showing battery mode and let its watts ramp down; switch only
        // when the adapter actually takes over.
        if r.sourceIsAC {
            modeLabel.attributedStringValue = modeString("电源供电", color: .systemGreen)
        } else {
            modeLabel.attributedStringValue = modeString("电池供电", color: .systemOrange)
        }

        // Show whatever is measured right now, and a dash for values the gauge
        // has not delivered yet — stale numbers must not masquerade as fresh data.
        if r.watts > 0 {
            wattsLabel.attributedStringValue = heroString(r.watts)
        } else {
            wattsLabel.attributedStringValue = heroDash()
        }
        if r.volts > 0 {
            voltageLabel.attributedStringValue = detailString("电压：", number: String(format: "%.1f", r.volts), unit: "V")
        } else {
            voltageLabel.attributedStringValue = detailString("电压：", number: "—", unit: "V")
        }
        if r.amps > 0 {
            currentLabel.attributedStringValue = detailString("电流：", number: String(format: "%.2f", r.amps), unit: "A")
        } else {
            currentLabel.attributedStringValue = detailString("电流：", number: "—", unit: "A")
        }
    }

    private func detailString(_ prefix: String, number: String, unit: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.detailFont, weight: .regular)
        let result = NSMutableAttributedString(
            string: prefix,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.55),
            ])
        result.append(NSAttributedString(
            string: number,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ]))
        result.append(NSAttributedString(
            string: " " + unit,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.45),
            ]))
        return result
    }

    private func modeString(_ text: String, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "●  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(6, style.modeFont - 2.5), weight: .bold),
                .foregroundColor: color,
                .baselineOffset: 1.5,
            ])
        result.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: style.modeFont, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.55),
            ]))
        return result
    }

    private func heroDash() -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "—",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: style.heroFont, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.6),
            ])
        result.append(NSAttributedString(
            string: " W",
            attributes: [
                .font: NSFont.systemFont(ofSize: style.unitFont, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.45),
            ]))
        return result
    }

    private func heroString(_ watts: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: String(format: "%.1f", watts),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: style.heroFont, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        result.append(NSAttributedString(
            string: " W",
            attributes: [
                .font: NSFont.systemFont(ofSize: style.unitFont, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.45),
            ]))
        return result
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let pin = NSMenuItem(title: "始终置顶", action: #selector(togglePin(_:)), keyEquivalent: "")
        pin.state = panel.level == .floating ? .on : .off
        pin.target = self
        menu.addItem(pin)
        let tune = NSMenuItem(title: "调整样式…", action: #selector(showTuner), keyEquivalent: "")
        tune.target = self
        menu.addItem(tune)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func togglePin(_ item: NSMenuItem) {
        panel.level = panel.level == .floating ? .normal : .floating
        item.state = panel.level == .floating ? .on : .off
    }

    // MARK: - Style tuning

    private func applyStyle() {
        guard panel != nil, effectView != nil, wattsTop != nil else { return }
        panel.setContentSize(NSSize(width: style.width, height: style.height))
        effectView.layer?.cornerRadius = style.cornerRadius
        effectView.maskImage = roundedMaskImage(radius: style.cornerRadius)
        wattsTop.constant = style.topPadding
        wattsTrailing.constant = -style.sidePadding
        modeLeading.constant = style.sidePadding
        dividerLeading.constant = style.sidePadding
        dividerTrailing.constant = -style.sidePadding
        dividerTop.constant = style.rowGap
        voltageLeading.constant = style.sidePadding
        voltageTop.constant = style.rowGap
        currentTrailing.constant = -style.sidePadding
        modeLabel.font = NSFont.systemFont(ofSize: style.modeFont, weight: .medium)
        voltageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: style.detailFont, weight: .regular)
        currentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: style.detailFont, weight: .regular)
        render(lastReading)
    }

    @objc private func showTuner() {
        if let existing = tunerPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "PowerHUD 样式调整"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        makeStyleRow("宽度", tag: 0, min: 120, max: 320, value: style.width, decimals: 0, stack: stack)
        makeStyleRow("高度", tag: 1, min: 60, max: 240, value: style.height, decimals: 0, stack: stack)
        makeStyleRow("主数值字号", tag: 2, min: 10, max: 32, value: style.heroFont, decimals: 1, stack: stack)
        makeStyleRow("单位字号", tag: 3, min: 6, max: 18, value: style.unitFont, decimals: 1, stack: stack)
        makeStyleRow("模式字号", tag: 4, min: 6, max: 16, value: style.modeFont, decimals: 1, stack: stack)
        makeStyleRow("指标字号", tag: 5, min: 6, max: 16, value: style.detailFont, decimals: 1, stack: stack)
        makeStyleRow("两侧边距", tag: 6, min: 4, max: 30, value: style.sidePadding, decimals: 0, stack: stack)
        makeStyleRow("顶部边距", tag: 7, min: 4, max: 50, value: style.topPadding, decimals: 0, stack: stack)
        makeStyleRow("行间距", tag: 8, min: 2, max: 20, value: style.rowGap, decimals: 0, stack: stack)
        makeStyleRow("圆角", tag: 9, min: 6, max: 34, value: style.cornerRadius, decimals: 0, stack: stack)

        let copyButton = NSButton(title: "复制参数", target: self, action: #selector(copyStyle))
        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetStyle))
        let buttonRow = NSStackView(views: [copyButton, resetButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        stack.addArrangedSubview(buttonRow)

        let content = p.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        tunerPanel = p
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeStyleRow(_ title: String, tag: Int, min: Double, max: Double,
                              value: CGFloat, decimals: Int, stack: NSStackView) {
        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 76).isActive = true

        let slider = NSSlider(value: Double(value), minValue: min, maxValue: max,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.tag = tag
        slider.isContinuous = true
        slider.controlSize = .small

        let val = NSTextField(labelWithString: formatValue(Double(value), decimals: decimals))
        val.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        val.alignment = .right
        val.translatesAutoresizingMaskIntoConstraints = false
        val.widthAnchor.constraint(equalToConstant: 40).isActive = true

        sliders[tag] = slider
        valueLabels[tag] = val

        let row = NSStackView(views: [name, slider, val])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(row)
    }

    private func formatValue(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue)
        switch sender.tag {
        case 0: style.width = v
        case 1: style.height = v
        case 2: style.heroFont = v
        case 3: style.unitFont = v
        case 4: style.modeFont = v
        case 5: style.detailFont = v
        case 6: style.sidePadding = v
        case 7: style.topPadding = v
        case 8: style.rowGap = v
        case 9: style.cornerRadius = v
        default: break
        }
        let decimals = [2, 3, 4, 5].contains(sender.tag) ? 1 : 0
        valueLabels[sender.tag]?.stringValue = formatValue(sender.doubleValue, decimals: decimals)
        applyStyle()
    }

    @objc private func copyStyle() {
        let summary = String(format:
            "width=%.0f height=%.0f heroFont=%.1f unitFont=%.1f modeFont=%.1f detailFont=%.1f sidePadding=%.0f topPadding=%.0f rowGap=%.0f cornerRadius=%.0f",
            style.width, style.height, style.heroFont, style.unitFont,
            style.modeFont, style.detailFont, style.sidePadding,
            style.topPadding, style.rowGap, style.cornerRadius)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(summary, forType: .string)
    }

    @objc private func resetStyle() {
        style = HUDStyle()
        for (tag, slider) in sliders {
            let v: CGFloat
            switch tag {
            case 0: v = style.width
            case 1: v = style.height
            case 2: v = style.heroFont
            case 3: v = style.unitFont
            case 4: v = style.modeFont
            case 5: v = style.detailFont
            case 6: v = style.sidePadding
            case 7: v = style.topPadding
            case 8: v = style.rowGap
            default: v = style.cornerRadius
            }
            slider.doubleValue = Double(v)
            let decimals = [2, 3, 4, 5].contains(tag) ? 1 : 0
            valueLabels[tag]?.stringValue = formatValue(Double(v), decimals: decimals)
        }
        applyStyle()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
