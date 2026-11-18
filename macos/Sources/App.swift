// Agent Dock: a menu bar item that drops down Claude Code, Codex, and
// Antigravity sessions, each in a column, by project. It starts at login
// and shows its item while Claude, Codex, or Antigravity is running.

import AppKit
import Combine
import ServiceManagement
import SwiftUI

extension Notification.Name {
    // Posted when a row has opened something, so the dropdown gets out of the way.
    static let closeDropdown = Notification.Name("AgentDockCloseDropdown")
}

// Whether any app of the given bundle identifiers is running.
final class AppWatcher: ObservableObject {
    @Published var isRunning = false
    private let bundleIDs: Set<String>
    private var observers: [NSObjectProtocol] = []

    init(bundleIDs: [String]) {
        self.bundleIDs = Set(bundleIDs)
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, let id = app?.bundleIdentifier, self.bundleIDs.contains(id) else { return }
                self.refresh()
            })
        }
    }

    private func refresh() {
        isRunning = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(bundleIDs.contains) ?? false
        }
    }
}

// A borderless, rounded, always-dark panel over the desktop blur. The dropdown
// and the hover preview are both one; ObsidianSurface draws the black on top.
final class GlassPanel: NSPanel {
    private let canKey: Bool

    init(content: NSView, radius: CGFloat, canBecomeKey: Bool) {
        canKey = canBecomeKey
        super.init(contentRect: NSRect(x: 0, y: 0, width: columnWidth, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Dark whatever the system setting: .hudWindow is then a neutral dark
        // blur, without the grey haze of .menu.
        appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.maskImage = mask

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { canKey }
}

// The card showing what the session under the pointer has been saying. It
// appears 0.4 s after the pointer settles on a row, next to the pointer and
// inside the dropdown where it can, stays while the pointer crosses onto it,
// and rereads a running session every 1.5 s.
//
// Its size is fixed when it comes up (360×420, narrower or shorter only where
// the space demands) and its place is worked out once: content arriving or
// growing scrolls inside it and never moves the window. It grows in from the
// pointer's side and fades; it shrinks and fades away.
final class PreviewController {
    private let model = PreviewModel()
    private let host: NSHostingController<AnyView>
    private let panel: GlassPanel
    private weak var dropdown: NSWindow?
    private let reader = TranscriptReader()
    // The latest state of a session, so a preview notices it finish.
    var lookup: ((String) -> Session?)?

    private var cache: [String: [PreviewEntry]] = [:]
    private var pendingID: String?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var refresh: Timer?
    private var isInsideCard = false
    // Set while the card shrinks away; a new show cancels it.
    private var hideToken: UUID?

    private var isShowing: Bool { panel.isVisible && hideToken == nil }

    init(dropdown: NSWindow, state: DropdownState) {
        self.dropdown = dropdown
        host = NSHostingController(rootView: AnyView(EmptyView()))
        // The window decides the size; the content never pushes it.
        host.sizingOptions = []
        panel = GlassPanel(content: host.view, radius: previewRadius, canBecomeKey: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.contentView?.wantsLayer = true
        host.rootView = AnyView(SessionPreviewView(model: model, onHover: { [weak self] inside in
            self?.cardHover(inside)
        }).environmentObject(state))
    }

    func hover(_ session: Session, inside: Bool, frame: NSRect) {
        if inside {
            hideWork?.cancel()
            showWork?.cancel()
            if isShowing, model.session?.id == session.id { return }
            pendingID = session.id
            let work = DispatchWorkItem { [weak self] in self?.show(session, rowFrame: frame) }
            showWork = work
            // Moving between rows while a card is up switches it sooner.
            DispatchQueue.main.asyncAfter(deadline: .now() + (isShowing ? 0.25 : 0.4), execute: work)
        } else {
            if pendingID == session.id {
                showWork?.cancel()
                pendingID = nil
            }
            scheduleHide()
        }
    }

    func hide() {
        showWork?.cancel()
        hideWork?.cancel()
        refresh?.invalidate()
        refresh = nil
        pendingID = nil
        isInsideCard = false
        guard panel.isVisible, hideToken == nil else { return }

        let token = UUID()
        hideToken = token
        if let layer = panel.contentView?.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: Self.scale(0.96, around: center(of: layer), in: layer))
            shrink.duration = 0.14
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "preview")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.hideToken = nil
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.contentView?.layer?.removeAnimation(forKey: "preview")
        })
    }

