// The dropdown: a top bar with the pin, the source switches and the time range,
// then one column per shown source (Claude, Codex, Antigravity), then the app's
// own rows. Also the hover preview card and the gloss-black surface both share.

import AppKit
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
                if model.showClaude && (model.showCodex || model.showAntigravity) {
                    Divider()
                }
                if model.showCodex {
                    CodexColumn(model: model, range: range, expanded: $expanded)
                }
                if model.showCodex && model.showAntigravity {
                    Divider()
                }
                if model.showAntigravity {
                    AntigravityColumn(model: model, range: range, expanded: $expanded)
                }
                if visibleColumns == 0 {
                    Text("Claude、Codex 和 Antigravity 都隐藏了，点上面的按钮显示")
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
        .background(ObsidianSurface(cornerRadius: dropdownRadius))
    }

    private var visibleColumns: Int {
        (model.showClaude ? 1 : 0) + (model.showCodex ? 1 : 0) + (model.showAntigravity ? 1 : 0)
    }

    // One column per shown source and the lines between them; one column's worth with none.
    private var width: CGFloat {
        guard visibleColumns > 0 else { return columnWidth }
        return columnWidth * CGFloat(visibleColumns) + CGFloat(visibleColumns - 1)
    }
}

struct TopBar: View {
    @ObservedObject var model: BoardModel
    @Binding var rangeKey: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("Agent Dock").font(.system(size: 14, weight: .semibold))
                        if model.isPinned {
                            Text("已常驻 · 按住顶栏空白处可拖动").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                PinToggle(isOn: $model.isPinned)
                SourceToggle(name: "Claude", isOn: $model.showClaude)
                SourceToggle(name: "Codex", isOn: $model.showCodex)
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
        // Pinned, the top bar is a handle for moving the dropdown.
        .background {
            if model.isPinned { WindowDragArea() }
        }
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
            .background(Capsule().fill(LinearGradient(
                colors: isOn ? [.white.opacity(0.14), .white.opacity(0.08)] : [.clear, .clear],
                startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.2)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "隐藏 \(name)" : "显示 \(name)")
    }
}

// Pins the dropdown: it then stays up when another app comes forward or a row
// opens something, and the top bar drags it. White when on, no tint.
struct PinToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "pin.fill" : "pin").font(.system(size: 10, weight: .semibold))
                Text(isOn ? "常驻中" : "常驻").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(LinearGradient(
                colors: isOn ? [.white.opacity(0.22), .white.opacity(0.12)] : [.clear, .clear],
                startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0.34 : 0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "取消常驻：点别处时自动收起" : "常驻：切换应用、打开会话时不收起，可拖动")
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

struct CodexColumn: View {
    @ObservedObject var model: BoardModel
    let range: TimeRange
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(title: "Codex", note: nil, open: { model.openApp(CodexFeed.bundleIDs[0]) })
            if !model.codexUsage.isEmpty {
                UsageSection(rows: model.codexUsage, updatedAt: model.codexUsageAt, now: model.now)
                Divider().padding(.horizontal, edge)
            }
            SessionList(model: model, sessions: model.visible(model.codex, within: range.seconds),
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
                SessionRow(session: session, now: model.now,
                           open: { model.open(session) },
                           hover: { inside, frame in model.hoverSession(session, inside: inside, frame: frame) })
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
    // The pointer entered or left the row, with the row's frame on screen.
    let hover: (Bool, NSRect) -> Void

    var body: some View {
        HoverRow(action: open, onHover: hover) {
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
// Hover comes from an always-active tracking area rather than `.onHover`, so it
// still works on a pinned dropdown while another app is in front.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    var onHover: ((Bool, NSRect) -> Void)? = nil
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
                        .fill(isHovered ? Color.white.opacity(0.10) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0), lineWidth: 0.5))
                )
                .background(HoverTracker { inside, frame in
                    isHovered = inside
                    onHover?(inside, frame)
                })
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
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

// MARK: - Gloss black surface

let dropdownRadius: CGFloat = 14
let previewRadius: CGFloat = 12
let previewWidth: CGFloat = 360

// Drawn over the dark blur: a neutral black glaze (equal channels, so nothing
// behind tints it), a clear-coat lift and diagonal sweep along the top, a thin
// white rim, and a brighter specular line on the top edge. White only.
struct ObsidianSurface: View {
    let cornerRadius: CGFloat
    // Glaze opacity at the top and the bottom: 80%→86% for the dropdown, denser
    // for the preview card, which often sits over the dropdown itself.
    var glaze: (top: Double, bottom: Double) = (0.80, 0.86)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.04, opacity: glaze.top), Color(white: 0.017, opacity: glaze.bottom)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .white.opacity(0.07), location: 0),
                                   .init(color: .white.opacity(0.012), location: 0.45),
                                   .init(color: .white.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
            GeometryReader { geometry in
                LinearGradient(stops: [.init(color: .white.opacity(0.075), location: 0),
                                       .init(color: .white.opacity(0.02), location: 0.46),
                                       .init(color: .white.opacity(0), location: 0.72)],
                               startPoint: UnitPoint(x: 0, y: 0.35), endPoint: UnitPoint(x: 1, y: 0.65))
                    .frame(width: geometry.size.width * 0.62, height: 56)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.30), .white.opacity(0.30), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .padding(.horizontal, cornerRadius)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - AppKit helpers

// Pressing here drags the window (used on the top bar while pinned).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

// Reports the pointer entering and leaving, with the view's frame on screen.
// The tracking area is active even while the app is in the background, and
// the view never takes clicks.
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool, NSRect) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool, NSRect) -> Void)?
        private var isInside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            isInside = true
            onChange?(true, screenFrame)
        }

        override func mouseExited(with event: NSEvent) {
            isInside = false
            onChange?(false, screenFrame)
        }

        // A row scrolled away or removed while under the pointer still counts as left.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard newWindow == nil, isInside else { return }
            isInside = false
            let report = onChange
            DispatchQueue.main.async { report?(false, .zero) }
        }

        private var screenFrame: NSRect {
            guard let window else { return .zero }
            return window.convertToScreen(convert(bounds, to: nil))
        }
    }
}

