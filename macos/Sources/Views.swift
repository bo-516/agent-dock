// The dropdown: a top bar with the source switches and the time range, then
// one column per shown source (Claude, Antigravity), then the app's own rows.

import ServiceManagement
import SwiftUI

let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
let unreadBlue = Color(red: 0.231, green: 0.510, blue: 0.965)
let barBlue = Color(red: 0.239, green: 0.459, blue: 0.851)
let shownPerProject = 5
let columnWidth: CGFloat = 340
let edge: CGFloat = 16

struct TimeRange {
    let key: String
    let seconds: TimeInterval?
    let empty: String
}

let timeRanges = [
    TimeRange(key: "6h", seconds: 6 * 3600, empty: "6 小时内没有活动的会话"),
    TimeRange(key: "24h", seconds: 24 * 3600, empty: "24 小时内没有活动的会话"),
    TimeRange(key: "7d", seconds: 7 * 86400, empty: "7 天内没有活动的会话"),
    TimeRange(key: "all", seconds: nil, empty: "没有会话"),
]

// Whether the dropdown is on screen; animations stop while it is not.
final class DropdownState: ObservableObject {
    @Published var isOpen = false
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var model: BoardModel
    @State private var expanded: Set<String> = []
    @AppStorage("range") private var rangeKey = "6h"

    var body: some View {
        let range = timeRanges.first { $0.key == rangeKey } ?? timeRanges[0]

        VStack(alignment: .leading, spacing: 0) {
            TopBar(model: model, rangeKey: $rangeKey)
            Divider().padding(.horizontal, edge)

            HStack(alignment: .top, spacing: 0) {
                if model.showClaude {
                    ClaudeColumn(model: model, range: range, expanded: $expanded)
                }
                if model.showClaude && model.showAntigravity {
                    Divider()
                }
                if model.showAntigravity {
                    AntigravityColumn(model: model, range: range, expanded: $expanded)
                }
                if !model.showClaude && !model.showAntigravity {
                    Text("Claude 和 Antigravity 都隐藏了，点上面的按钮显示")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(edge)
                        .frame(width: columnWidth, alignment: .leading)
                }
            }

            Divider().padding(.horizontal, edge).padding(.top, 8)
            VStack(spacing: 0) {
                LoginItemRow()
                HoverRow(action: { NSApp.terminate(nil) }) {
                    Text("退出 Agent Dock").font(.system(size: 13))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: width)
    }

    // One column per shown source and the line between them; one column's worth with none.
    private var width: CGFloat {
        let columns = (model.showClaude ? 1 : 0) + (model.showAntigravity ? 1 : 0)
        return columns == 2 ? columnWidth * 2 + 1 : columnWidth
    }
}

struct TopBar: View {
    @ObservedObject var model: BoardModel
    @Binding var rangeKey: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent Dock").font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                SourceToggle(name: "Claude", isOn: $model.showClaude)
                SourceToggle(name: "Antigravity", isOn: $model.showAntigravity)
            }
            HStack {
                Text("最近活动")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                RangePicker(selection: $rangeKey)
            }
        }
        .padding(.horizontal, edge)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if model.runningCount > 0 { parts.append("\(model.runningCount) 个运行中") }
        if model.unreadCount > 0 { parts.append("\(model.unreadCount) 个未查看") }
        return parts.isEmpty ? "全部空闲" : parts.joined(separator: " · ")
    }
}

// Shows or hides one source's column; the choice is kept.
struct SourceToggle: View {
    let name: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "eye" : "eye.slash").font(.system(size: 10, weight: .semibold))
                Text(name).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(isOn ? Color.primary.opacity(0.12) : Color.clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.2)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "隐藏 \(name)" : "显示 \(name)")
    }
}

// MARK: - Columns

struct ClaudeColumn: View {
    @ObservedObject var model: BoardModel
    let range: TimeRange
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                title: "Claude",
                note: model.isClaudeStale ? "未连接：没有运行 agent-dock 插件的 Claude 会话" : nil,
                open: { model.openApp(ClaudeFeed.bundleIDs[0]) }
            )
            if !model.usage.isEmpty {
                UsageSection(
                    rows: model.usage.map {
                        UsageRow(id: $0.kind, label: usageLabel($0.kind), percentUsed: $0.percentUsed, resetsAt: $0.resetsAt)
                    },
                    updatedAt: model.usageAt,
                    now: model.now
                )
                Divider().padding(.horizontal, edge)
            }
            SessionList(model: model, sessions: model.visible(model.claude, within: range.seconds),
                        range: range, expanded: $expanded)
        }
        .frame(width: columnWidth)
    }
}

struct AntigravityColumn: View {
    @ObservedObject var model: BoardModel
    let range: TimeRange
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(title: "Antigravity", note: nil, open: { model.openApp(AntigravityFeed.bundleIDs[0]) })
            if !model.antigravityUsage.isEmpty {
                UsageSection(rows: model.antigravityUsage, updatedAt: model.antigravityUsageAt, now: model.now)
                Divider().padding(.horizontal, edge)
            }
            SessionList(model: model, sessions: model.visible(model.antigravity, within: range.seconds),
                        range: range, expanded: $expanded)
        }
        .frame(width: columnWidth)
    }
}