    private func cardHover(_ inside: Bool) {
        isInsideCard = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    // Leaves a moment to cross from the row onto the card.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isInsideCard else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func show(_ session: Session, rowFrame: NSRect) {
        guard let dropdown, dropdown.isVisible else { return }
        pendingID = nil
        let pointer = NSEvent.mouseLocation
        let screen = (dropdown.screen ?? NSScreen.main)?.visibleFrame ?? dropdown.frame
        guard let place = Self.placement(pointer: pointer, row: rowFrame, height: previewHeight,
                                         dropdown: dropdown.frame, screen: screen) else { return }

        let wasShowing = isShowing
        // A card that was shrinking away comes back from where it is.
        hideToken = nil

        if wasShowing {
            // Another row: the card glides over and its content fades across.
            withAnimation(.easeOut(duration: 0.18)) { fill(session, size: place.frame.size) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(place.frame, display: true)
            }
        } else {
            fill(session, size: place.frame.size)
            panel.setFrame(place.frame, display: true)
            panel.invalidateShadow()
            appear(growingFrom: pointer)
        }
        load(session)

        refresh?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    private func fill(_ session: Session, size: NSSize) {
        model.width = size.width
        model.height = size.height
        model.session = session
        model.entries = cache[session.id] ?? []
        model.isLoading = true
    }

    // Fades in while growing from 86% with a light spring, anchored at the
    // point nearest the pointer, so the card seems to come out of it.
    private func appear(growingFrom pointer: NSPoint) {
        let isFading = panel.isVisible
        if !isFading { panel.alphaValue = 0 }
        panel.orderFront(nil)
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 1
            return
        }
        let local = NSPoint(x: min(max(pointer.x - panel.frame.minX, 0), panel.frame.width),
                            y: min(max(pointer.y - panel.frame.minY, 0), panel.frame.height))
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Self.scale(isFading ? 0.96 : 0.86, around: local, in: layer))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.mass = 1
        grow.stiffness = 420
        grow.damping = 32
        grow.duration = grow.settlingDuration
        layer.removeAnimation(forKey: "preview")
        layer.add(grow, forKey: "preview")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func center(of layer: CALayer) -> NSPoint {
        NSPoint(x: layer.bounds.midX, y: layer.bounds.midY)
    }

