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

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

struct PanelView: View {
    @ObservedObject var store: Store
    // Command Line Tools ship without the SwiftUI macro plugins, so no @State here:
    // view state lives in Store (@Published).
    private var period: Int { store.period }

    private let periodNames = ["今日", "7 日", "30 日", "累计"]
    private var span: Int { [1, 7, 30, 30][period] }

    var body: some View {
        let snap = store.snap
        let total = snap.total(period)
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs.padding(.top, 20)
            hero(total).padding(.top, 14).padding(.bottom, 18)
            Hairline()
            ForEach(Agent.allCases) { a in
                row(a, snap, periodTotal: total.total)
                Hairline()
            }
            if let l = snap.limits {
                quota(l)
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
            ForEach(0..<4, id: \.self) { i in
                Button { store.period = i } label: {
                    VStack(spacing: 5) {
                        Text(periodNames[i])
                            .font(.system(size: 11, weight: period == i ? .semibold : .regular))
                            .foregroundStyle(period == i ? Color.primary : Color.secondary)
                        Rectangle().fill(period == i ? Color.primary : Color.clear).frame(height: 1)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                Text(store.indexing ? "第一次打开，正在读取本地日志…" : "这段时间没有记录")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ a: Agent, _ snap: Snapshot, periodTotal: Int) -> some View {
        let st = snap.stats[a.idx]
        let v = st.periods[period].total
        let share = periodTotal > 0 ? Double(v) / Double(periodTotal) : 0
        let open = store.expanded == a
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
                    if st.periods[3].total == 0 {
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
                DayStrip(values: st.daily, scale: snap.dailyMax, span: span)
            }

            if open {
                let models = st.models[period].sorted { $0.value > $1.value }.prefix(6)
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
    }

    private func quota(_ l: CodexLimits) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Codex 额度").font(.system(size: 11, weight: .medium))
                if let p = l.plan { Text(p.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary) }
                Spacer()
                Text("记录于 " + fmt("M/d HH:mm", Date(timeIntervalSince1970: l.t)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let w = l.primary { Meter(w: w) }
            if let w = l.secondary { Meter(w: w) }
        }
        .padding(.vertical, 13)
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
struct DayStrip: View {
    let values: [Int]
    let scale: Int
    let span: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<values.count, id: \.self) { i in
                let v = values[i]
                let isToday = i == values.count - 1
                let inSpan = i >= values.count - span
                let h: CGFloat = v == 0 ? 1 : max(1.5, 22 * CGFloat(v) / CGFloat(max(scale, 1)))
                Rectangle()
                    .fill(isToday ? Color.cinnabar : Color.primary.opacity(v == 0 ? 0.10 : (inSpan ? 0.55 : 0.18)))
                    .frame(maxWidth: .infinity)
                    .frame(height: h)
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

struct Meter: View {
    let w: RateWindow

    private var label: String {
        switch w.windowMin {
        case 300: return "5 小时"
        case 10080: return "本周"
        case let m where m % 1440 == 0: return "\(m / 1440) 天"
        case let m where m % 60 == 0: return "\(m / 60) 小时"
        default: return "\(w.windowMin) 分"
        }
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        let expired = w.resetsAt > 0 && now > w.resetsAt
        let used = expired ? 0 : w.used
        let reset = Date(timeIntervalSince1970: w.resetsAt)
        let resetText = expired ? "已重置"
            : (w.resetsAt - now < 86400 ? fmt("HH:mm", reset) : fmt("EEE HH:mm", reset)) + " 重置"
        return HStack(spacing: 10) {
            Text(label).font(.system(size: 11)).frame(width: 40, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.10))
                    Rectangle().fill(used >= 80 ? Color.cinnabar : Color.primary.opacity(0.65))
                        .frame(width: g.size.width * CGFloat(min(1, used / 100)))
                }
            }
            .frame(height: 2)
            Text("\(Int(used.rounded()))%")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(used >= 80 ? Color.cinnabar : Color.primary)
                .frame(width: 36, alignment: .trailing)
            Text(resetText).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 78, alignment: .trailing)
        }
    }
}
