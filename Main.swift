import AppKit
import QuartzCore
import SwiftUI
import Darwin
import ApplicationServices

/// A cross-launch lock. Launch Services normally prevents duplicates, but this also
/// protects against direct executable launches and `open -n`.
@MainActor
final class SingleInstanceLock {
    static let shared = SingleInstanceLock()
    private var descriptor: Int32 = -1

    private init() {}

    func acquire() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.trailpoint.app.instance.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

struct TrailSettings: Codable, Equatable {
    // Windows' neutral setting is 6/11: a 1:1 base movement multiplier.
    var pointerSpeed = 6.0
    var enhancePrecision = true
    var snapToDefaultButton = false
    var displayTrails = true
    var trailLength = 11.0
    var hidePointerWhileTyping = true
    var showLocationWithControl = true
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var draft: TrailSettings
    @Published private(set) var active: TrailSettings
    var onApply: ((TrailSettings) -> Void)?
    /// `true` when this was an explicit user toggle, so the controller may ask for
    /// Accessibility permission rather than prompting merely because the app launched.
    var onSnapToDefaultButtonChange: ((Bool, Bool) -> Void)?
    private let key = "TrailPoint.settings"

    init() {
        var saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(TrailSettings.self, from: $0) } ?? TrailSettings()
        draft = saved
        active = saved
        loadMacMouseSettings(into: &saved)
        draft = saved
        active = saved
    }

    func apply() {
        active = draft
        if let data = try? JSONEncoder().encode(active) { UserDefaults.standard.set(data, forKey: key) }
        applyMacMouseSettings(active)
        onApply?(active)
        // Recheck on every Apply while Snap To is checked. This catches a
        // permission grant made moments earlier and a later revocation alike.
        onSnapToDefaultButtonChange?(active.snapToDefaultButton, active.snapToDefaultButton)
    }

    func applyPointerSpeed() {
        active.pointerSpeed = draft.pointerSpeed
        if let data = try? JSONEncoder().encode(active) { UserDefaults.standard.set(data, forKey: key) }
        applyMacMouseSettings(active)
    }

    func applyHidePointerWhileTyping() {
        active.hidePointerWhileTyping = draft.hidePointerWhileTyping
        if let data = try? JSONEncoder().encode(active) { UserDefaults.standard.set(data, forKey: key) }
        if !active.hidePointerWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(false)
            NSCursor.unhide()
        }
    }

    func cancel() { draft = active }
    func reset() { draft = TrailSettings() }

    /// `com.apple.mouse.scaling` is the tracking-speed value used by macOS Mouse settings.
    /// Starting with Sonoma, `com.apple.mouse.linear` controls the Advanced pointer-acceleration switch.
    private func applyMacMouseSettings(_ settings: TrailSettings) {
        let scaling = mouseScaling(for: settings.pointerSpeed)
        runDefaults(["write", "NSGlobalDomain", "com.apple.mouse.scaling", "-float", String(format: "%.4f", scaling)])
        // A linear pointer is macOS terminology for acceleration being disabled.
        runDefaults(["write", "NSGlobalDomain", "com.apple.mouse.linear", "-bool", settings.enhancePrecision ? "false" : "true"])
        // Apply the same tracking value to HID immediately; the defaults value alone can be deferred.
        applyImmediateMouseTracking(scaling)
    }

    private func loadMacMouseSettings(into settings: inout TrailSettings) {
        if let scaling = readDefaults("com.apple.mouse.scaling"), let value = Double(scaling) {
            settings.pointerSpeed = nearestSpeed(for: value)
        }
        if let linear = readDefaults("com.apple.mouse.linear")?.lowercased() {
            settings.enhancePrecision = !(linear == "1" || linear == "true" || linear == "yes")
        }
    }

    private func readDefaults(_ key: String) -> String? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "NSGlobalDomain", key]
        task.standardOutput = output
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        guard task.terminationStatus == 0, let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runDefaults(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { NSSound.beep() }
    }

    /// `IOHIDSetAccelerationWithKey` has no replacement API, yet remains the
    /// only system interface that applies mouse tracking speed immediately.
    /// Resolve it at runtime so the project does not compile against a deprecated
    /// SDK declaration while retaining that current-session behavior.
    private func applyImmediateMouseTracking(_ scaling: Double) {
        typealias OpenEventStatus = @convention(c) () -> UInt32
        typealias SetAcceleration = @convention(c) (UInt32, CFString, Double) -> Int32
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let openSymbol = dlsym(library, "NXOpenEventStatus"),
              let setSymbol = dlsym(library, "IOHIDSetAccelerationWithKey") else { return }
        defer { dlclose(library) }
        let open = unsafeBitCast(openSymbol, to: OpenEventStatus.self)
        let set = unsafeBitCast(setSymbol, to: SetAcceleration.self)
        _ = set(open(), "HIDMouseAcceleration" as CFString, scaling)
    }

    private func mouseScaling(for speed: Double) -> Double {
        let values: [Double] = [0, 0.125, 0.5, 0.6875, 0.875, 1, 1.5, 2, 2.5, 3, 3.5]
        return values[min(values.count - 1, max(0, Int(speed.rounded()) - 1))]
    }

    private func nearestSpeed(for scaling: Double) -> Double {
        let values: [Double] = [0, 0.125, 0.5, 0.6875, 0.875, 1, 1.5, 2, 2.5, 3, 3.5]
        let index = values.indices.min(by: { abs(values[$0] - scaling) < abs(values[$1] - scaling) }) ?? 5
        return Double(index + 1)
    }
}

