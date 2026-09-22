import AppKit
import Foundation

private struct Quota: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
    }
    struct Limits: Decodable {
        let primary: Window?
        let secondary: Window?
    }
    let rateLimits: Limits?
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

    static func read() -> (Int?, Int?)? {
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
                return (remainingPercentage(quota.rateLimits?.primary?.usedPercent),
                        remainingPercentage(quota.rateLimits?.secondary?.usedPercent))
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
    private static let numberWidth: CGFloat = 28

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var refreshing = false
    private var lastUpdated: Date?
    private var lastValues: (Int?, Int?) = (nil, nil)
    private var fiveMode: DisplayMode = .barAndNumber
    private var weekMode: DisplayMode = .barAndNumber

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        fiveMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "fiveHourDisplayMode") ?? "")
            ?? .barAndNumber
        weekMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "weekDisplayMode") ?? "")
            ?? .barAndNumber
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "Codex 剩余额度：5 小时与周额度"
        }
        updateMeter()
        updateMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func updateMeter() {
        statusItem.button?.image = MeterRenderer.image(fiveHour: lastValues.0,
                                                        week: lastValues.1,
                                                        fiveMode: fiveMode,
                                                        weekMode: weekMode)
        statusItem.length = MeterRenderer.size(fiveMode: fiveMode, weekMode: weekMode).width + 6
    }

    private func updateMenu() {
        let menu = NSMenu()
        let info: String
        if let lastUpdated {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            info = "更新于 \(formatter.string(from: lastUpdated)) · 显示剩余额度"
        } else {
            info = "等待读取 Codex 额度"
        }
        let item = NSMenuItem(title: info, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
        menu.addItem(modeMenu(title: "5h 显示方式", selected: fiveMode, key: "fiveHourDisplayMode"))
        menu.addItem(modeMenu(title: "Week 显示方式", selected: weekMode, key: "weekDisplayMode"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.filter { $0.action != nil }.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func modeMenu(title: String, selected: DisplayMode, key: String) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, mode) in DisplayMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = key
            item.state = selected == mode ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard DisplayMode.allCases.indices.contains(sender.tag),
              let key = sender.representedObject as? String else { return }
        let mode = DisplayMode.allCases[sender.tag]
        switch key {
        case "fiveHourDisplayMode": fiveMode = mode
        case "weekDisplayMode": weekMode = mode
        default: return
        }
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        updateMeter()
        updateMenu()
    }

    @objc private func refreshFromMenu() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let values = QuotaReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.lastValues = values ?? (nil, nil)
                self.lastUpdated = values == nil ? nil : Date()
                self.updateMeter()
                self.updateMenu()
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
        print("5h \(quota.0.map(String.init) ?? "--")% · Week \(quota.1.map(String.init) ?? "--")%")
        exit(quota.0 != nil && quota.1 != nil ? 0 : 2)
    }
    fputs("Unable to read Codex quota\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
