import SwiftUI
import AppKit
import ServiceManagement

extension Color {
    /// 朱砂 — the only colour in the panel. Used for "today" and for limits running out.
    static let cinnabar = Color(red: 0.78, green: 0.20, blue: 0.14)
}

private let zh = Locale(identifier: "zh_CN")

private func fmt(_ pattern: String, _ d: Date) -> String {
    let f = DateFormatter()
    f.locale = zh
    f.dateFormat = pattern
    return f.string(from: d)
}

/// Soft highlight behind the panel row under the pointer. Extends a little past the
/// content edges so the text keeps its alignment.
struct HoverRow: ViewModifier {
    @ObservedObject var store: Store
    let id: String
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(store.hovered == id ? 0.07 : 0))
                    .padding(.horizontal, -12)
                    .padding(.vertical, 2)
            )
            .onHover { inside in
                if inside { store.hovered = id } else if store.hovered == id { store.hovered = nil }
            }
            .animation(.easeOut(duration: 0.12), value: store.hovered == id)
    }
}

extension View {
    func hoverRow(_ store: Store, _ id: String) -> some View { modifier(HoverRow(store: store, id: id)) }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

struct PanelView: View {
    @ObservedObject var store: Store
    // Command Line Tools ship without the SwiftUI macro plugins, so no @State here:
    // view state lives in Store (@Published).
    private var period: Int { store.period }

    private let periodNames = ["今日", "7 日", "30 日", "累计", "按日"]
    /// 按日: one chosen day, any day since the first record.
    private var dayMode: Bool { period == 4 }
    private var selKey: Int { store.selectedDay ?? store.snap.todayKey }
    private var span: Int { dayMode ? 0 : [1, 7, 30, 30][period] }

    private func bd(_ s: Snapshot, _ a: Agent) -> Breakdown {
        dayMode ? (s.days[selKey]?.stats[a.idx] ?? Breakdown()) : s.stats[a.idx].periods[period]
    }
    private func modelsOf(_ s: Snapshot, _ a: Agent) -> [String: Int] {
        dayMode ? (s.days[selKey]?.models[a.idx] ?? [:]) : s.stats[a.idx].models[period]
    }
    private func totalOf(_ s: Snapshot) -> Breakdown {
        var b = Breakdown()
        for a in Agent.allCases { b.add(bd(s, a)) }
        return b
    }
    private func dayTitle(_ k: Int, _ today: Int) -> String {
        let rel = k == today ? " · 今天" : (k == today - 1 ? " · 昨天" : "")
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: dayDate(k)) == cal.component(.year, from: dayDate(today))
        return fmt(sameYear ? "M月d日 EEE" : "yyyy年M月d日 EEE", dayDate(k)) + rel
    }

    var body: some View {
        let snap = store.snap
        let total = totalOf(snap)
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs.padding(.top, 20)
            if dayMode { dayNav(snap).padding(.top, 12) }
            hero(total).padding(.top, 14).padding(.bottom, 18)
            Hairline()
            ForEach(Agent.allCases) { a in
                row(a, snap, periodTotal: total.total)
                Hairline()
            }
            if snap.limits != nil || !snap.wbQuotas.isEmpty || snap.gemini.overQuotaModes != nil {
                quota(snap)
                Hairline()
            }
            if snap.skippedZst > 0 {
                Text("Codex 有 \(snap.skippedZst) 个已归档会话未计入：需要 zstd 解压")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
            footer.padding(.top, 10)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 348)
    }

