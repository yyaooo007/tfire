import AppKit
import SwiftUI
import ServiceManagement

@main
@MainActor
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--report"), i + 1 < args.count {
            Report.run(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshotter.run(dir: args[i + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var snap = Snapshot()
    @Published var indexing = true
    @Published var barStyle: Int = UserDefaults.standard.integer(forKey: "barStyle") {
        didSet { UserDefaults.standard.set(barStyle, forKey: "barStyle"); onChange?() }
    }
    @Published var period = 0
    @Published var expanded: Agent?
    @Published var loginOn = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?

    private let scanner = Scanner()
    private var busy = false

    init() {
        // Show what the cache already knows straight away; the scan then catches up.
        let s = aggregate(scanner.cache)
        snap = s
        indexing = s.isEmpty
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let scanner = self.scanner
        Task.detached(priority: .utility) {
            scanner.scan()
            var s = aggregate(scanner.cache)
            s.skippedZst = scanner.skippedZst
            s.scanSeconds = scanner.lastScanSeconds
            let result = s
            await MainActor.run {
                self.snap = result
                self.indexing = false
                self.busy = false
                self.onChange?()
            }
        }
    }

    func saveNow() { scanner.save() }
}

// MARK: - Menu bar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let store = Store()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.imagePosition = .imageLeading
        }
        let hc = NSHostingController(rootView: PanelView(store: store))
        hc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hc
        popover.behavior = .transient
        popover.animates = false
        store.onChange = { [weak self] in self?.updateTitle() }
        updateTitle()
        store.refresh()
        timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) { store.saveNow() }

    @objc private func tick() { store.refresh() }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let b = item.button {
            store.refresh()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateTitle() {
        guard let b = item.button else { return }
        let s = store.snap
        let today = s.total(0).total
        let text: String
        if store.indexing && s.isEmpty {
            text = "索引中"
        } else if store.barStyle == 1 {
            let parts = Agent.allCases.compactMap { a -> String? in
                let v = s.stats[a.idx].periods[0].total
                return v > 0 ? "\(a.short) \(cn(v))" : nil
            }
            text = parts.isEmpty ? "0" : parts.joined(separator: "  ")
        } else {
            text = cn(today)
        }
        b.attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .baselineOffset: 0.5,
        ])
        let level = s.dailyTotalMax > 0 ? Double(today) / Double(s.dailyTotalMax) : 0
        b.image = flameIcon(level: level)
        b.toolTip = "Tfire · 今日 \(cn(today)) token"
    }
}

/// Outflow vessel with a drip (first icon, kept for comparison). The water level is today's usage against the
/// busiest day of the last 30 days.
func vesselIcon(level: Double) -> NSImage {
    let img = NSImage(size: NSSize(width: 11, height: 17), flipped: false) { _ in
        NSColor.black.set()
        let v = NSRect(x: 1.5, y: 5.5, width: 8, height: 10)
        let path = NSBezierPath(roundedRect: v, xRadius: 1.6, yRadius: 1.6)
        path.lineWidth = 1
        path.stroke()
        let inner = v.height - 3
        let h = max(0, min(1, level)) * inner
        if h >= 0.6 {
            NSBezierPath(rect: NSRect(x: v.minX + 1.5, y: v.minY + 1.5, width: v.width - 3, height: h)).fill()
        }
        NSBezierPath(rect: NSRect(x: 5.0, y: 3.2, width: 1, height: 1.6)).fill()      // spout
        NSBezierPath(ovalIn: NSRect(x: 4.3, y: 0.3, width: 2.4, height: 2.4)).fill()   // drop
        return true
    }
    img.isTemplate = true
    return img
}

/// Tfire: a flame outline; the fire inside rises with today's usage against the busiest
/// day of the last 30 days.
func flameIcon(level: Double) -> NSImage {
    let img = NSImage(size: NSSize(width: 11, height: 17), flipped: false) { _ in
        NSColor.black.set()
        let p = NSBezierPath()
        func c(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            p.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x1, y: y1), controlPoint2: NSPoint(x: x2, y: y2))
        }
        p.move(to: NSPoint(x: 5.5, y: 0.8))
        c(8.3, 0.8, 10.0, 2.9, 10.0, 5.7)      // right belly
        c(10.0, 9.6, 6.6, 11.6, 6.6, 16.6)     // up to the main tongue
        c(5.6, 14.0, 4.4, 12.6, 4.5, 10.2)     // down into the notch
        c(3.7, 11.2, 2.9, 12.0, 2.7, 13.2)     // small left tongue
        c(1.4, 11.0, 1.0, 8.2, 1.0, 5.7)       // left side
        c(1.0, 2.9, 2.7, 0.8, 5.5, 0.8)        // base
        p.close()
        p.lineWidth = 1
        p.lineJoinStyle = .round
        p.stroke()
        let lv = max(0, min(1, level))
        if lv > 0.02 {
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 11, height: 0.8 + 15.8 * lv)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        return true
    }
    img.isTemplate = true
    return img
}

