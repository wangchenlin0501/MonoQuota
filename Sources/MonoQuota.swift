import AppKit
import Carbon
import Foundation
import SwiftUI

private struct SavedShortcut: Codable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
}

private struct Quota: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
        let resetsAt: Int?
    }
    struct Limits: Decodable {
        let primary: Window?
        let secondary: Window?
    }
    let rateLimits: Limits?
}

private struct QuotaSnapshot {
    struct Window {
        let remainingPercent: Int?
        let resetsAt: Date?
    }
    let fiveHour: Window
    let week: Window
}

private enum QuotaReader {
    static func executable() -> URL? {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let candidates = [
            installed?.appendingPathComponent("Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func read() -> QuotaSnapshot? {
        guard let executable = executable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "mono-quota", "version": "1.0"]]],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "account/rateLimits/read", "params": [:]],
        ]
        for message in messages {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return nil }
        }

        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            pending.append(chunk)
            if pending.count > 2_000_000 { return nil }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int, id == 2,
                      let result = message["result"],
                      let resultData = try? JSONSerialization.data(withJSONObject: result),
                      let quota = try? JSONDecoder().decode(Quota.self, from: resultData)
                else { continue }
                func remainingPercentage(_ used: Double?) -> Int? {
                    guard let used, used.isFinite else { return nil }
                    return Int((100 - min(100, max(0, used))).rounded())
                }
                func window(_ source: Quota.Window?) -> QuotaSnapshot.Window {
                    QuotaSnapshot.Window(
                        remainingPercent: remainingPercentage(source?.usedPercent),
                        resetsAt: source?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    )
                }
                return QuotaSnapshot(fiveHour: window(quota.rateLimits?.primary),
                                     week: window(quota.rateLimits?.secondary))
            }
        }
    }
}

private enum DisplayMode: String, CaseIterable {
    case numberOnly
    case barAndNumber
    case barOnly

    var title: String {
        switch self {
        case .numberOnly: "仅数字"
        case .barAndNumber: "进度条 + 数字"
        case .barOnly: "仅进度条"
        }
    }
}

private enum MeterRenderer {
    private static let labelWidth: CGFloat = 30
    private static let barWidth: CGFloat = 48
    private static let numberWidth: CGFloat = ceil(("100%" as NSString).size(withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
    ]).width)

    static func size(fiveMode: DisplayMode, weekMode: DisplayMode) -> NSSize {
        let contentWidth = max(rowWidth(fiveMode), rowWidth(weekMode))
        return NSSize(width: contentWidth, height: 20)
    }

    private static func rowWidth(_ mode: DisplayMode) -> CGFloat {
        switch mode {
        case .numberOnly: labelWidth + numberWidth
        case .barAndNumber: labelWidth + barWidth + 5 + numberWidth
        case .barOnly: labelWidth + barWidth
        }
    }

    static func image(fiveHour: Int?, week: Int?,
                      fiveMode: DisplayMode, weekMode: DisplayMode) -> NSImage {
        let image = NSImage(size: size(fiveMode: fiveMode, weekMode: weekMode), flipped: false) { _ in
            drawRow(label: "5h", value: fiveHour, mode: fiveMode, y: 10)
            drawRow(label: "Week", value: week, mode: weekMode, y: 1)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawRow(label: String, value: Int?, mode: DisplayMode, y: CGFloat) {
        let ink = NSColor.labelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        (label as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: [
            .font: font, .foregroundColor: ink,
        ])

        if mode != .numberOnly {
            let track = NSRect(x: labelWidth, y: y + 2.5, width: barWidth, height: 4)
            ink.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            if let value, value > 0 {
                let fill = NSRect(x: track.minX, y: track.minY,
                                  width: track.width * CGFloat(value) / 100, height: track.height)
                ink.setFill()
                NSBezierPath(roundedRect: fill, xRadius: min(2, fill.width / 2), yRadius: 2).fill()
            }
        }

        if mode != .barOnly {
            let percent = value.map { "\($0)%" } ?? "--"
            let x = mode == .numberOnly ? labelWidth : labelWidth + barWidth + 5
            (percent as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: font, .foregroundColor: ink,
            ])
        }
    }
}