    // MARK: parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tfire").font(.system(size: 13, weight: .semibold)).tracking(1)
            Text("本机 token").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Text(fmt("M月d日 EEE", Date())).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(0..<5, id: \.self) { i in
                Button { store.period = i; if i == 4 { store.selectedDay = nil } } label: {
                    VStack(spacing: 5) {
                        Text(periodNames[i])
                            .font(.system(size: 11, weight: period == i ? .semibold : .regular))
                            .foregroundStyle(period == i || store.hovered == "tab-\(i)" ? Color.primary : Color.secondary)
                        Rectangle().fill(period == i ? Color.primary : Color.clear).frame(height: 1)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { store.hovered = "tab-\(i)" } else if store.hovered == "tab-\(i)" { store.hovered = nil }
                }
            }
            Spacer()
        }
    }

    private func hero(_ b: Breakdown) -> some View {
        let (num, unit) = cnParts(b.total)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(store.indexing && store.snap.isEmpty ? "—" : num)
                    .font(.system(size: 44, weight: .ultraLight))
                    .monospacedDigit()
                Text(unit).font(.system(size: 15, weight: .light)).foregroundStyle(.secondary)
                Spacer()
            }
            if b.total > 0 {
                let cachePct = Int((Double(b.cr) / Double(b.total) * 100).rounded())
                Text("新输入 \(cn(b.i + b.cw))   缓存读取 \(cn(b.cr))（\(cachePct)%）   输出 \(cn(b.o))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(store.indexing ? "第一次打开，正在读取本地日志…" : (dayMode ? "这一天没有 token 记录" : "这段时间没有记录"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    /// ‹ 11月26日 周四 · 昨天 ›   — steps one day at a time, from the first record to today.
    private func dayNav(_ s: Snapshot) -> some View {
        let k = selKey
        let canPrev = k > (s.firstDay ?? k)
        let canNext = k < s.todayKey
        return HStack(spacing: 12) {
            Button { store.selectedDay = k - 1 } label: {
                Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(!canPrev).opacity(canPrev ? 1 : 0.25)
            Text(dayTitle(k, s.todayKey))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color.primary)
            Button { store.selectedDay = k + 1 == s.todayKey ? nil : k + 1 } label: {
                Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(!canNext).opacity(canNext ? 1 : 0.25)
            Spacer()
            if k != s.todayKey {
                Button("回到今天") { store.selectedDay = nil }
                    .font(.system(size: 10.5))
            } else if let f = s.firstDay {
                Text("最早 " + fmt("yyyy/M/d", dayDate(f))).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    /// Index in a 30-day strip → day key (index 29 is today).
    private func stripKey(_ i: Int, _ s: Snapshot) -> Int { s.todayKey - 29 + i }

    private func strip(_ a: Agent, _ values: [Int], scale: Int, _ s: Snapshot) -> some View {
        let sel = dayMode ? selKey - (s.todayKey - 29) : nil
        let hov = store.scrub?.agent == a ? store.scrub.map { $0.day - (s.todayKey - 29) } : nil
        return DayStrip(values: values, scale: scale, span: span, selected: sel, hover: hov,
                        onHover: { i in
                            if let i = i { store.scrub = (a, stripKey(i, s)) }
                            else if store.scrub?.agent == a { store.scrub = nil }
                        },
                        onTap: { i in
                            store.period = 4
                            let k = stripKey(i, s)
                            store.selectedDay = k == s.todayKey ? nil : k
                        })
    }

    private func row(_ a: Agent, _ snap: Snapshot, periodTotal: Int) -> some View {
        let st = snap.stats[a.idx]
        let v = bd(snap, a).total
        let scrubDay = store.scrub?.agent == a ? store.scrub?.day : nil
        let share = periodTotal > 0 ? Double(v) / Double(periodTotal) : 0
        let open = store.expanded == a
        // Gemini desktop app: no local token data, show real message / chat counts instead.
        let gApp = a == .gemini && st.periods[3].total == 0 && snap.gemini.found
        let g = snap.gemini
        return VStack(alignment: .leading, spacing: 9) {
            Button {
                store.expanded = open ? nil : a
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(a.title).font(.system(size: 13))
                    if v > 0 {
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    Spacer()
                    if let k = scrubDay {
                        // the day under the pointer
                        let d = snap.days[k]
                        Text(fmt("M/d EEE", dayDate(k)) + "  " + (gApp
                            ? "\(d?.gMsgs ?? 0) 条消息"
                            : cn(d?.stats[a.idx].total ?? 0)))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    } else if gApp {
                        let m = dayMode ? (snap.days[selKey]?.gMsgs ?? 0) : g.msgs[period]
                        let c = dayMode ? (snap.days[selKey]?.gChats ?? 0) : g.chats[period]
                        Text("\(m) 条消息 · \(c) 个对话")
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .foregroundStyle(m > 0 ? Color.primary : Color.secondary)
                    } else if st.periods[3].total == 0 {
                        Text(a == .claude ? "本机没有记录 · 云端会话不落本地" : "本机没有记录")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        Text(v > 0 ? cn(v) : "0")
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .foregroundStyle(v > 0 ? Color.primary : Color.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if st.periods[3].total > 0 {
                strip(a, st.daily, scale: snap.dailyMax, snap)
            } else if gApp {
                // messages, on their own scale (not comparable with tokens)
                strip(a, g.daily, scale: g.daily.max() ?? 1, snap)
                Text("桌面 App 的 token 记在 Google 服务器上，本机只有消息和对话数")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }

            if open {
                let models = modelsOf(snap, a).sorted { $0.value > $1.value }.prefix(6)
                VStack(alignment: .leading, spacing: 4) {
                    if models.isEmpty {
                        Text("这段时间没有调用").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(models), id: \.key) { m in
                        HStack {
                            Text(m.key).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(cn(m.value)).font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 13)
        .hoverRow(store, "row-\(a.rawValue)")
    }

    private func quota(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("订阅额度").font(.system(size: 11, weight: .medium))
                Text("≥90% 时火焰闪红").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                if let l = snap.limits {
                    Text("Codex 记录于 " + fmt("M/d HH:mm", Date(timeIntervalSince1970: l.t)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if let l = snap.limits {
                let plan = l.plan.map { " " + $0.uppercased() } ?? ""
                if let w = l.primary { Meter(label: "Codex\(plan) · " + Meter.window(w.windowMin), used: w.used, resetsAt: w.resetsAt) }
                if let w = l.secondary { Meter(label: "Codex\(plan) · " + Meter.window(w.windowMin), used: w.used, resetsAt: w.resetsAt) }
            }
            ForEach(snap.wbQuotas.prefix(4), id: \.name) { n in
                Meter(label: "WorkBuddy · " + n.name, used: n.q.percent, resetsAt: n.q.resetAt)
            }
            if let n = snap.gemini.overQuotaModes {
                HStack(alignment: .firstTextBaseline) {
                    Text("Gemini 桌面 App").font(.system(size: 11))
                    Spacer()
                    Text(n > 0 ? "\(n) 个模式已超额" : "未超额")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(n > 0 ? Color.cinnabar : Color.primary)
                    Text("记录于 " + fmt("M/d HH:mm", Date(timeIntervalSince1970: snap.gemini.quotaT)))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 78 + 22, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 13)
        .hoverRow(store, "row-quota")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(store.indexing ? "正在索引…" : "更新于 " + fmt("HH:mm", store.snap.updated))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Button("刷新") { store.refresh() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            Menu {
                Picker("菜单栏显示", selection: $store.barStyle) {
                    Text("今日总量").tag(0)
                    Text("按 agent 分开").tag(1)
                }
                Toggle("登录时启动", isOn: Binding(get: { store.loginOn }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {}
                    store.loginOn = SMAppService.mainApp.status == .enabled
                }))
                Divider()
                Button("退出 Tfire") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// 30 hairline bars, one per day, all agents on one shared scale so heights compare honestly.
/// Hover a bar to read that day; click it to open the day in 按日.
struct DayStrip: View {
    let values: [Int]
    let scale: Int
    let span: Int
    var selected: Int? = nil
    var hover: Int? = nil
    var onHover: (Int?) -> Void = { _ in }
    var onTap: (Int) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<values.count, id: \.self) { i in
                let v = values[i]
                let isToday = i == values.count - 1
                let inSpan = i >= values.count - span
                let isSel = selected == i
                let h: CGFloat = v == 0 ? 1 : max(1.5, 22 * CGFloat(v) / CGFloat(max(scale, 1)))
                let base: Color = isToday ? .cinnabar
                    : Color.primary.opacity(v == 0 ? 0.10 : (isSel ? 0.9 : (inSpan ? 0.55 : 0.18)))
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(base)
                        .overlay(Rectangle().fill(Color.primary.opacity(hover == i && !isToday ? 0.35 : 0)))
                        .frame(height: h)
                    // a hairline under the chosen day
                    Rectangle().fill(isSel ? Color.primary : Color.clear).frame(height: 1).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in onHover(inside ? i : nil) }
                .onTapGesture { onTap(i) }
            }
        }
        .frame(height: 25, alignment: .bottom)
    }
}

struct Meter: View {
    let label: String
    let used: Double
    let resetsAt: Double

    static func window(_ minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时"
        case 10080: return "本周"
        case let m where m % 1440 == 0: return "\(m / 1440) 天"
        case let m where m % 60 == 0: return "\(m / 60) 小时"
        default: return "\(minutes) 分"
        }
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        let expired = resetsAt > 0 && now > resetsAt
        let u = expired ? 0 : used
        let reset = Date(timeIntervalSince1970: resetsAt)
        let cal = Calendar.current
        let day = cal.isDateInToday(reset) ? "" : (cal.isDateInTomorrow(reset) ? "明天 " : fmt("EEE ", reset))
        let resetText = expired ? "已重置" : day + fmt("HH:mm", reset) + " 重置"
        let hot = u >= 90 ? Color.cinnabar : (u >= 80 ? Color.cinnabar.opacity(0.75) : Color.primary.opacity(0.65))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 11)).lineLimit(1)
                Spacer()
                Text("\(Int(u.rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(u >= 80 ? Color.cinnabar : Color.primary)
                Text(resetText).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 78, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.10))
                    Rectangle().fill(hot).frame(width: g.size.width * CGFloat(min(1, u / 100)))
                }
            }
            .frame(height: 2)
        }
    }
}