final class TrailOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = TrailOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
    }
}

final class TrailOverlayView: NSView {
    override var wantsLayer: Bool { get { true } set {} }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.clear.cgColor }

    func addPointer(at point: CGPoint, lifetime: CFTimeInterval) {
        let cursor = NSCursor.arrow
        let image = cursor.image
        let size = image.size
        let hotSpot = cursor.hotSpot
        let pointer = CALayer()
        pointer.contents = image
        pointer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        pointer.frame = CGRect(
            x: point.x - hotSpot.x,
            y: point.y - (size.height - hotSpot.y),
            width: size.width,
            height: size.height
        )
        // Windows trail ghosts are full-strength cursor images, removed together on delay.
        pointer.opacity = 1
        layer?.addSublayer(pointer)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { pointer.removeFromSuperlayer() }
    }

    func showLocator(at point: CGPoint) {
        let diameters: [CGFloat] = [108, 88, 68, 48, 28]
        for (index, diameter) in diameters.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.095) { [weak self] in
                self?.showLocatorRing(at: point, diameter: diameter)
            }
        }
    }

    private func showLocatorRing(at point: CGPoint, diameter: CGFloat) {
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ring.position = point
            let path = CGMutablePath()
            path.addEllipse(in: ring.bounds)
            path.addEllipse(in: ring.bounds.insetBy(dx: 3.5, dy: 3.5))
            ring.path = path
            ring.fillRule = .evenOdd
            ring.fillColor = NSColor.windowBackgroundColor.cgColor
            ring.strokeColor = NSColor.white.cgColor
            ring.lineWidth = 0.8
            layer?.addSublayer(ring)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { ring.removeFromSuperlayer() }
    }
}

@MainActor
final class MouseTrailController {
    private let settings: SettingsStore
    private var overlays: [TrailOverlayWindow] = []
    private var monitors: [Any] = []
    private var lastPoint: CGPoint?
    private var lastDrawTime = Date.distantPast
    private var controlWasPressed = false
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var snapTimer: Timer?
    private var lastSnappedTarget: String?
    private var hasShownSnapGrantedAlert = false
    // Windows uses widely spaced cursor stamps rather than sampling every display frame.
    private let sampleInterval: TimeInterval = 1.0 / 30.0
    var isRunning = false

    init(settings: SettingsStore) {
        self.settings = settings
        settings.onSnapToDefaultButtonChange = { [weak self] enabled, userInitiated in
            self?.configureSnapToDefaultButton(enabled: enabled, requestPermission: userInitiated)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildOverlays()
        overlays.forEach { $0.orderFrontRegardless() }
        installEventTap()
        configureSnapToDefaultButton(enabled: settings.active.snapToDefaultButton, requestPermission: false)
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            Task { @MainActor in self?.handle(event, location: location) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            Task { @MainActor in self?.handle(event, location: location) }
            return event
        }) { monitors.append(local) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        eventTap = nil
        eventTapSource = nil
        snapTimer?.invalidate()
        snapTimer = nil
        lastSnappedTarget = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NotificationCenter.default.removeObserver(self)
        lastPoint = nil
    }

    @objc private func screensChanged() { rebuildOverlays(); overlays.forEach { $0.orderFrontRegardless() } }

    private func rebuildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { TrailOverlayWindow(screen: $0) }
    }