private final class DetailModel: ObservableObject {
    @Published var snapshot: QuotaSnapshot?
    @Published var updatedAt: Date?
    @Published var isRefreshing = false
    @Published var fiveMode: DisplayMode = .barAndNumber {
        didSet {
            UserDefaults.standard.set(fiveMode.rawValue, forKey: "fiveHourDisplayMode")
            onDisplayModeChanged?()
        }
    }
    @Published var weekMode: DisplayMode = .barAndNumber {
        didSet {
            UserDefaults.standard.set(weekMode.rawValue, forKey: "weekDisplayMode")
            onDisplayModeChanged?()
        }
    }
    var onDisplayModeChanged: (() -> Void)?
    @Published var shortcutLabel = "未设置"
    @Published var isRecordingShortcut = false
    @Published var shortcutError: String?
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            content
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct QuotaCard: View {
    let title: String
    let symbol: String
    let window: QuotaSnapshot.Window?
    let tint: Color

    private var remaining: Int? { window?.remainingPercent }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GlassCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(title, systemImage: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(remaining.map { "\($0)%" } ?? "--")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("剩余")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.10))
                            if let remaining {
                                Capsule()
                                    .fill(LinearGradient(colors: [tint.opacity(0.72), tint],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geometry.size.width * CGFloat(remaining) / 100)
                                    .overlay(alignment: .top) {
                                        Capsule().fill(.white.opacity(0.30)).frame(height: 1.5)
                                            .padding(.horizontal, 3)
                                    }
                                    .shadow(color: tint.opacity(0.28), radius: 4, y: 0)
                                    .shadow(color: tint.opacity(0.12), radius: 8, y: 0)
                                    .animation(.easeInOut(duration: 0.55), value: remaining)
                            }
                        }
                    }
                    .frame(height: 9)

                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("重置：\(resetMoment(window?.resetsAt, now: context.date))")
                        Spacer(minLength: 6)
                        Text(countdown(window?.resetsAt, now: context.date))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
    }

    private func resetMoment(_ date: Date?, now: Date) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: date))"
        }
        if Calendar.current.isDate(date, inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now) {
            formatter.dateFormat = "HH:mm"
            return "明天 \(formatter.string(from: date))"
        }
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func countdown(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes == 0 { return "即将重置" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainingMinutes = minutes % 60
        if days > 0 { return "还有 \(days)天\(hours)小时" }
        if hours > 0 { return "还有 \(hours)小时\(remainingMinutes)分" }
        return "还有 \(remainingMinutes)分"
    }
}

private struct DetailView: View {
    @ObservedObject var model: DetailModel
    let refresh: () -> Void
    let recordShortcut: () -> Void
    let clearShortcut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 额度")
                        .font(.system(size: 16, weight: .bold))
                    Text("5 小时与周额度 · 剩余量")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }

            QuotaCard(title: "5 小时", symbol: "clock", window: model.snapshot?.fiveHour,
                      tint: .cyan)
            QuotaCard(title: "周额度", symbol: "calendar", window: model.snapshot?.week,
                      tint: .indigo)

            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                Text("打开额度面板")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(model.isRecordingShortcut ? "请按新组合键…" : model.shortcutLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Button(model.isRecordingShortcut ? "取消" : "设置快捷键", action: recordShortcut)
                if model.shortcutLabel != "未设置" {
                    Button("清除", action: clearShortcut)
                }
            }
            .buttonStyle(.borderless)
            if let error = model.shortcutError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }

            HStack(spacing: 6) {
                Text(model.updatedAt.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" }
                     ?? "等待额度数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("立即刷新")

                Menu {
                    Picker("5h 显示方式", selection: $model.fiveMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("Week 显示方式", selection: $model.weekMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("菜单栏显示设置")

                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .help("退出")
            }
            .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(width: 356)
    }
}

private final class MeterContentView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2,
                              y: (bounds.height - image.size.height) / 2,
                              width: image.size.width, height: image.size.height))
    }
}

private final class SelectionBackdrop: NSView {
    private let plainContent = MeterContentView()
    private let selectedContent = MeterContentView()
    private let material: NSView
    var image: NSImage? {
        didSet { plainContent.image = image; selectedContent.image = image }
    }
    var isSelected = false {
        didSet { material.isHidden = !isSelected; plainContent.isHidden = isSelected }
    }
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 11
            glass.contentView = selectedContent
            material = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .selection
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 11
            effect.layer?.masksToBounds = true
            effect.addSubview(selectedContent)
            material = effect
        }
        super.init(frame: frame)
        addSubview(material)
        addSubview(plainContent)
        material.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        material.frame = bounds
        plainContent.frame = bounds
        selectedContent.frame = material.bounds
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        }
    }
}