    // Scales by `factor` about `point` (in the view's coordinates), whatever
    // the layer's anchor point.
    private static func scale(_ factor: CGFloat, around point: NSPoint, in layer: CALayer) -> CATransform3D {
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let x = point.x - anchor.x
        let y = (layer.isGeometryFlipped ? layer.bounds.height - point.y : point.y) - anchor.y
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-x, -y, 0),
                                                       CATransform3DMakeScale(factor, factor, 1)),
                                   CATransform3DMakeTranslation(x, y, 0))
    }

    private func tick() {
        guard isShowing, let current = model.session else { return }
        let fresh = lookup?(current.id) ?? current
        if fresh != current { model.session = fresh }
        // A running session keeps writing; a finished one is read once more, then left.
        if fresh.isRunning || current.isRunning { load(fresh) }
    }

    private func load(_ session: Session) {
        reader.load(session) { [weak self] entries in
            guard let self, self.model.session?.id == session.id else { return }
            self.cache[session.id] = entries
            if entries != self.model.entries {
                withAnimation(.easeOut(duration: 0.15)) { self.model.entries = entries }
            }
            self.model.isLoading = false
        }
    }

    struct Placement {
        let index: Int
        let frame: NSRect
    }

    // Where the card goes, in screen coordinates; the first of these that
    // works, P being the dropdown inset by 8 pt:
    //   0. right of the pointer, wholly inside P;
    //   1. left of the pointer, wholly inside P;
    //   2. right or left of the pointer inside P's width, taller than P allows;
    //   3. below the row, narrowed to P's width, wholly inside P;
    //   4. above the row, the same;
    //   5. below or above the row, whichever has more screen, shortened to fit.
    // Beside the pointer the card's top sits 12 pt above it and slides up or
    // down to stay in P (or, for 2, on screen). Pure geometry: also run by
    // `AgentDock --test-placement`.
    static func placement(pointer: NSPoint, row: NSRect, height: CGFloat,
                          dropdown: NSRect, screen: NSRect) -> Placement? {
        let inner = dropdown.insetBy(dx: 8, dy: 8)
        let narrow = min(previewWidth, dropdown.width - 16)

        func beside(right: Bool, within area: NSRect) -> NSRect {
            let x = right ? pointer.x + 16 : pointer.x - 16 - previewWidth
            var y = min(pointer.y + 12, area.maxY) - height
            if y < area.minY { y = area.minY }
            if y + height > area.maxY { y = area.maxY - height }
            return NSRect(x: x, y: y, width: previewWidth, height: height)
        }
        func around(below: Bool, height: CGFloat) -> NSRect {
            let x = min(max(pointer.x - narrow / 2, inner.minX), inner.maxX - narrow)
            let y = below ? row.minY - 6 - height : row.maxY + 6
            return NSRect(x: x, y: y, width: narrow, height: height)
        }

        for right in [true, false] {
            let rect = beside(right: right, within: inner)
            if inner.contains(rect) { return Placement(index: right ? 0 : 1, frame: rect) }
        }
        for right in [true, false] {
            let rect = beside(right: right, within: screen)
            if rect.minX >= inner.minX && rect.maxX <= inner.maxX { return Placement(index: 2, frame: rect) }
        }
        for below in [true, false] {
            let rect = around(below: below, height: height)
            if inner.contains(rect) { return Placement(index: below ? 3 : 4, frame: rect) }
        }
        let roomBelow = row.minY - 6 - (screen.minY + 8)
        let roomAbove = (screen.maxY - 8) - row.maxY - 6
        let below = roomBelow >= roomAbove
        let fitted = max(160, min(height, max(roomBelow, roomAbove)))
        return Placement(index: 5, frame: around(below: below, height: fitted))
    }
}

// The status item and its dropdown, in AppKit: SwiftUI's MenuBarExtra with
// `isInserted` wrote back to the binding inside every view update, looping
// the main thread so that clicks went unanswered.
final class StatusController: NSObject, NSWindowDelegate {
    private let model: BoardModel
    private let claude = AppWatcher(bundleIDs: ClaudeFeed.bundleIDs)
    private let codex = AppWatcher(bundleIDs: CodexFeed.bundleIDs)
    private let antigravity = AppWatcher(bundleIDs: AntigravityFeed.bundleIDs)
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dropdown: DropdownState
    private let host: NSHostingController<AnyView>
    private let panel: GlassPanel
    private let preview: PreviewController
    private var bag: Set<AnyCancellable> = []
    private var sizeWatch: NSKeyValueObservation?
    private var clickMonitor: Any?
    private var closedAt = Date.distantPast
    private var anchor: NSPoint?
    // Pinned and dragged somewhere: keep it there instead of under the item.
    private var userMoved = false
    private var isPlacing = false

