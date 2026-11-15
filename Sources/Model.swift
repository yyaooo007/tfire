import Foundation

enum Agent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, workbuddy
    var id: Self { self }
    var idx: Int {
        switch self { case .claude: return 0; case .codex: return 1; case .workbuddy: return 2 }
    }
    var title: String {
        switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .workbuddy: return "WorkBuddy" }
    }
    var short: String {
        switch self { case .claude: return "Cl"; case .codex: return "Cx"; case .workbuddy: return "WB" }
    }
}

/// One model call. i = fresh input, cr = cache read, cw = cache write, o = output (incl. reasoning).
struct Rec: Codable, Sendable {
    var t: Double
    var m: String
    var i: Int
    var cr: Int
    var cw: Int
    var o: Int
    var id: String?
    var total: Int { i + cr + cw + o }
}

struct RateWindow: Codable, Sendable {
    var used: Double
    var windowMin: Int
    var resetsAt: Double
}

struct CodexLimits: Codable, Sendable {
    var t: Double
    var primary: RateWindow?
    var secondary: RateWindow?
    var plan: String?
}

struct FileState: Codable, Sendable {
    var agent: Agent
    var path: String
    var size: Int64
    var mtime: Double
    var offset: Int64
    var recs: [Rec]
    var fromZst: Bool
    var codexModel: String?
    var codexPrevTotal: Int?
    var limits: CodexLimits?
}

struct Cache: Codable, Sendable {
    static let currentVersion = 1
    var version = Cache.currentVersion
    var files: [String: FileState] = [:]
}

// MARK: - Aggregation

struct Breakdown: Sendable {
    var i = 0, cr = 0, cw = 0, o = 0
    var total: Int { i + cr + cw + o }
    mutating func add(_ r: Rec) { i += r.i; cr += r.cr; cw += r.cw; o += r.o }
    mutating func add(_ b: Breakdown) { i += b.i; cr += b.cr; cw += b.cw; o += b.o }
}

struct AgentStat: Sendable {
    var periods = [Breakdown](repeating: Breakdown(), count: 4)   // 今日 / 7日 / 30日 / 累计
    var models = [[String: Int]](repeating: [:], count: 4)
    var daily = [Int](repeating: 0, count: 30)                     // index 29 = today
    var files = 0
}

struct Snapshot: Sendable {
    var stats = [AgentStat](repeating: AgentStat(), count: Agent.allCases.count)
    var limits: CodexLimits?
    var updated = Date()
    var skippedZst = 0
    var dailyMax = 0          // biggest single agent-day in 30 days (shared bar scale)
    var dailyTotalMax = 0     // biggest all-agent day in 30 days (menu-bar water level)
    var scanSeconds = 0.0

    func total(_ p: Int) -> Breakdown {
        var b = Breakdown()
        for s in stats { b.add(s.periods[p]) }
        return b
    }
    var isEmpty: Bool { total(3).total == 0 }
}

func aggregate(_ cache: Cache, now: Date = Date()) -> Snapshot {
    let todayStart = Calendar.current.startOfDay(for: now).timeIntervalSince1970
    var snap = Snapshot()
    var deduped: [String: (Int, Rec)] = [:]

    func add(_ a: Int, _ r: Rec) {
        let dayAgo = r.t >= todayStart ? 0 : Int((todayStart - r.t) / 86400) + 1
        let v = r.total
        snap.stats[a].periods[3].add(r)
        snap.stats[a].models[3][r.m, default: 0] += v
        if dayAgo < 30 {
            snap.stats[a].daily[29 - dayAgo] += v
            snap.stats[a].periods[2].add(r)
            snap.stats[a].models[2][r.m, default: 0] += v
        }
        if dayAgo < 7 {
            snap.stats[a].periods[1].add(r)
            snap.stats[a].models[1][r.m, default: 0] += v
        }
        if dayAgo == 0 {
            snap.stats[a].periods[0].add(r)
            snap.stats[a].models[0][r.m, default: 0] += v
        }
    }

    for st in cache.files.values {
        let a = st.agent.idx
        snap.stats[a].files += 1
        for r in st.recs {
            if let id = r.id {
                // Claude Code writes the same API message on several lines (and again in resumed
                // sessions); keep one copy, the one with the most tokens.
                if let e = deduped[id], e.1.total >= r.total { continue }
                deduped[id] = (a, r)
            } else {
                add(a, r)
            }
        }
        if let l = st.limits, l.t > (snap.limits?.t ?? 0) { snap.limits = l }
    }
    for (a, r) in deduped.values { add(a, r) }

    var dayTotals = [Int](repeating: 0, count: 30)
    for s in snap.stats {
        for d in 0..<30 {
            snap.dailyMax = max(snap.dailyMax, s.daily[d])
            dayTotals[d] += s.daily[d]
        }
    }
    snap.dailyTotalMax = dayTotals.max() ?? 0
    snap.updated = now
    return snap
}

// MARK: - Formatting (万 / 亿)

func cnParts(_ n: Int) -> (String, String) {
    let d = Double(n)
    if n >= 100_000_000 { return (String(format: "%.2f", d / 1e8), "亿") }
    if n >= 10_000 {
        let v = d / 1e4
        return (v >= 1000 ? String(format: "%.0f", v) : String(format: "%.1f", v), "万")
    }
    return ("\(n)", "")
}

func cn(_ n: Int) -> String { let p = cnParts(n); return p.0 + p.1 }