private final class QuotaPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let selectionBackdrop = SelectionBackdrop()
    private let panel = QuotaPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model = DetailModel()
    private var timer: Timer?
    private var refreshing = false
    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var shortcutRecorder: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var savedShortcut: SavedShortcut?
    #if PREVIEW
    private var previewWindow: NSWindow?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if PREVIEW
        NSApp.setActivationPolicy(.regular)
        model.snapshot = QuotaSnapshot(
            fiveHour: .init(remainingPercent: 15, resetsAt: Date().addingTimeInterval(2 * 3600)),
            week: .init(remainingPercent: 60, resetsAt: Date().addingTimeInterval(6 * 86400))
        )
        model.updatedAt = Date()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MonoQuota 预览"
        window.contentViewController = NSHostingController(rootView: DetailView(model: model, refresh: {}, recordShortcut: {}, clearShortcut: {}))
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        return
        #endif
        NSApp.setActivationPolicy(.accessory)
        model.fiveMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "fiveHourDisplayMode") ?? "")
            ?? .barAndNumber
        model.weekMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "weekDisplayMode") ?? "")
            ?? .barAndNumber
        model.onDisplayModeChanged = { [weak self] in self?.updateMeter() }
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            selectionBackdrop.frame = button.bounds
            selectionBackdrop.autoresizingMask = [.width, .height]
            selectionBackdrop.isSelected = false
            button.addSubview(selectionBackdrop)
            button.toolTip = "Codex 剩余额度：5 小时与周额度"
            button.target = self
            button.action = #selector(togglePopover)
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        panel.contentViewController = NSHostingController(rootView: DetailView(
            model: model,
            refresh: { [weak self] in self?.refresh() },
            recordShortcut: { [weak self] in self?.toggleShortcutRecording() },
            clearShortcut: { [weak self] in self?.clearShortcut() }
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18)))
        installHotKeyHandler()
        if let data = UserDefaults.standard.data(forKey: "globalShortcut"),
           let shortcut = try? JSONDecoder().decode(SavedShortcut.self, from: data) {
            if register(shortcut) { savedShortcut = shortcut; model.shortcutLabel = shortcut.label }
            else { model.shortcutError = "快捷键已被其他应用占用，请重新设置" }
        }
        updateMeter()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in self?.togglePopoverFromShortcut() }
        }
    }

    private func updateMeter() {
        selectionBackdrop.image = MeterRenderer.image(
            fiveHour: model.snapshot?.fiveHour.remainingPercent,
            week: model.snapshot?.week.remainingPercent,
            fiveMode: model.fiveMode,
            weekMode: model.weekMode
        )
        statusItem.length = MeterRenderer.size(fiveMode: model.fiveMode,
                                               weekMode: model.weekMode).width + 8
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPopover(anchoredTo: button)
        }
    }

    private func showPopover(anchoredTo button: NSStatusBarButton, attempt: Int = 0) {
        guard let window = button.window, let screen = window.screen,
              let content = panel.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        // A newly created status item temporarily reports an off-screen frame.
        guard anchor.minY >= screen.visibleFrame.maxY - 2,
              anchor.intersects(screen.frame) else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.showPopover(anchoredTo: button, attempt: attempt + 1)
                }
            } else if CommandLine.arguments.contains("--check-panel") {
                print("FAIL: menu item has no valid screen position")
                exit(1)
            }
            return
        }
        // Use screen coordinates explicitly: the entire panel stays below the menu bar.
        let top = min(anchor.minY, screen.visibleFrame.maxY) - 4
        let x = min(max(anchor.maxX - size.width, screen.visibleFrame.minX + 8),
                    screen.visibleFrame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        // Native glass owns its content view, keeping all text above the material.
        selectionBackdrop.isSelected = true
        selectionBackdrop.needsDisplay = true
        watchOutsideClicks()
        if CommandLine.arguments.contains("--check-selection") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                // Simulate AppKit clearing the temporary pressed state after mouse-up.
                button.highlight(false)
                let stayedSelected = panel.isVisible && selectionBackdrop.isSelected
                    && selectionBackdrop.superview === button && selectionBackdrop.bounds.width > 0
                hidePanel()
                let cleared = !selectionBackdrop.isSelected && !panel.isVisible
                print(stayedSelected && cleared ? "PASS: selection persists after mouse-up and clears on dismissal" : "FAIL: selection state")
                exit(stayedSelected && cleared ? 0 : 1)
            }
        }
        if CommandLine.arguments.contains("--check-panel") {
            let frame = panel.frame
            print("Panel: \(frame); menu item: \(anchor); usable screen: \(screen.visibleFrame)")
            let valid = frame.maxY <= anchor.minY - 4 && frame.width == 356 && frame.height > 300
                && frame.minX >= screen.visibleFrame.minX && frame.maxX <= screen.visibleFrame.maxX
                && frame.minY >= screen.visibleFrame.minY && frame.maxY <= screen.visibleFrame.maxY
            print(valid ? "PASS: panel stays below menu bar and inside screen" : "FAIL: panel geometry")
            exit(valid ? 0 : 1)
        }
    }

    private func togglePopoverFromShortcut() {
        if panel.isVisible { hidePanel(); return }
        // The hotkey can arrive while another app owns the active menu bar.
        // Activate first, then let AppKit update the status item's position before anchoring.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button, !self.panel.isVisible else { return }
            self.showPopover(anchoredTo: button)
            self.panel.makeKey()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        selectionBackdrop.isSelected = false
        statusItem.button?.state = .off
        statusItem.button?.highlight(false)
        stopOutsideClickMonitoring()
        stopShortcutRecording()
    }

    private func watchOutsideClicks() {
        stopOutsideClickMonitoring()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            let panelWindow = self.panel
            let statusWindow = self.statusItem.button?.window
            if event.window !== panelWindow && event.window !== statusWindow && event.window?.level != .popUpMenu {
                self.hidePanel()
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let insideClickMonitor { NSEvent.removeMonitor(insideClickMonitor); self.insideClickMonitor = nil }
    }

    private func toggleShortcutRecording() {
        if model.isRecordingShortcut { stopShortcutRecording(); return }
        model.shortcutError = nil
        model.isRecordingShortcut = true
        shortcutRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureShortcut(event)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func stopShortcutRecording() {
        if let shortcutRecorder { NSEvent.removeMonitor(shortcutRecorder); self.shortcutRecorder = nil }
        model.isRecordingShortcut = false
    }

    private func captureShortcut(_ event: NSEvent) {
        if event.keyCode == 53 { stopShortcutRecording(); return } // Escape
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            model.shortcutError = "请同时按下 ⌘、⌥ 或 ⌃，避免占用普通输入"
            return
        }
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard key.count == 1, key.unicodeScalars.first?.isASCII == true,
              key.rangeOfCharacter(from: .alphanumerics) != nil else {
            model.shortcutError = "请选择字母或数字键"
            return
        }
        let prefix = (flags.contains(.control) ? "⌃" : "") +
                     (flags.contains(.option) ? "⌥" : "") +
                     (flags.contains(.shift) ? "⇧" : "") +
                     (flags.contains(.command) ? "⌘" : "")
        let candidate = SavedShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                                      label: prefix + key)
        guard register(candidate) else {
            model.shortcutError = "该快捷键已被占用，请换一个组合"
            return
        }
        savedShortcut = candidate
        model.shortcutLabel = candidate.label
        model.shortcutError = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(candidate), forKey: "globalShortcut")
        stopShortcutRecording()
    }

    private func clearShortcut() {
        stopShortcutRecording()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        savedShortcut = nil
        model.shortcutLabel = "未设置"
        model.shortcutError = nil
        UserDefaults.standard.removeObject(forKey: "globalShortcut")
    }

    private func register(_ shortcut: SavedShortcut) -> Bool {
        // Keep the old shortcut if the new combination cannot be registered.
        let old = savedShortcut
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let identifier = EventHotKeyID(signature: 0x4D515441, id: 1)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if result == noErr { return true }
        if let old {
            RegisterEventHotKey(old.keyCode, old.modifiers, identifier,
                                GetApplicationEventTarget(), 0, &hotKey)
        }
        return false
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            owner.togglePopoverFromShortcut()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        model.isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let values = QuotaReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.model.isRefreshing = false
                self.model.snapshot = values
                self.model.updatedAt = values == nil ? nil : Date()
                self.updateMeter()
            }
        }
    }
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(previewIndex + 1) {
    let image = MeterRenderer.image(fiveHour: 36, week: 79,
                                    fiveMode: .barAndNumber, weekMode: .barAndNumber)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1])) }
    catch { exit(1) }
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    if let quota = QuotaReader.read() {
        let five = quota.fiveHour.remainingPercent.map(String.init) ?? "--"
        let week = quota.week.remainingPercent.map(String.init) ?? "--"
        let formatter = ISO8601DateFormatter()
        print("5h \(five)% resets \(quota.fiveHour.resetsAt.map(formatter.string(from:)) ?? "--")")
        print("Week \(week)% resets \(quota.week.resetsAt.map(formatter.string(from:)) ?? "--")")
        exit(quota.fiveHour.remainingPercent != nil && quota.week.remainingPercent != nil ? 0 : 2)
    }
    fputs("Unable to read Codex quota\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
