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
        if let i = args.firstIndex(of: "--iconset"), i + 1 < args.count {
            IconMaker.run(dir: args[i + 1])
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
    @Published var hovered: String?          // id of the panel row under the pointer
    @Published var selectedDay: Int?         // 按日 view; nil = today
    @Published var scrub: (agent: Agent, day: Int)?   // day bar under the pointer
    /// Tokens went up in the last scan → the flame burns until this moment.
    var burningUntil = Date.distantPast
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
            var s = aggregate(scanner.cache, gemini: scanner.geminiAppMessages(), geminiQuota: scanner.geminiQuota())
            s.skippedZst = scanner.skippedZst
            s.scanSeconds = scanner.lastScanSeconds
            let result = s
            await MainActor.run {
                if !self.indexing, result.total(3).total > self.snap.total(3).total
                    || result.gemini.msgs[3] > self.snap.gemini.msgs[3] {
                    self.burningUntil = Date().addingTimeInterval(8)
                }
                self.snap = result
                self.indexing = false
                self.busy = false
                self.onChange?()
            }
        }
    }

    func saveNow() { scanner.save() }

    /// Offline snapshots: fill in the Gemini app counts synchronously.
    func applyGeminiForSnapshot() {
        snap = aggregate(scanner.cache, gemini: scanner.geminiAppMessages(), geminiQuota: scanner.geminiQuota())
        indexing = false
    }
}

// MARK: - Menu bar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let store = Store()
    private var timer: Timer?
    private var animTimer: Timer?
    private var watcher: FSWatcher?
    private var phase = 0.0
    private var alertUntil = Date.distantPast

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
        store.onChange = { [weak self] in self?.afterRefresh() }
        updateTitle()
        store.refresh()
        timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        // React within a second or two when any agent writes to its logs.
        let home = NSHomeDirectory()
        watcher = FSWatcher(paths: [home + "/.claude/projects", home + "/.codex/sessions",
                                    home + "/.workbuddy/projects", home + "/.gemini/tmp",
                                    home + "/Library/Caches/com.google.GeminiMacOS/Gemini"]) { [weak self] in
            self?.store.refresh()
        }
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

    private func afterRefresh() {
        // Any subscription window at ≥90% that hasn't alerted yet → flash red for 10 s, once.
        let keys = quotaAlerts(store.snap)
        var seen = Set(UserDefaults.standard.stringArray(forKey: "alertedKeys") ?? [])
        let fresh = keys.filter { !seen.contains($0) }
        if !fresh.isEmpty {
            alertUntil = Date().addingTimeInterval(10)
            fresh.forEach { seen.insert($0) }
            UserDefaults.standard.set(Array(seen.suffix(200)), forKey: "alertedKeys")
        }
        updateTitle()
        updateAnimation()
    }

    private var level: Double {
        let s = store.snap
        return s.dailyTotalMax > 0 ? Double(s.total(0).total) / Double(s.dailyTotalMax) : 0
    }

    private func updateAnimation() {
        let now = Date()
        let active = store.burningUntil > now || alertUntil > now
        if active && animTimer == nil {
            animTimer = Timer.scheduledTimer(timeInterval: 1.0 / 12, target: self, selector: #selector(frame),
                                             userInfo: nil, repeats: true)
        } else if !active {
            animTimer?.invalidate(); animTimer = nil
            item.button?.image = flameIcon(level: level)
        }
    }

    @objc private func frame() {
        let now = Date()
        phase += 1.0 / 12
        if alertUntil > now {
            // 0.5 s red, 0.5 s normal
            let red = Int(alertUntil.timeIntervalSince(now) * 2) % 2 == 0
            item.button?.image = red ? flameIcon(level: 1, phase: phase, color: .systemRed)
                                     : flameIcon(level: level, phase: phase)
        } else if store.burningUntil > now {
            item.button?.image = flameIcon(level: level, phase: phase)
        } else {
            updateAnimation()
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
        if animTimer == nil { b.image = flameIcon(level: level) }
        b.toolTip = "Tfire · 今日 \(cn(today)) token"
    }
}

