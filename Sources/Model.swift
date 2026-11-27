import Foundation

enum Agent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, workbuddy, gemini
    var id: Self { self }
    var idx: Int {
        switch self { case .claude: return 0; case .codex: return 1; case .workbuddy: return 2; case .gemini: return 3 }
    }
    var title: String {
        switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .workbuddy: return "WorkBuddy"; case .gemini: return "Gemini" }
    }
    var short: String {
        switch self { case .claude: return "Cl"; case .codex: return "Cx"; case .workbuddy: return "WB"; case .gemini: return "Gm" }
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

/// A subscription quota as WorkBuddy reports it per model: percent used, resets at.
struct ModelQuota: Codable, Sendable {
    var t: Double
    var percent: Double
    var resetAt: Double
}

struct NamedQuota: Sendable {
    var name: String
    var q: ModelQuota
}

/// One message in the Gemini desktop app. The app keeps message bodies encrypted and its
/// token usage on Google's servers, so only counts and times are available locally.
struct GMsg: Sendable {
    var t: Double
    var user: Bool
    var chat: String
}

/// Gemini desktop app activity: messages and chats per period, and the app's own
/// over-quota flag from its log.
struct GeminiActivity: Sendable {
    var found = false
    var msgs = [Int](repeating: 0, count: 4)
    var chats = [Int](repeating: 0, count: 4)
    var daily = [Int](repeating: 0, count: 30)
    var overQuotaModes: Int?
    var quotaT: Double = 0
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
    var quotas: [String: ModelQuota]?
}

struct Cache: Codable, Sendable {
    static let currentVersion = 2
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

/// Everything about one calendar day (local time), for the 按日 view.
struct DayStat: Sendable {
    var stats = [Breakdown](repeating: Breakdown(), count: Agent.allCases.count)
    var models = [[String: Int]](repeating: [:], count: Agent.allCases.count)
    var gMsgs = 0
    var gChats = 0
    var total: Int { stats.reduce(0) { $0 + $1.total } }
}

/// Local-day index: days since 1970-01-01 in the Mac's current time zone.
func dayKey(_ t: Double, offset: Double = Double(TimeZone.current.secondsFromGMT())) -> Int {
    Int(((t + offset) / 86400).rounded(.down))
}

/// Start of a local day, back as a Date.
func dayDate(_ key: Int) -> Date {
    Date(timeIntervalSince1970: Double(key) * 86400 - Double(TimeZone.current.secondsFromGMT()))
}

struct Snapshot: Sendable {
    var stats = [AgentStat](repeating: AgentStat(), count: Agent.allCases.count)
    var limits: CodexLimits?
    var updated = Date()
    var skippedZst = 0
    var dailyMax = 0          // biggest single agent-day in 30 days (shared bar scale)
    var dailyTotalMax = 0     // biggest all-agent day in 30 days (menu-bar water level)
    var scanSeconds = 0.0
    var wbQuotas: [NamedQuota] = []   // WorkBuddy per-model quotas still inside their window
    var gemini = GeminiActivity()
    var days: [Int: DayStat] = [:]    // every day that has any record
    var todayKey = 0
    var firstDay: Int?                // earliest day with a record

    func total(_ p: Int) -> Breakdown {
        var b = Breakdown()
        for s in stats { b.add(s.periods[p]) }
        return b
    }
    var isEmpty: Bool { total(3).total == 0 }
}

func aggregate(_ cache: Cache, gemini: [GMsg]? = nil, geminiQuota: (Int, Double)? = nil,
               now: Date = Date()) -> Snapshot {
    let todayStart = Calendar.current.startOfDay(for: now).timeIntervalSince1970
    var snap = Snapshot()
    let off = Double(TimeZone.current.secondsFromGMT())
    snap.todayKey = dayKey(now.timeIntervalSince1970, offset: off)
    var deduped: [String: (Int, Rec)] = [:]
    var wbLatest: [String: ModelQuota] = [:]

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
        let k = dayKey(r.t, offset: off)
        snap.days[k, default: DayStat()].stats[a].add(r)
        snap.days[k, default: DayStat()].models[a][r.m, default: 0] += v
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
        for (m, q) in st.quotas ?? [:] where q.t > (wbLatest[m]?.t ?? 0) { wbLatest[m] = q }
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
    snap.firstDay = snap.days.keys.min()
    let nowT = now.timeIntervalSince1970
    snap.wbQuotas = wbLatest.filter { $0.value.resetAt > nowT }
        .map { NamedQuota(name: $0.key, q: $0.value) }
        .sorted { $0.q.percent > $1.q.percent }

    if let msgs = gemini {
        var g = GeminiActivity()
        g.found = true
        var chatSets = [Set<String>](repeating: [], count: 4)
        var dayChats: [Int: Set<String>] = [:]
        for m in msgs {
            let k = dayKey(m.t, offset: off)
            snap.days[k, default: DayStat()].gMsgs += 1
            dayChats[k, default: []].insert(m.chat)
            let dayAgo = m.t >= todayStart ? 0 : Int((todayStart - m.t) / 86400) + 1
            let periods = [dayAgo == 0, dayAgo < 7, dayAgo < 30, true]
            for p in 0..<4 where periods[p] {
                g.msgs[p] += 1
                chatSets[p].insert(m.chat)
            }
            if dayAgo < 30 { g.daily[29 - dayAgo] += 1 }
        }
        g.chats = chatSets.map(\.count)
        for (k, set) in dayChats { snap.days[k, default: DayStat()].gChats = set.count }
        if let q = geminiQuota { g.overQuotaModes = q.0; g.quotaT = q.1 }
        snap.gemini = g
    }
    snap.updated = now
    return snap
}

// MARK: - Subscription alerts

/// Every quota window that is at or above `threshold` percent right now, as a stable key
/// (agent + window + reset time), so each crossing alerts once.
func quotaAlerts(_ s: Snapshot, threshold: Double = 90, now: Date = Date()) -> [String] {
    let t = now.timeIntervalSince1970
    var keys: [String] = []
    if let l = s.limits {
        for w in [l.primary, l.secondary].compactMap({ $0 }) where w.resetsAt > t && w.used >= threshold {
            // Codex nudges resets_at by a second or two between events; bucket to the hour.
            keys.append("codex-\(w.windowMin)-\(Int(w.resetsAt / 3600))")
        }
    }
    for n in s.wbQuotas where n.q.percent >= threshold {
        keys.append("wb-\(n.name)-\(Int(n.q.resetAt / 3600))")
    }
    // The Gemini app only says "over quota" or not; once per day at most.
    if let n = s.gemini.overQuotaModes, n > 0, t - s.gemini.quotaT < 6 * 3600 {
        keys.append("gemini-over-\(Int(s.gemini.quotaT / 86400))")
    }
    return keys
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
