import Foundation
import Darwin

/// Reads the session logs each agent already writes on this Mac. Read-only; never touches
/// the network, the Keychain or the agents' own files. Incremental: remembers how far into
/// each file it has read, so only new lines are parsed.
final class Scanner: @unchecked Sendable {
    private(set) var cache = Cache()
    private let fm = FileManager.default
    let home: URL
    let cacheURL: URL
    let zstdPath: String?
    private(set) var skippedZst = 0
    private(set) var lastScanSeconds = 0.0
    private var lastSave = Date.distantPast
    private var dirty = false

    init() {
        home = URL(fileURLWithPath: NSHomeDirectory())
        let dir = home.appendingPathComponent("Library/Application Support/Tfire", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("cache.json")
        // carry the index over from the app's first name (漏刻 / Loukei) so it isn't rebuilt
        let old = home.appendingPathComponent("Library/Application Support/Loukei/cache.json")
        if !fm.fileExists(atPath: cacheURL.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: cacheURL)
        }
        if let d = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode(Cache.self, from: d),
           c.version == Cache.currentVersion {
            cache = c
        }
        zstdPath = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: files

    struct Candidate { let agent: Agent; let path: String; let key: String; let zst: Bool }

    private let skipDirs: Set<String> = [
        "vm_bundles", "Cache", "Code Cache", "GPUCache", "IndexedDB", "Local Storage",
        "Session Storage", "blob_storage", "Crashpad", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker", "WebStorage", "Partitions", "sentry", "node_modules", ".git", "tool-results",
    ]

    private func walk(_ root: URL, _ visit: (URL) -> Void) {
        guard fm.fileExists(atPath: root.path),
              let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                                     errorHandler: { _, _ in true }) else { return }
        for case let url as URL in en {
            let name = url.lastPathComponent
            if skipDirs.contains(name) { en.skipDescendants(); continue }
            if name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") { visit(url) }
        }
    }

