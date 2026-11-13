import AppKit
import SwiftUI
import Combine
import NotcherCore
import QuartzCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A click on a panel that is not the key window must act at once, not merely focus it.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
/// Clips the fixed-size canvas to the window and reports the pointer even while another app is active.
private final class NotchContainer: NSView {
    var onPointer: (() -> Void)?
    private var area: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { onPointer?() }
    override func mouseMoved(with event: NSEvent) { onPointer?() }
    override func mouseExited(with event: NSEvent) { onPointer?() }
}

@MainActor final class NotchController: NSObject {
    /// The drawing never changes size: the window only reveals more or less of it. Resizing the window
    /// therefore cannot shift the content, even for a single frame.
    private static let canvas = CGSize(width: 920, height: 640)
    private let container = NotchContainer()
    private var hosting: NSView?
    let model: AppModel
    private let panel: NotchPanel
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var lastInside = false
    private var contextMenuOpen = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var anchor = CGPoint.zero
    private var geometryQueued = false
    /// Identifies the transition in flight; a stale completion must never resize the window.
    private var transition = 0
    private var settleTask: Task<Void, Never>?
    /// Area actually drawn, in screen coordinates. The window may be larger while a transition runs.
    private var shapeFrame: CGRect { PanelGeometry.frame(size: model.targetSize, topCenter: anchor) }
    private var screen: NSScreen? { NSScreen.screens.first { displayID($0) == model.preferences.screenID } ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first }

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isMovable = false; panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        let hosting = NotchHostingView(rootView: NotchView(model: model, followsWindow: true).preferredColorScheme(.dark))
        hosting.sizingOptions = []
        hosting.autoresizingMask = []
        hosting.frame = NSRect(origin: .zero, size: Self.canvas)
        container.wantsLayer = true; container.layer?.masksToBounds = true
        container.addSubview(hosting); self.hosting = hosting
        container.onPointer = { [weak self] in self?.pointerMoved(click: false) }
        panel.contentView = container
        model.onGeometryChange = { [weak self] in self?.scheduleGeometry() }
        model.$tab.dropFirst().sink { [weak self] _ in self?.panel.makeFirstResponder(nil) }.store(in: &subscriptions)
        model.$expanded.dropFirst().sink { [weak self] expanded in
            if !expanded { self?.panel.makeFirstResponder(nil); self?.panel.resignKey() }
        }.store(in: &subscriptions)
        model.$dialogOpen.dropFirst().sink { [weak self] open in if !open { self?.scheduleClose() } }.store(in: &subscriptions)
        model.$pinned.dropFirst().sink { [weak self] pinned in if !pinned { self?.scheduleClose() } }.store(in: &subscriptions)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reassert() } }
        // After sleep or a Space change the system may reorder or move a borderless panel.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reassert() } })
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in Task { @MainActor in self?.mouse(event) } }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown), handler: { [weak self] event in
            guard let self, !self.contextMenuOpen else { return event }
            if event.window === self.panel && (event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))) {
                self.showContextMenu(event)
                return nil
            }
            // Open on the press itself: no gesture recogniser, no dependence on which window has the focus.
            if event.type == .leftMouseDown, !self.model.expanded, self.shapeFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
                self.hoverTask?.cancel(); self.model.expand(); self.lastInside = true
                return nil
            }
            if event.type == .keyDown && event.keyCode == 53 && self.panel.isKeyWindow { self.model.collapse(); return nil }
            // ⌘1…⌘5 jump between the visible tabs while the panel has the keyboard.
            if event.type == .keyDown, self.panel.isKeyWindow, self.model.expanded,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...self.model.visibleTabs.count).contains(digit) {
                self.model.select(self.model.visibleTabs[digit - 1]); return nil
            }
            self.mouse(event); return event
        }) { monitors.append(local) }
    }
    func show() { updateGeometry(animated: false); panel.orderFrontRegardless() }
    func stop() {
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers.removeAll()
        hoverTask?.cancel(); closeTask?.cancel(); settleTask?.cancel(); transition += 1; panel.orderOut(nil)
    }
    func toggle() {
        if model.expanded { model.collapse() }
        else { model.expand(); panel.makeKeyAndOrderFront(nil) }
    }
    /// Opens without toggling; used when the app is launched again while already running.
    func open() { if !model.expanded { toggle() } }
    private func reassert() { updateGeometry(animated: false); panel.orderFrontRegardless() }
    private func scheduleGeometry() {
        guard !geometryQueued else { return }
        geometryQueued = true
        DispatchQueue.main.async { [weak self] in self?.geometryQueued = false; self?.updateGeometry() }
    }
    /// The window only changes size at rest. During a transition it is large enough for both shapes and
    /// SwiftUI animates the drawn shape inside it, so no frame of the animation resizes a window.
    func updateGeometry(animated: Bool = true) {
        guard let target = screen else { return }
        let width: CGFloat
        if let left = target.auxiliaryTopLeftArea, let right = target.auxiliaryTopRightArea { width = max(130, right.minX - left.maxX) }
        else { width = 160 }
        let height = target.safeAreaInsets.top > 0 ? target.safeAreaInsets.top : 26
        if model.notchWidth != width { model.notchWidth = width }
        if model.notchHeight != height { model.notchHeight = height }
        let destination = model.targetSize
        let nextAnchor = CGPoint(x: target.frame.midX, y: target.frame.maxY)
        let moved = anchor != nextAnchor
        anchor = nextAnchor
        let unchanged = model.shapeSize == destination && model.presentationExpanded == model.expanded
        if unchanged && !moved && settleTask != nil { return } // Repeated service updates must not restart a transition.
        guard animated, !unchanged, !moved, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            settleTask?.cancel(); settleTask = nil; transition += 1
            var instant = Transaction(); instant.disablesAnimations = true
            if !unchanged { withTransaction(instant) { model.shapeSize = destination; model.presentationExpanded = model.expanded } }
            place(destination)
            return
        }
        transition += 1
        let token = transition
        // The current window already holds the shape being drawn, including an interrupted transition.
        place(PanelGeometry.envelope(panel.frame.size, PanelGeometry.envelope(destination, destination, margin: 28)))
        let style = model.preferences.motionStyle
        let spring = model.expanded && !model.presentationExpanded ? style.opening : style.closing
        withAnimation(.spring(response: spring.response, dampingFraction: spring.damping), completionCriteria: .removed) {
            model.shapeSize = destination; model.presentationExpanded = model.expanded
        } completion: { [weak self] in Task { @MainActor in self?.settle(token) } }
        // The completion is an optimisation; this bound guarantees the window never stays oversized.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1400)); self?.settle(token) } catch {}
        }
    }
    private func settle(_ token: Int) {
        guard token == transition else { return }
        settleTask?.cancel(); settleTask = nil
        place(model.shapeSize)
    }
    private func place(_ size: CGSize) {
        let frame = PanelGeometry.frame(size: PanelGeometry.envelope(size, size), topCenter: anchor)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Keep the canvas hanging from the top centre of the window, whatever the window size.
        let origin = CGPoint(x: ((frame.width - Self.canvas.width) / 2).rounded(), y: frame.height - Self.canvas.height)
        if hosting?.frame.origin != origin { hosting?.setFrameOrigin(origin) }
        CATransaction.commit()
    }
    private func mouse(_ event: NSEvent) {
        pointerMoved(click: event.type == .leftMouseDown, drag: event.type == .leftMouseDragged && event.window !== panel)
    }
    private func pointerMoved(click: Bool, drag: Bool = false) {
        guard !contextMenuOpen else { return }
        let point = NSEvent.mouseLocation
        // A transparent margin exists around the shape during transitions; only the shape counts.
        let inside = shapeFrame.insetBy(dx: -2, dy: -2).contains(point)
        if drag && inside {
            model.expand(tab: .files); closeTask?.cancel(); return
        }
        if inside {
            closeTask?.cancel()
            if !lastInside && !model.expanded && model.preferences.openMode == .touch {
                // Acknowledge the pointer; the click itself is handled by the notch header.
                model.hovering = true; Haptics.play(.alignment)
            }
            if !lastInside && model.preferences.openMode == .hover && !model.expanded {
                hoverTask?.cancel()
                hoverTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(120)); guard let self, self.shapeFrame.contains(NSEvent.mouseLocation) else { return }; self.model.expand() } catch {}
                }
            }
        } else {
            hoverTask?.cancel()
            if model.hovering { model.hovering = false }
            if click && model.expanded && !model.pinned && !model.dialogOpen { model.collapse() }
            else if lastInside && model.expanded && !model.pinned {
                scheduleClose()
            }
        }
        lastInside = inside
    }
    private func showContextMenu(_ event: NSEvent) {
        guard !contextMenuOpen, let view = panel.contentView else { return }
        hoverTask?.cancel(); closeTask?.cancel()
        contextMenuOpen = true
        let menu = NSMenu()
        let settings = NSMenuItem(title: L("Réglages…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings); menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quitter Notcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        contextMenuOpen = false
        scheduleClose()
    }
    @objc private func openSettings() { model.openSettings?() }
    private func scheduleClose() {
        closeTask?.cancel()
        let delay = model.preferences.closeDelay.seconds
        closeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, self.model.expanded, !self.contextMenuOpen else { return }
                let editing = (self.panel.firstResponder as? NSTextView)?.isEditable == true
                guard PanelDismissal.shouldClose(pointerInside: self.shapeFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation), pinned: self.model.pinned,
                                                 dragging: self.model.dragging, dialogOpen: self.model.dialogOpen, editingText: editing) else { return }
                self.model.collapse()
            } catch {}
        }
    }
    private func displayID(_ screen: NSScreen) -> Int { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }
}