    init(model: BoardModel) {
        self.model = model
        let state = DropdownState()
        let hosting = NSHostingController(rootView: AnyView(BoardView(model: model).environmentObject(state)))
        hosting.sizingOptions = [.preferredContentSize]
        let glass = GlassPanel(content: hosting.view, radius: dropdownRadius, canBecomeKey: true)
        dropdown = state
        host = hosting
        panel = glass
        preview = PreviewController(dropdown: glass, state: state)
        super.init()

        panel.delegate = self
        panel.isMovableByWindowBackground = model.isPinned
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.onHoverSession = { [weak self] session, inside, frame in
            self?.preview.hover(session, inside: inside, frame: frame)
        }
        preview.lookup = { [weak model] id in
            guard let model else { return nil }
            return (model.claude + model.codex + model.antigravity).first { $0.id == id }
        }

        // Keep the panel's top edge under the item as the board grows or shrinks.
        sizeWatch = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.place() }
        }
        model.objectWillChange.merge(with: model.animator.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.redrawIcon() }
            .store(in: &bag)
        model.$isPinned
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPinned in self?.pinChanged(isPinned) }
            .store(in: &bag)
        // The app runs from login on; its item comes and goes with Claude, Codex, and Antigravity.
        Publishers.CombineLatest4(claude.$isRunning, codex.$isRunning, antigravity.$isRunning, model.$hasActiveCodexSession)
            .map { $0 || $1 || $2 || $3 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isAnyRunning in
                self?.item.isVisible = isAnyRunning
                if !isAnyRunning { self?.close() }
            }
            .store(in: &bag)
        NotificationCenter.default.addObserver(forName: .closeDropdown, object: nil, queue: .main) { [weak self] _ in
            self?.close()
        }
        redrawIcon()
    }

    private func redrawIcon() {
        let running = model.runningCount
        let image = MenuIcon.cached(spin: running > 0 ? model.animator.phase : nil,
                                    hasUnread: model.unreadCount > 0,
                                    count: running)
        if item.button?.image !== image { item.button?.image = image }
    }

    @objc private func toggle() {
        // A click on the item while open first takes the key away, which closes it.
        if panel.isVisible || Date().timeIntervalSince(closedAt) < 0.25 {
            close()
        } else {
            open()
        }
    }

    private func open() {
        guard let button = item.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        anchor = NSPoint(x: rect.minX, y: rect.minY - 4)
        dropdown.isOpen = true
        model.isShown = true
        model.load()
        place()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.model.isPinned else { return }
            self.close()
        }
    }

    private func place() {
        var size = host.preferredContentSize
        if size.width < 1 || size.height < 1 { size = host.view.fittingSize }
        var frame: NSRect
        if model.isPinned && userMoved {
            // Where it was dragged: same top-left corner, growing downwards.
            frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            if let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.x = min(max(frame.minX, area.minX + 8), area.maxX - size.width - 8)
                frame.origin.y = max(frame.minY, area.minY + 8)
            }
        } else {
            guard let anchor else { return }
            var x = anchor.x
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
                let area = screen.visibleFrame
                x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
            }
            frame = NSRect(x: x, y: anchor.y - size.height, width: size.width, height: size.height)
        }
        isPlacing = true
        panel.setFrame(frame, display: true)
        isPlacing = false
    }

    private func pinChanged(_ isPinned: Bool) {
        panel.isMovableByWindowBackground = isPinned
        guard !isPinned else { return }
        // Unpinned: back under the item, and closing on outside clicks again.
        userMoved = false
        preview.hide()
        if panel.isVisible {
            place()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        preview.hide()
        panel.orderOut(nil)
        dropdown.isOpen = false
        model.isShown = false
        closedAt = Date()
        item.button?.highlight(false)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !model.isPinned else { return }
        close()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPlacing else { return }
        if model.isPinned { userMoved = true }
        preview.hide()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start at login unless the person has turned that off since.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "loginItemConfigured") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginItemConfigured")
        }
        controller = StatusController(model: BoardModel())
    }
}