// MARK: - Hover preview

final class PreviewModel: ObservableObject {
    @Published var session: Session?
    @Published var entries: [PreviewEntry] = []
    @Published var isLoading = false
    // Fixed for as long as the card is up: 360×420, narrower below a row in a
    // one-column dropdown, shorter where the screen has less room.
    @Published var width: CGFloat = previewWidth
    @Published var height: CGFloat = previewHeight
}

let previewHeight: CGFloat = 420

// What the session under the pointer has been saying: newest at the bottom,
// scrolled there; a running session's last thinking reads "思考中".
struct SessionPreviewView: View {
    @ObservedObject var model: PreviewModel
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.session {
                VStack(alignment: .leading, spacing: 0) {
                    header(session)
                    Divider().padding(.horizontal, 14)
                    stream(session)
                }
                // Another session fades across instead of snapping.
                .id(session.id)
                .transition(.opacity)
            }
        }
        // The card's size is the window's: content scrolls, it never resizes.
        .frame(width: model.width, height: model.height, alignment: .top)
        .background(ObsidianSurface(cornerRadius: previewRadius, glaze: (0.90, 0.94)))
        .clipShape(RoundedRectangle(cornerRadius: previewRadius, style: .circular))
        .background(HoverTracker { inside, _ in onHover(inside) })
    }

    private func header(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Marker(state: session.state)
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(subtitle(session))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func subtitle(_ session: Session) -> String {
        let source: String
        switch session.source {
        case .claude: source = "Claude"
        case .codex: source = "Codex"
        case .antigravity: source = "Antigravity"
        }
        let state = session.isRunning ? "运行中，每 1.5 秒刷新" : ago(session.lastActivity, now: Date())
        return "\(source) · \(session.project) · \(state)"
    }

    @ViewBuilder
    private func stream(_ session: Session) -> some View {
        if model.entries.isEmpty {
            Text(model.isLoading ? "读取中…" : "没有可预览的消息")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.entries) { entry in
                            PreviewEntryView(entry: entry,
                                             isLive: session.isRunning && entry.id == model.entries.last?.id,
                                             width: model.width - 28)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
                // Only a new last step scrolls down, so reading further up is not interrupted.
                .onChange(of: model.entries.last?.id) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}

struct PreviewEntryView: View {
    let entry: PreviewEntry
    let isLive: Bool
    // The card's content width.
    let width: CGFloat

    var body: some View {
        switch entry.kind {
        case .user:
            // A bubble at most the width less 36 pt, holding its own markdown.
            HStack(spacing: 0) {
                Spacer(minLength: 36)
                MarkdownView(entry.text, width: min(width - 36 - 20, bubbleWidth))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.11)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
            }
        case .thinking:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isLive { Spinner() }
                    Text(isLive ? "思考中" : "思考")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
                // Inline styles only: thinking is shown from its end, often mid-structure.
                Text(inlineMarkdown(entry.text))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(claudeOrange.opacity(0.8)).frame(width: 2)
            }
        case .tools(let names):
            ChipFlow(spacing: 4) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.10)))
                }
            }
        case .reply:
            MarkdownView(entry.text, width: width)
        }
    }

    // A short prompt hugs its text; a long one wraps at the bubble's widest.
    private var bubbleWidth: CGFloat {
        let longest = entry.text.components(separatedBy: "\n").map { line in
            line.reduce(CGFloat(0)) { $0 + ($1.unicodeScalars.first!.value > 0x2E7F ? 12 : 6.6) }
        }.max() ?? 0
        return max(24, ceil(longest) + 2)
    }
}

// Lays chips out left to right, wrapping to a new line when one does not fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            let needed = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], itemWidth, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