/// FSEvents on the agents' log folders; calls back on the main queue at most once a second.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init(paths: [String], handler: @escaping () -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
            FSEventStreamStart(s)
        }
    }

    deinit {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
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
/// day of the last 30 days. `phase` (seconds) makes the tongues sway like a live flame;
/// `color` draws a non-template coloured flame (used for the red quota alert).
func flameIcon(level: Double, phase: Double? = nil, color: NSColor? = nil) -> NSImage {
    // Sway offsets, all zero for the still icon.
    var tx: CGFloat = 0, ty: CGFloat = 0, sx: CGFloat = 0, sy: CGFloat = 0, fl: Double = 0
    if let p = phase {
        tx = CGFloat(0.55 * sin(p * 7.1) + 0.25 * sin(p * 12.7))
        ty = CGFloat(0.35 * sin(p * 9.3 + 1.1))
        sx = CGFloat(0.45 * sin(p * 8.2 + 2.0))
        sy = CGFloat(0.55 * sin(p * 10.9 + 0.4))
        fl = 0.05 * sin(p * 11.3)
    }
    let img = NSImage(size: NSSize(width: 11, height: 17), flipped: false) { _ in
        (color ?? NSColor.black).set()
        let p = NSBezierPath()
        func c(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            p.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x1, y: y1), controlPoint2: NSPoint(x: x2, y: y2))
        }
        p.move(to: NSPoint(x: 5.5, y: 0.8))
        c(8.3, 0.8, 10.0, 2.9, 10.0, 5.7)                                   // right belly
        c(10.0, 9.6, 6.6 + tx * 0.5, 11.6, 6.6 + tx, 16.2 + ty)             // up to the main tongue (≤16.55: stays inside 17 pt)
        c(5.6 + tx, 14.0 + ty * 0.6, 4.4, 12.6, 4.5, 10.2)                  // down into the notch
        c(3.7, 11.2, 2.9 + sx * 0.5, 12.0 + sy * 0.5, 2.7 + sx, 13.2 + sy)  // small left tongue
        c(1.4 + sx * 0.3, 11.0, 1.0, 8.2, 1.0, 5.7)                         // left side
        c(1.0, 2.9, 2.7, 0.8, 5.5, 0.8)                                     // base
        p.close()
        p.lineWidth = 1
        p.lineJoinStyle = .round
        p.stroke()
        let lv = max(0, min(1, level + fl))
        if lv > 0.02 {
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            let top = CGFloat(0.8 + 15.8 * lv)
            if let ph = phase, lv < 0.97 {
                // a licking, uneven top edge while burning instead of a still waterline
                let f = NSBezierPath()
                f.move(to: NSPoint(x: 0, y: 0))
                f.line(to: NSPoint(x: 11, y: 0))
                var x: CGFloat = 11
                while x >= 0 {
                    let w = 0.55 * sin(Double(x) * 1.5 + ph * 9.0) + 0.3 * sin(Double(x) * 2.9 - ph * 13.0)
                    f.line(to: NSPoint(x: x, y: top + CGFloat(w)))
                    x -= 0.5
                }
                f.close()
                f.fill()
            } else {
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 11, height: top)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return true
    }
    img.isTemplate = color == nil
    return img
}

/// Side-by-side menu-bar mock of the two icon ideas, light and dark, three levels.
func iconComparison() -> NSImage? {
    let rows: [(String, (Double) -> NSImage)] = [("漏壶（原）", vesselIcon), ("火焰（新）", { flameIcon(level: $0) })]
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

// MARK: - App icon (Finder / DMG / Dock-less, but Finder and the DMG show it)

/// The menu-bar flame, enlarged: white outline on a near-black squircle, burning cinnabar
/// inside up to just past half — the same glyph you see in the menu bar, given a body.
func drawAppIcon(_ s: CGFloat) {
    let m = s * 100 / 1024
    let body = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
    let r = s * 185 / 1024
    let bg = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
    NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))?.draw(in: bg, angle: -90)

    let h = s * 0.56, k = h / 17, w = 11 * k
    let ox = (s - w) / 2, oy = (s - h) / 2 - s * 0.01
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy + y * k) }
    let p = NSBezierPath()
    func c(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        p.curve(to: pt(x, y), controlPoint1: pt(x1, y1), controlPoint2: pt(x2, y2))
    }
    p.move(to: pt(5.5, 0.8))
    c(8.3, 0.8, 10.0, 2.9, 10.0, 5.7)
    c(10.0, 9.6, 6.6, 11.6, 6.6, 16.2)
    c(5.6, 14.0, 4.4, 12.6, 4.5, 10.2)
    c(3.7, 11.2, 2.9, 12.0, 2.7, 13.2)
    c(1.4, 11.0, 1.0, 8.2, 1.0, 5.7)
    c(1.0, 2.9, 2.7, 0.8, 5.5, 0.8)
    p.close()

    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    let top = 0.8 + 15.8 * 0.55
    let f = NSBezierPath()
    f.move(to: pt(0, 0)); f.line(to: pt(11, 0))
    var x: CGFloat = 11
    while x >= 0 {
        f.line(to: pt(x, CGFloat(top + 0.55 * sin(Double(x) * 1.5 + 0.8) + 0.3 * sin(Double(x) * 2.9 - 0.4))))
        x -= 0.25
    }
    f.close()
    NSColor(red: 0.84, green: 0.24, blue: 0.16, alpha: 1).setFill()
    f.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.setStroke()
    p.lineWidth = max(1, k * 0.8)
    p.lineJoinStyle = .round
    p.stroke()
}