@main
enum AgentDockApp {
    static let delegate = AppDelegate()

    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-icon"), flag + 1 < args.count {
            MenuIcon.render(to: args[flag + 1])
            return
        }
        // Runs the preview card's placement on the desk the peek preview drew
        // (1512×640, menu bar 28), printing frames in that top-left space.
        if args.contains("--test-placement") {
            let height: CGFloat = 640
            func flip(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x, y: height - top - h, width: w, height: h)
            }
            let screen = flip(0, 28, 1512, 612)
            let wide = flip(480, 36, 1022, 584)
            let narrow = flip(1162, 36, 340, 344)
            let cases: [(String, NSPoint, NSRect, NSRect)] = [
                ("near-cursor", NSPoint(x: 650, y: height - 292), flip(486, 279, 328, 26), wide),
                ("edge-flip", NSPoint(x: 1330, y: height - 560), flip(1168, 551, 328, 26), wide),
                ("single-col", NSPoint(x: 1300, y: height - 292), flip(1168, 279, 328, 26), narrow),
            ]
            for (name, pointer, row, dropdown) in cases {
                guard let p = PreviewController.placement(pointer: pointer, row: row, height: previewHeight,
                                                          dropdown: dropdown, screen: screen) else {
                    print("\(name): none")
                    continue
                }
                let f = p.frame
                print("\(name): placement \(p.index)  left \(Int(f.minX)) top \(Int(height - f.maxY)) width \(Int(f.width)) height \(Int(f.height))")
            }
            return
        }
        // Prints what the hover preview reads for the latest session of each source.
        if args.contains("--print-preview") {
            let reader = TranscriptReader()
            let samples: [(String, Session?)] = [
                ("Claude", ClaudeFeed.readSessions()?.sessions.max { $0.lastActivity < $1.lastActivity }),
                ("Codex", CodexFeed().read().first),
                ("Antigravity", AntigravityFeed().read().first),
            ]
            for (name, session) in samples {
                guard let session else {
                    print("[\(name)] no session")
                    continue
                }
                let entries = reader.entriesNow(for: session)
                print("[\(name)] \(session.title) — \(entries.count) entries")
                for entry in entries {
                    let label: String
                    switch entry.kind {
                    case .user: label = "user"
                    case .thinking: label = "thinking"
                    case .tools(let names): label = "tools(\(names.count))"
                    case .reply: label = "reply"
                    }
                    let text: String
                    if case .tools(let names) = entry.kind { text = names.joined(separator: " | ") } else { text = entry.text }
                    print("  \(label)\t\(text.replacingOccurrences(of: "\n", with: " ").prefix(90))")
                }
            }
            return
        }
        // Prints Codex and Antigravity conversations as the dock reads them.
        if args.contains("--print-conversations") {
            let codexFeed = CodexFeed()
            let codexThreads = codexFeed.read()
            print("[Codex] \(codexThreads.count) threads" + (codexFeed.lastError.map { ", last error: \($0)" } ?? ""))
            for c in codexThreads.prefix(8) {
                print("  \(c.state)\t\(c.project)\t\(ago(c.lastActivity, now: Date()))\t\(c.title)")
            }
            let feed = AntigravityFeed()
            let conversations = feed.read()
            print("[Antigravity] \(conversations.count) conversations" + (feed.lastError.map { ", last error: \($0)" } ?? ""))
            for c in conversations.prefix(8) {
                print("  \(c.state)\t\(c.project)\t\(ago(c.lastActivity, now: Date()))\t\(c.title)")
            }
            return
        }
        // Prints Codex and Antigravity limits as the dock reads them, for checking outside the menu bar.
        if args.contains("--print-quota") {
            let group = DispatchGroup()
            var codexRows: [UsageRow]?
            var antigravityRows: [UsageRow]?

            group.enter()
            let codexQuota = CodexQuota()
            codexQuota.fetch { rows in
                codexRows = rows
                group.leave()
            }

            group.enter()
            let quota = AntigravityQuota()
            quota.fetch { rows in
                antigravityRows = rows
                group.leave()
            }

            group.notify(queue: .main) {
                print("[Codex]")
                if let codexRows, !codexRows.isEmpty {
                    for row in codexRows { print("  \(row.label)\t\(row.percentUsed)% used\tresets \(row.resetsAt)") }
                } else {
                    print("  Codex did not answer (is codex CLI / ChatGPT.app installed and signed in?)")
                }
                print("[Antigravity]")
                if let antigravityRows, !antigravityRows.isEmpty {
                    for row in antigravityRows { print("  \(row.label)\t\(row.percentUsed)% used\tresets \(row.resetsAt)") }
                } else {
                    print("  Antigravity did not answer (is it running?)")
                }
                exit(codexRows == nil && antigravityRows == nil ? 1 : 0)
            }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