    private func handle(_ event: NSEvent, location: CGPoint) {
        if event.type == .flagsChanged {
            // Fallback for Macs where a session event tap is not authorized yet.
            controlChanged(event.modifierFlags.contains(.control))
        } else if event.type == .keyDown && settings.active.hidePointerWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            recordPointerLocation()
        }
    }

    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MouseTrailController>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in
                    if let tap = controller.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
            } else if type == .flagsChanged {
                let controlIsPressed = event.flags.contains(.maskControl)
                Task { @MainActor in controller.controlChanged(controlIsPressed) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func configureSnapToDefaultButton(enabled: Bool, requestPermission: Bool) {
        snapTimer?.invalidate()
        snapTimer = nil
        lastSnappedTarget = nil
        guard enabled else { return }

        if requestPermission { presentSnapToPermissionAlert() }

        // Default buttons appear after a dialog is created, so poll the focused
        // accessibility window briefly. The target key makes this a one-time snap.
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.snapToDefaultButtonIfNeeded() }
        }
        snapTimer?.tolerance = 0.04
    }

    private func presentSnapToPermissionAlert() {
        if AXIsProcessTrusted() {
            guard !hasShownSnapGrantedAlert else { return }
            hasShownSnapGrantedAlert = true
            let alert = NSAlert()
            alert.messageText = "Granted"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Grant TrailPoint Accessibility access"
        alert.informativeText = "Without it, macOS prevents reading other apps’ dialog controls."
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // This is Apple's supported prompt which sends the person to Privacy &
        // Security > Accessibility. If permission is later revoked, this branch
        // is reached again the next time Snap To is enabled.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func snapToDefaultButtonIfNeeded() {
        guard settings.active.snapToDefaultButton, AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication else { return }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let target = defaultButtonTarget(in: appElement) else {
            lastSnappedTarget = nil
            return
        }

        let key = "\(application.processIdentifier):\(windowNumber(target.container) ?? -1):\(Int(target.frame.midX)): \(Int(target.frame.midY))"
        guard key != lastSnappedTarget else { return }
        // Accessibility frames and CGWarpMouseCursorPosition both use Quartz's
        // global display coordinate space (origin at the upper-left).
        guard CGWarpMouseCursorPosition(CGPoint(x: target.frame.midX, y: target.frame.midY)) == .success else { return }
        lastSnappedTarget = key
    }

    /// Sheets often expose their default control from the focused UI element's
    /// top-level element rather than the application's focused window. Search
    /// those first, then the app's visible windows as an AppKit fallback.
    private func defaultButtonTarget(in application: AXUIElement) -> (container: AXUIElement, frame: CGRect)? {
        var candidates: [AXUIElement] = []
        if let focusedWindow = accessibilityElement(application, attribute: kAXFocusedWindowAttribute) {
            candidates.append(focusedWindow)
        }
        if let focusedElement = accessibilityElement(application, attribute: "AXFocusedUIElement") {
            candidates.append(focusedElement)
            if let topLevel = accessibilityElement(focusedElement, attribute: "AXTopLevelUIElement") {
                candidates.append(topLevel)
            }
            if let window = accessibilityElement(focusedElement, attribute: "AXWindow") {
                candidates.append(window)
            }
        }
        candidates.append(contentsOf: accessibilityElements(application, attribute: "AXWindows"))

        for candidate in candidates {
            guard let button = accessibilityElement(candidate, attribute: kAXDefaultButtonAttribute),
                  let frame = accessibilityFrame(button) else { continue }
            return (candidate, frame)
        }
        return nil
    }

    private func accessibilityElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func accessibilityElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AnyObject] else { return [] }
        return elements.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(item, to: AXUIElement.self)
        }
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let value else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var frame = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &frame) ? frame : nil
    }

    private func windowNumber(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value) == .success,
              let value else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func controlChanged(_ controlIsPressed: Bool) {
        if controlIsPressed && !controlWasPressed && settings.active.showLocationWithControl {
            // Read the AppKit global pointer location on the main run loop; it is not tied to window focus.
            showLocator(at: NSEvent.mouseLocation)
        }
        controlWasPressed = controlIsPressed
    }

    private func recordPointerLocation() {
        guard settings.active.displayTrails else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDrawTime) >= sampleInterval else { return }
        let point = NSEvent.mouseLocation
        defer { lastPoint = point; lastDrawTime = now }
        guard let previousPoint = lastPoint else { return }
        let distance = hypot(point.x - previousPoint.x, point.y - previousPoint.y)
        guard distance > 1.5, let overlay = overlays.first(where: { $0.frame.contains(previousPoint) }), let view = overlay.contentView as? TrailOverlayView else { return }
        let lifetime = 0.14 + settings.active.trailLength * 0.035
        view.addPointer(at: CGPoint(x: previousPoint.x - overlay.frame.minX, y: previousPoint.y - overlay.frame.minY), lifetime: lifetime)
    }

    private func showLocator(at point: CGPoint) {
        guard let overlay = overlays.first(where: { $0.frame.contains(point) }), let view = overlay.contentView as? TrailOverlayView else { return }
        view.showLocator(at: CGPoint(x: point.x - overlay.frame.minX, y: point.y - overlay.frame.minY))
    }
}

