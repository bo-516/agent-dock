// Agent Dock: a menu bar item that drops down the Claude Code sessions and the
// Antigravity conversations, each in a column, by project. It starts at login
// and shows its item while Claude or Antigravity is running.

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

// The dropdown: a borderless, rounded panel of menu material under the item.
final class DropdownPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: columnWidth, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        let radius: CGFloat = 12
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

    override var canBecomeKey: Bool { true }
}

// The status item and its dropdown, in AppKit: SwiftUI's MenuBarExtra with
// `isInserted` wrote back to the binding inside every view update, looping
// the main thread so that clicks went unanswered.
final class StatusController: NSObject, NSWindowDelegate {
    private let model: BoardModel
    private let claude = AppWatcher(bundleIDs: ClaudeFeed.bundleIDs)
    private let antigravity = AppWatcher(bundleIDs: AntigravityFeed.bundleIDs)
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dropdown = DropdownState()
    private let host: NSHostingController<AnyView>
    private let panel: DropdownPanel
    private var bag: Set<AnyCancellable> = []
    private var sizeWatch: NSKeyValueObservation?
    private var clickMonitor: Any?
    private var closedAt = Date.distantPast
    private var anchor: NSPoint?

    init(model: BoardModel) {
        self.model = model
        host = NSHostingController(rootView: AnyView(BoardView(model: model).environmentObject(dropdown)))
        host.sizingOptions = [.preferredContentSize]
        panel = DropdownPanel(content: host.view)
        super.init()

        panel.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Keep the panel's top edge under the item as the board grows or shrinks.
        sizeWatch = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.place() }
        }
        model.objectWillChange.merge(with: model.animator.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.redrawIcon() }
            .store(in: &bag)
        // The app runs from login on; its item comes and goes with Claude and Antigravity.
        claude.$isRunning.combineLatest(antigravity.$isRunning)
            .map { $0 || $1 }
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
            self?.close()
        }
    }

    private func place() {
        guard let anchor else { return }
        var size = host.preferredContentSize
        if size.width < 1 || size.height < 1 { size = host.view.fittingSize }
        var x = anchor.x
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
    }

    private func close() {
        guard panel.isVisible else { return }
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
        close()
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
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
