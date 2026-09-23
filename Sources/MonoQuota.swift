import AppKit
import Foundation
import SwiftUI

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = DetailModel()
    private var timer: Timer?
    private var refreshing = false
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
        window.contentViewController = NSHostingController(rootView: DetailView(model: model) {})
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
            button.toolTip = "Codex 剩余额度：5 小时与周额度"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 356, height: 350)
        popover.contentViewController = NSHostingController(rootView: DetailView(model: model) { [weak self] in
            self?.refresh()
        })
        updateMeter()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func updateMeter() {
        statusItem.button?.image = MeterRenderer.image(
            fiveHour: model.snapshot?.fiveHour.remainingPercent,
            week: model.snapshot?.week.remainingPercent,
            fiveMode: model.fiveMode,
            weekMode: model.weekMode
        )
        statusItem.length = MeterRenderer.size(fiveMode: model.fiveMode,
                                               weekMode: model.weekMode).width + 6
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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