struct ColumnHeader: View {
    let title: String
    let note: String?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: open) { Pill(text: "打开") }.buttonStyle(.plain)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(claudeOrange)
            }
        }
        .padding(.horizontal, edge)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

struct SessionList: View {
    @ObservedObject var model: BoardModel
    let sessions: [Session]
    let range: TimeRange
    @Binding var expanded: Set<String>

    var body: some View {
        FittedScroll(maxHeight: 440) {
            VStack(alignment: .leading, spacing: 0) {
                if sessions.isEmpty {
                    Text(range.empty)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, edge)
                        .padding(.vertical, 12)
                }
                ForEach(model.groups(of: sessions)) { group in
                    ProjectSection(model: model, group: group, expanded: $expanded)
                }
            }
        }
    }
}

// MARK: - Usage

// A source's plan limits: one bar per limit, used share and time to reset.
struct UsageSection: View {
    let rows: [UsageRow]
    // When the figures were read: Claude's at its last API response, Antigravity's when asked.
    let updatedAt: Date?
    let now: Date

    private var readingAge: String {
        guard let updatedAt else { return "" }
        return now.timeIntervalSince(updatedAt) < 300 ? "updated just now" : "updated \(ago(updatedAt, now: now))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "套餐用量", trailing: readingAge)
            ForEach(rows) { row in
                let reset = until(row.resetsAt, now: now)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(reset.map { "\(format(row.percentUsed)) · \($0)" } ?? "已重置")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    UsageBar(fraction: reset == nil ? 0 : row.percentUsed / 100)
                }
                .padding(.horizontal, edge)
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 6)
    }

    private func format(_ percent: Double) -> String {
        percent.rounded() == percent ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(fraction >= 0.9 ? claudeOrange : barBlue)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Sessions

struct ProjectSection: View {
    @ObservedObject var model: BoardModel
    let group: ProjectGroup
    @Binding var expanded: Set<String>

    var body: some View {
        let isOpen = expanded.contains(group.id)
        let shown = isOpen
            ? group.rows
            : group.rows.enumerated().filter { $0.offset < shownPerProject || $0.element.isRunning }.map(\.element)
        let hidden = group.rows.count - shown.count

        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: group.name)
            ForEach(shown) { session in
                SessionRow(session: session, now: model.now) { model.open(session) }
            }
            if hidden > 0 {
                FoldRow(label: "see more ▾") { expanded.insert(group.id) }
            } else if isOpen && group.rows.count > shownPerProject {
                FoldRow(label: "see less ▴") { expanded.remove(group.id) }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date
    let open: () -> Void

    var body: some View {
        HoverRow(action: open) {
            HStack(spacing: 8) {
                Marker(state: session.state)
                Text(session.title)
                    .font(.system(size: 13, weight: session.isRunning ? .semibold : .regular))
                    .foregroundStyle(session.isRunning || session.isUnread ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(ago(session.lastActivity, now: now))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .help(session.title)
    }
}

struct Marker: View {
    let state: RunState

    var body: some View {
        Group {
            switch state {
            case .running: Spinner()
            case .unread: Circle().fill(unreadBlue).frame(width: 7, height: 7)
            case .seen: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            }
        }
        .frame(width: 12, height: 12)
    }
}

struct Spinner: View {
    @EnvironmentObject private var dropdown: DropdownState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !dropdown.isOpen)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
            ZStack {
                Circle().stroke(claudeOrange.opacity(0.25), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(claudeOrange, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
        }
        .frame(width: 10, height: 10)
    }
}

struct FoldRow: View {
    let label: String
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }
}

// MARK: - Building blocks

// A scroll view as tall as its content, up to `maxHeight`: a dropdown window
// sizes itself to what it holds, which a plain ScrollView does not report.
struct FittedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(
                GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeight.self, value: geometry.size.height)
                }
            )
        }
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(ContentHeight.self) { height = $0 }
    }
}

struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// A small segmented control: the chosen range filled, the others plain.
struct RangePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(timeRanges, id: \.key) { range in
                let isChosen = range.key == selection
                Text(range.key)
                    .font(.system(size: 11, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isChosen ? Color.primary.opacity(0.12) : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { selection = range.key }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

struct Pill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(trailing).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, edge)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// A full-width row that highlights under the pointer, as a menu item does.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, edge - 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}

// Starting Agent Dock at login, so its item is there whenever Claude or
// Antigravity opens. On by default; macOS lists it under Login Items.
struct LoginItemRow: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var note = ""

    var body: some View {
        HoverRow(action: toggle) {
            HStack {
                Text("登录时自动启动").font(.system(size: 13))
                Spacer()
                if !note.isEmpty {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .onAppear { isOn = SMAppService.mainApp.status == .enabled }
    }

    private func toggle() {
        do {
            if isOn {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            note = SMAppService.mainApp.status == .requiresApproval ? "需在系统设置里允许" : ""
        } catch {
            note = "设置失败"
        }
        isOn = SMAppService.mainApp.status == .enabled
    }
}