/// Side-by-side menu-bar mock of the two icon ideas, light and dark, three levels.
func iconComparison() -> NSImage? {
    let rows: [(String, (Double) -> NSImage)] = [("漏壶（原）", vesselIcon), ("火焰（新）", flameIcon)]
    let levels = [0.0, 0.5, 1.0]
    let cellW: CGFloat = 150, rowH: CGFloat = 44, labelW: CGFloat = 110
    let W = labelW + cellW * CGFloat(levels.count) * 2, H = rowH * CGFloat(rows.count) + 30
    let out = NSImage(size: NSSize(width: W, height: H))
    out.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.gray]
    for (k, lv) in levels.enumerated() {
        for (d, dark) in [false, true].enumerated() {
            let x = labelW + cellW * CGFloat(d * levels.count + k)
            ("\(dark ? "深色" : "浅色") \(Int(lv * 100))%" as NSString).draw(at: NSPoint(x: x + 10, y: H - 22), withAttributes: small)
        }
    }
    for (r, row) in rows.enumerated() {
        let y = H - 30 - rowH * CGFloat(r + 1)
        (row.0 as NSString).draw(at: NSPoint(x: 10, y: y + 14), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
        for (k, lv) in levels.enumerated() {
            for (d, dark) in [false, true].enumerated() {
                let x = labelW + cellW * CGFloat(d * levels.count + k)
                let bg = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)
                bg.setFill(); NSRect(x: x + 4, y: y + 6, width: cellW - 8, height: rowH - 12).fill()
                let fg = dark ? NSColor.white : NSColor.black
                // tint the template glyph
                let glyph = row.1(lv)
                let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                    glyph.draw(in: rect); fg.set(); rect.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: x + 30, y: y + 13, width: 11, height: 17))
                (" 7709万" as NSString).draw(at: NSPoint(x: x + 42, y: y + 14), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: fg])
            }
        }
    }
    out.unlockFocus()
    return out
}

// MARK: - Self-check report (used by the installer)

enum Report {
    static func run(to path: String) {
        let s = Scanner()
        let hadCache = !s.cache.files.isEmpty
        let t0 = Date()
        s.scan(forceSave: true)
        let first = Date().timeIntervalSince(t0)
        let t1 = Date()
        s.scan(forceSave: true)
        let second = Date().timeIntervalSince(t1)
        let snap = aggregate(s.cache)

        var out = "Tfire 自检报告 \(Date())\n"
        out += "缓存: \(hadCache ? "已有" : "首次建立")  首轮扫描 \(String(format: "%.1f", first))s  增量扫描 \(String(format: "%.2f", second))s\n"
        out += "zstd: \(s.zstdPath ?? "未找到")  未计入的归档会话: \(s.skippedZst)\n\n"
        let names = ["今日", "7日", "30日", "累计"]
        for a in Agent.allCases {
            let st = snap.stats[a.idx]
            out += "[\(a.title)] 文件 \(st.files)\n"
            for p in 0..<4 {
                let b = st.periods[p]
                out += "  \(names[p]): 合计 \(b.total)  输入 \(b.i)  缓存读 \(b.cr)  缓存写 \(b.cw)  输出 \(b.o)\n"
            }
            let top = st.models[2].sorted { $0.value > $1.value }.prefix(6)
            out += "  30日模型: " + top.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "\n"
            out += "  近7天: " + st.daily.suffix(7).map(String.init).joined(separator: " ") + "\n\n"
        }
        // Claude diagnostics: where the files are and what their usage lines look like.
        let fm = FileManager.default
        out += "Claude 目录: ~/.claude/projects \(fm.fileExists(atPath: s.home.path + "/.claude/projects") ? "存在" : "不存在")"
        out += "，~/.claude \(fm.fileExists(atPath: s.home.path + "/.claude") ? "存在" : "不存在")\n"
        for c in s.candidates() where c.agent == .claude {
            let short = c.path.replacingOccurrences(of: s.home.path, with: "~")
            var n = 0, usage = 0
            var sample = ""
            if let text = try? String(contentsOfFile: c.path, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    n += 1
                    if line.contains("\"usage\"") {
                        usage += 1
                        if sample.isEmpty, let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                            sample = "keys=\(o.keys.sorted()) type=\(o["type"] ?? "-")"
                        }
                    }
                }
            }
            out += "  \(short)  行 \(n)  含usage \(usage)  \(sample)\n"
        }
        out += "\n"
        if let l = snap.limits {
            out += "Codex 额度 (记录于 \(Date(timeIntervalSince1970: l.t))) plan=\(l.plan ?? "-")\n"
            if let w = l.primary { out += "  primary \(w.windowMin)min used \(w.used)% resets \(Date(timeIntervalSince1970: w.resetsAt))\n" }
            if let w = l.secondary { out += "  secondary \(w.windowMin)min used \(w.used)% resets \(Date(timeIntervalSince1970: w.resetsAt))\n" }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        print(out)
    }
}

// MARK: - Panel snapshots (visual check without opening the menu)

@MainActor
enum Snapshotter {
    static func run(dir: String) {
        let store = Store()           // reads the cache built by --report
        let variants: [(String, ColorScheme, Int, Agent?)] = [
            ("panel-light-today", .light, 0, nil),
            ("panel-dark-today", .dark, 0, nil),
            ("panel-light-30d-open", .light, 2, .workbuddy),
        ]
        for (name, scheme, period, open) in variants {
            store.period = period
            store.expanded = open
            let view = PanelView(store: store)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        if let cmp = iconComparison(), let tiff = cmp.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon-compare.png"))
        }
        // the menu-bar glyph at a few water levels
        for lv in [0.0, 0.35, 1.0] {
            let img = vesselIcon(level: lv)
            let big = NSImage(size: NSSize(width: 66, height: 102))
            big.lockFocus()
            img.draw(in: NSRect(x: 0, y: 0, width: 66, height: 102))
            big.unlockFocus()
            if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon-\(Int(lv * 100)).png"))
            }
        }
    }
}