    func candidates() -> [Candidate] {
        var out: [Candidate] = []
        // Claude Code (CLI and the desktop app's local Code sessions)
        for r in [".claude/projects", ".config/claude/projects", "Library/Application Support/Claude"] {
            walk(home.appendingPathComponent(r)) { url in
                let p = url.path
                guard p.hasSuffix(".jsonl") else { return }
                if r.hasPrefix("Library"), !p.contains("/projects/") { return }
                out.append(Candidate(agent: .claude, path: p, key: p, zst: false))
            }
        }
        // Codex (desktop app + CLI). Finished sessions get moved to archived_sessions as .zst,
        // so the key is the bare file name: a session is counted once wherever it lives.
        for r in [".codex/sessions", ".codex/archived_sessions"] {
            walk(home.appendingPathComponent(r)) { url in
                let name = url.lastPathComponent
                if name.hasSuffix(".jsonl") {
                    out.append(Candidate(agent: .codex, path: url.path, key: "codex:" + name, zst: false))
                } else if name.hasSuffix(".jsonl.zst") {
                    out.append(Candidate(agent: .codex, path: url.path, key: "codex:" + String(name.dropLast(4)), zst: true))
                }
            }
        }
        // WorkBuddy: ~/.workbuddy/projects/<project>/<session>.jsonl
        let wb = home.appendingPathComponent(".workbuddy/projects").path
        for d in (try? fm.contentsOfDirectory(atPath: wb)) ?? [] {
            let sub = wb + "/" + d
            for f in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] where f.hasSuffix(".jsonl") {
                let p = sub + "/" + f
                out.append(Candidate(agent: .workbuddy, path: p, key: p, zst: false))
            }
        }
        return out
    }

    // MARK: scan

    @discardableResult
    func scan(forceSave: Bool = false) -> Bool {
        let start = Date()
        var changed = false
        var byKey: [String: Candidate] = [:]
        for c in candidates() {
            if let e = byKey[c.key], !e.zst { continue }   // prefer the live .jsonl
            byKey[c.key] = c
        }
        var skipped = 0
        for c in byKey.values {
            guard let attrs = try? fm.attributesOfItem(atPath: c.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

            if var st = cache.files[c.key] {
                if st.path == c.path && st.size == size && st.mtime == mtime { continue }
                if c.zst && st.path != c.path && !st.fromZst {
                    // Session was archived after we had already read it live: same data.
                    st.path = c.path; st.size = size; st.mtime = mtime; st.fromZst = true
                    cache.files[c.key] = st; changed = true
                    continue
                }
                if !c.zst && st.path == c.path && size >= st.offset {
                    readTail(&st)
                    st.size = size; st.mtime = mtime
                    cache.files[c.key] = st; changed = true
                    continue
                }
            }
            var st = FileState(agent: c.agent, path: c.path, size: size, mtime: mtime, offset: 0,
                               recs: [], fromZst: c.zst, codexModel: nil, codexPrevTotal: nil, limits: nil)
            if c.zst {
                guard let z = zstdPath, let data = decompress(z, c.path) else { skipped += 1; continue }
                st.offset = Int64(parse(&st, data))
            } else {
                readTail(&st)
            }
            cache.files[c.key] = st
            changed = true
        }
        skippedZst = skipped
        if changed { dirty = true }
        if dirty && (forceSave || Date().timeIntervalSince(lastSave) > 300) { save() }
        lastScanSeconds = Date().timeIntervalSince(start)
        return changed
    }

    func save() {
        guard let d = try? JSONEncoder().encode(cache) else { return }
        try? d.write(to: cacheURL, options: .atomic)
        lastSave = Date(); dirty = false
    }

    private func readTail(_ st: inout FileState) {
        guard let fh = FileHandle(forReadingAtPath: st.path) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(st.offset)) } catch { return }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }
        st.offset += Int64(parse(&st, data))
    }

    private func decompress(_ zstd: String, _ path: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zstd)
        p.arguments = ["-dc", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    // MARK: parsing

    private static let needles: [Agent: [[UInt8]]] = [
        .claude: [Array("\"usage\"".utf8)],
        .codex: [Array("token_count".utf8), Array("turn_context".utf8)],
        .workbuddy: [Array("\"usage\"".utf8)],
    ]

    /// Parses complete lines; returns the number of bytes consumed (up to the last newline).
    private func parse(_ st: inout FileState, _ data: Data) -> Int {
        let needles = Scanner.needles[st.agent] ?? []
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            guard let base = buf.baseAddress else { return 0 }
            let n = buf.count
            var p = 0
            while p < n {
                let start = base.advanced(by: p)
                guard let nlPtr = memchr(start, 0x0A, n - p) else { break }
                let len = start.distance(to: UnsafeRawPointer(nlPtr))
                if len > 0 {
                    var hit = false
                    for nd in needles {
                        let found: Bool = nd.withUnsafeBytes { nb -> Bool in
                            memmem(start, len, nb.baseAddress, nb.count) != nil
                        }
                        if found { hit = true; break }
                    }
                    if hit,
                       let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: start, count: len))) as? [String: Any] {
                        handle(&st, obj)
                    }
                }
                p += len + 1
            }
            return p
        }
    }

    private func int(_ a: Any?) -> Int { (a as? NSNumber)?.intValue ?? 0 }

    private func handle(_ st: inout FileState, _ o: [String: Any]) {
        switch st.agent {
        case .claude:
            guard (o["type"] as? String) == "assistant",
                  let msg = o["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { return }
            let model = msg["model"] as? String ?? "?"
            if model == "<synthetic>" { return }
            let r = Rec(t: parseISO(o["timestamp"] as? String) ?? st.mtime, m: model,
                        i: int(u["input_tokens"]), cr: int(u["cache_read_input_tokens"]),
                        cw: int(u["cache_creation_input_tokens"]), o: int(u["output_tokens"]),
                        id: (msg["id"] as? String).map { $0 + ":" + ((o["requestId"] as? String) ?? "") })
            if r.total > 0 { st.recs.append(r) }

        case .codex:
            guard let p = o["payload"] as? [String: Any] else { return }
            if (o["type"] as? String) == "turn_context" {
                if let m = p["model"] as? String { st.codexModel = m }
                return
            }
            guard (p["type"] as? String) == "token_count" else { return }
            let ts = parseISO(o["timestamp"] as? String) ?? st.mtime
            if let rl = p["rate_limits"] as? [String: Any] {
                let lid = rl["limit_id"] as? String
                if lid == nil || lid == "codex" {
                    st.limits = CodexLimits(t: ts, primary: window(rl["primary"]), secondary: window(rl["secondary"]),
                                            plan: rl["plan_type"] as? String)
                }
            }
            guard let info = p["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            let totalNow = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if let prev = st.codexPrevTotal, prev == totalNow { return }   // repeated event
            st.codexPrevTotal = totalNow
            let inp = int(last["input_tokens"]), cached = int(last["cached_input_tokens"])
            let r = Rec(t: ts, m: st.codexModel ?? "codex", i: max(0, inp - cached), cr: cached, cw: 0,
                        o: int(last["output_tokens"]), id: nil)
            if r.total > 0 { st.recs.append(r) }

        case .workbuddy:
            guard let pd = o["providerData"] as? [String: Any],
                  let u = pd["usage"] as? [String: Any] else { return }
            let inp = int(u["inputTokens"]), out = int(u["outputTokens"])
            var cached = 0
            if let d = u["inputTokensDetails"] as? [[String: Any]] {
                cached = d.reduce(0) { $0 + int($1["cached_tokens"]) }
            }
            var ts = st.mtime
            if let n = o["timestamp"] as? NSNumber { ts = n.doubleValue / 1000 }
            else if let s = o["timestamp"] as? String, let t = parseISO(s) { ts = t }
            let r = Rec(t: ts, m: pd["model"] as? String ?? "?", i: max(0, inp - cached), cr: cached, cw: 0,
                        o: out, id: (pd["messageId"] as? String).map { "wb:" + $0 })
            if r.total > 0 { st.recs.append(r) }
        }
    }

    private func window(_ a: Any?) -> RateWindow? {
        guard let w = a as? [String: Any] else { return nil }
        return RateWindow(used: (w["used_percent"] as? NSNumber)?.doubleValue ?? 0,
                          windowMin: int(w["window_minutes"]),
                          resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue ?? 0)
    }
}

/// Fast ISO-8601 ("2026-11-15T07:15:06.570Z" or with +08:00) → epoch seconds.
func parseISO(_ s: String?) -> Double? {
    guard let s = s else { return nil }
    let u = Array(s.utf8)
    guard u.count >= 19 else { return nil }
    func d(_ a: Int, _ n: Int) -> Int32 {
        var v: Int32 = 0
        for k in a..<(a + n) {
            let c = u[k]
            if c < 48 || c > 57 { return -1 }
            v = v * 10 + Int32(c - 48)
        }
        return v
    }
    var t = tm()
    t.tm_year = d(0, 4) - 1900; t.tm_mon = d(5, 2) - 1; t.tm_mday = d(8, 2)
    t.tm_hour = d(11, 2); t.tm_min = d(14, 2); t.tm_sec = d(17, 2)
    if t.tm_year < 0 || t.tm_mon < 0 || t.tm_mday < 0 { return nil }
    var secs = Double(timegm(&t))
    var k = 19
    if k < u.count && u[k] == 46 {
        var scale = 0.1
        k += 1
        while k < u.count, u[k] >= 48, u[k] <= 57 { secs += Double(u[k] - 48) * scale; scale /= 10; k += 1 }
    }
    // "+08:00" / "-05:00" needs u[k]...u[k+5]
    if k + 6 <= u.count, u[k] == 43 || u[k] == 45 {
        let h = d(k + 1, 2), m = d(k + 4, 2)
        if h >= 0 && m >= 0 {
            let off = Double(h) * 3600 + Double(m) * 60
            secs += (u[k] == 43 ? -off : off)
        }
    }
    return secs
}