@MainActor
final class SettingsPanelController {
    private let panel: NSPanel

    init(store: SettingsStore) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 455), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "🖱 Mouse Properties"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: PointerOptionsView(store: store, close: { [weak panel] in panel?.close() }))
    }

    func show() { panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

}

struct PointerOptionsView: View {
    @ObservedObject var store: SettingsStore
    let close: () -> Void

    private func binding<T>(_ keyPath: WritableKeyPath<TrailSettings, T>) -> Binding<T> {
        Binding(get: { store.draft[keyPath: keyPath] }, set: { store.draft[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowsTabBar()
            VStack(spacing: 8) {
                WindowsSection("Motion") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "cursorarrow.motionlines").font(.system(size: 24)).foregroundStyle(.secondary).frame(width: 42, height: 59)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Select a pointer speed:")
                            speedSlider(label: "Slow", value: binding(\.pointerSpeed), range: 1...11, trailing: "Fast", onChange: store.applyPointerSpeed)
                            Toggle("Enhance pointer precision", isOn: binding(\.enhancePrecision))
                        }
                    }
                }

                WindowsSection("Snap To") {
                    HStack(spacing: 10) {
                        SnapToIcon().frame(width: 42, height: 32)
                        Toggle(isOn: binding(\.snapToDefaultButton)) {
                            Text("Automatically move pointer to the default\nbutton in a dialog box")
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The 58 px border maps from the 76 px Windows reference box;
                // include the section's 5 px inter-section gap outside the border.
                .frame(height: 63)

                WindowsSection("Visibility") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            PointerTrailIcon().frame(width: 42, height: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Display pointer trails", isOn: binding(\.displayTrails))
                                speedSlider(label: "Short", value: binding(\.trailLength), range: 1...20, trailing: "Long")
                                    .disabled(!store.draft.displayTrails)
                            }
                        }
                        HStack(spacing: 10) { TypingHideIcon().frame(width: 42, height: 42); Toggle("Hide pointer while typing", isOn: binding(\.hidePointerWhileTyping)).onChange(of: store.draft.hidePointerWhileTyping) { _ in store.applyHidePointerWhileTyping() } }
                        HStack(spacing: 10) { PointerLocationIcon().frame(width: 42, height: 36); Toggle("Show location of pointer when I press the Control key", isOn: binding(\.showLocationWithControl)) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer(minLength: 0)
            Divider().opacity(0.45)
            MadeWithLoveFooter()
            HStack { Spacer(); Button("Reset") { store.reset() }.frame(width: 68); Button("Cancel") { store.cancel(); close() }.frame(width: 68); Button("Apply") { store.apply() }.frame(width: 68).keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
        }
        .font(.system(size: 12))
        .frame(width: 400, height: 455)
    }

    private func speedSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, trailing: String, onChange: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            Text(label).frame(width: 31, alignment: .leading)
            Slider(value: value, in: range, step: 1).frame(width: 132)
            Text(trailing).frame(width: 35, alignment: .trailing)
        }
        .onChange(of: value.wrappedValue) { _ in onChange?() }
    }
}

private struct WindowsTabBar: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Pointer Options").font(.system(size: 12)).padding(.horizontal, 9).frame(height: 25)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            Spacer()
        }
        .padding(.leading, 9)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 0.5) }
    }
}

private struct WindowsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.6)
            content.padding(.horizontal, 9).padding(.top, 13).padding(.bottom, 8)
            Text(title).padding(.horizontal, 3).font(.system(size: 12)).background(Color(nsColor: .windowBackgroundColor)).offset(x: 7, y: -8)
        }
        .padding(.top, 5)
    }
}

private struct PointerTrailIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "cursorarrow").offset(x: -9, y: 4).opacity(0.20)
            Image(systemName: "cursorarrow").offset(x: -5, y: 2).opacity(0.38)
            Image(systemName: "cursorarrow").offset(x: -1, y: 0).opacity(0.60)
            Image(systemName: "cursorarrow").offset(x: 3, y: -2)
        }
        .font(.system(size: 19))
        .foregroundStyle(.secondary)
    }
}