enum IconMaker {
    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in specs {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawAppIcon(CGFloat(px))
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
    }
}

// MARK: - Self-check report (used by the installer)

func fmtDay(_ k: Int) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: dayDate(k))
}

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
        let t2 = Date()
        let gm = s.geminiAppMessages()
        let gq = s.geminiQuota()
        let snap = aggregate(s.cache, gemini: gm, geminiQuota: gq)
        let aggT = Date().timeIntervalSince(t2)

        var out = "Tfire 自检报告 \(Date())\n"
        out += "缓存: \(hadCache ? "已有" : "首次建立")  首轮扫描 \(String(format: "%.1f", first))s  增量扫描 \(String(format: "%.2f", second))s\n"
        out += "zstd: \(s.zstdPath ?? "未找到")  未计入的归档会话: \(s.skippedZst)  汇总耗时 \(String(format: "%.2f", aggT))s\n"
        out += "WorkBuddy 额度: " + snap.wbQuotas.map { "\($0.name) \(Int($0.q.percent))% 重置 \(Date(timeIntervalSince1970: $0.q.resetAt))" }.joined(separator: "; ") + "\n"
        out += "≥90% 提醒: " + quotaAlerts(snap).joined(separator: ", ") + "\n\n"
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
        // Records kept from files that no longer exist (agents delete some session files later).
        var gone: [Agent: Int] = [:]
        var goneDays: [Int: [String: Int]] = [:]
        for st in s.cache.files.values where !FileManager.default.fileExists(atPath: st.path) {
            gone[st.agent, default: 0] += 1
            for r in st.recs { goneDays[dayKey(r.t), default: [:]][r.m, default: 0] += r.total }
        }
        out += "已不在磁盘上的会话文件: " + gone.map { "\($0.key.title) \($0.value)" }.joined(separator: ", ") + "\n"
        for k in goneDays.keys.sorted().suffix(12) {
            let m = goneDays[k]!.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            out += "  " + fmtDay(k) + " 来自已删文件: \(goneDays[k]!.values.reduce(0, +))  \(m)\n"
        }
        out += "\n"
        let g = snap.gemini
        out += "[Gemini 桌面 App] \(g.found ? "找到" : "未找到")  消息 今日/7日/30日/累计: \(g.msgs.map(String.init).joined(separator: "/"))  对话: \(g.chats.map(String.init).joined(separator: "/"))\n"
        out += "  近7天消息: " + g.daily.suffix(7).map(String.init).joined(separator: " ") + "\n"
        out += "  额度: " + (g.overQuotaModes.map { "\($0) 个模式超额，记录于 \(Date(timeIntervalSince1970: g.quotaT))" } ?? "日志里没有") + "\n\n"
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
        store.applyGeminiForSnapshot()
        let variants: [(String, ColorScheme, Int, Agent?)] = [
            ("panel-light-today", .light, 0, nil),
            ("panel-dark-today", .dark, 0, nil),
            ("panel-light-30d-open", .light, 2, .workbuddy),
            ("panel-light-hover", .light, 0, nil),
            ("panel-light-7d", .light, 1, nil),
            ("panel-light-day", .light, 4, nil),
        ]
        for (name, scheme, period, open) in variants {
            store.period = period
            store.expanded = open
            store.hovered = name.hasSuffix("hover") ? "row-codex" : nil
            // 按日 sample: the busiest day of the last 30, so the frame shows real numbers
            store.selectedDay = name.hasSuffix("day")
                ? (store.snap.days.filter { $0.key > store.snap.todayKey - 30 }.max { $0.value.total < $1.value.total }?.key)
                : nil
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
        // animation frames of the menu-bar flame: 24 burning frames, then a red/normal alert pair
        let frames: [(String, NSImage)] =
            (0..<24).map { i in (String(format: "anim-burn-%02d", i), flameIcon(level: 0.5, phase: Double(i) / 12)) } +
            [("anim-alert-red", flameIcon(level: 1, phase: 0.3, color: .systemRed)),
             ("anim-alert-off", flameIcon(level: 0.5, phase: 0.3))]
        for (name, img) in frames {
            let big = NSImage(size: NSSize(width: 66, height: 102))
            big.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 66, height: 102).fill()
            img.draw(in: NSRect(x: 0, y: 0, width: 66, height: 102))
            big.unlockFocus()
            if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
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