private struct SnapToIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: .controlBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 1.5).stroke(.secondary.opacity(0.65), lineWidth: 1)).frame(width: 24, height: 19).offset(x: -4, y: -3)
            Image(systemName: "cursorarrow").font(.system(size: 17)).foregroundStyle(.secondary).offset(x: 8, y: 8)
        }
    }
}

private struct TypingHideIcon: View {
    var body: some View {
        Canvas { context, _ in
            // The reference is a wide, low dialog—not a tall card.
            context.stroke(Path(CGRect(x: 2, y: 5, width: 30, height: 19)), with: .color(.secondary.opacity(0.7)), lineWidth: 1.45)
            // Equal inset on each opposing edge: 6 pt horizontal, 4 pt vertical.
            context.fill(Path(CGRect(x: 8, y: 9, width: 18, height: 11)), with: .color(.secondary.opacity(0.28)))

            // A 17 pt cursorarrow-shaped silhouette, drawn only as a dotted
            // outline. Its dimensions and angle match the Snap To cursor.
            var cursor = Path()
            cursor.move(to: CGPoint(x: 27, y: 19))
            cursor.addLine(to: CGPoint(x: 27, y: 35))
            cursor.addLine(to: CGPoint(x: 30.4, y: 31))
            cursor.addLine(to: CGPoint(x: 34.7, y: 38))
            cursor.addLine(to: CGPoint(x: 37.2, y: 36))
            cursor.addLine(to: CGPoint(x: 33, y: 29))
            cursor.addLine(to: CGPoint(x: 38.9, y: 29))
            cursor.closeSubpath()
            context.stroke(cursor, with: .color(.secondary.opacity(0.78)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [0.7, 2.2]))
        }
    }
}

private struct PointerLocationIcon: View {
    var body: some View {
        ZStack {
            Canvas { context, _ in
            // In the Windows artwork all three circles meet at the arrow's hot
            // spot. Keeping one explicit point avoids the SF Symbol's inset tip.
            let tip = CGPoint(x: 20, y: 18)
            for diameter in [25.0, 19.0, 13.0] {
                let rect = CGRect(x: tip.x - diameter / 2, y: tip.y - diameter / 2, width: diameter, height: diameter)
                context.stroke(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.64)), lineWidth: 1.35)
            }
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 18))
                .foregroundStyle(.secondary.opacity(0.78))
                // At 18 pt the Symbol has a 15×21 layout box and its visible
                // tip is inset by 2×3 pt. This puts that tip at (20, 18).
                .offset(x: 4.5, y: 7.5)
        }
    }
}

private struct MadeWithLoveFooter: View {
    var body: some View {
        VStack(spacing: 4) {
            (Text("Made with <3 by ")
                .foregroundColor(.secondary.opacity(0.65))
             + Text("aspauldingcode")
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
             + Text(" · MIT")
                .foregroundColor(.secondary.opacity(0.65)))
                .font(.system(size: 11))

            HStack(spacing: 0) {
                footerLink("Source", "https://github.com/aspauldingcode/TrailPoint")
                Text(" · ").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                footerLink("Ko-fi", "https://ko-fi.com/aspauldingcode")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func footerLink(_ title: String, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        } label: {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(urlString)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var trail = MouseTrailController(settings: settings)
    private lazy var preferences = SettingsPanelController(store: settings)
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(activateExistingInstance), name: .trailPointActivate, object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "TrailPoint")
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "Pause TrailPoint", action: #selector(toggleTrail), keyEquivalent: "")
        toggleItem.target = self
        let options = menu.addItem(withTitle: "Pointer Options…", action: #selector(showOptions), keyEquivalent: "")
        options.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit TrailPoint", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        statusItem.menu = menu
        trail.start()
        showOptions()
    }

    func applicationWillTerminate(_ notification: Notification) { trail.stop() }
    @objc private func toggleTrail() { if trail.isRunning { trail.stop(); toggleItem.title = "Start TrailPoint" } else { trail.start(); toggleItem.title = "Pause TrailPoint" } }
    @objc private func showOptions() { preferences.show() }
    @objc private func activateExistingInstance(_ notification: Notification) { showOptions() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

private extension Notification.Name {
    static let trailPointActivate = Notification.Name("com.trailpoint.app.activate-existing-instance")
}

@main
struct TrailPointMain {
    @MainActor private static let delegate = AppDelegate()

    @MainActor static func main() {
        guard SingleInstanceLock.shared.acquire() else {
            DistributedNotificationCenter.default().post(name: .trailPointActivate, object: nil)
            return
        }
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
