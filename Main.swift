import AppKit
import QuartzCore
import SwiftUI
import Darwin

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
    }

    func cancel() { draft = active }
    func reset() { draft = TrailSettings() }

    /// `com.apple.mouse.scaling` is the tracking-speed value used by macOS Mouse settings.
    /// Starting with Sonoma, `com.apple.mouse.linear` controls the Advanced pointer-acceleration switch.
    private func applyMacMouseSettings(_ settings: TrailSettings) {
        let scaling = 0.125 + ((settings.pointerSpeed - 1) / 10) * 2.875
        runDefaults(["write", "NSGlobalDomain", "com.apple.mouse.scaling", "-float", String(format: "%.4f", scaling)])
        // A linear pointer is macOS terminology for acceleration being disabled.
        runDefaults(["write", "NSGlobalDomain", "com.apple.mouse.linear", "-bool", settings.enhancePrecision ? "false" : "true"])
    }

    private func loadMacMouseSettings(into settings: inout TrailSettings) {
        if let scaling = readDefaults("com.apple.mouse.scaling"), let value = Double(scaling) {
            settings.pointerSpeed = min(11, max(1, 1 + ((value - 0.125) / 2.875) * 10))
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
        let image = NSCursor.arrow.image
        let size = image.size
        let pointer = CALayer()
        pointer.contents = image
        pointer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        pointer.frame = CGRect(x: point.x - 1, y: point.y - size.height + 1, width: size.width, height: size.height)
        // Windows keeps every ghost at a constant translucency, then removes it at once.
        pointer.opacity = 0.46
        layer?.addSublayer(pointer)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { pointer.removeFromSuperlayer() }
    }

    func showLocator(at point: CGPoint) {
        for index in 0 ..< 3 {
            let ring = CAShapeLayer()
            let diameter: CGFloat = 30 + CGFloat(index) * 25
            // A self-contained layer makes the contraction pivot exactly at the captured cursor point.
            ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ring.position = point
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = NSColor.controlAccentColor.cgColor
            ring.lineWidth = 2.5
            ring.shadowColor = NSColor.black.cgColor
            ring.shadowOpacity = 0.28
            ring.shadowRadius = 2
            layer?.addSublayer(ring)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.95
            fade.toValue = 0
            let contract = CABasicAnimation(keyPath: "transform.scale")
            contract.fromValue = 2.1
            contract.toValue = 0.08
            let group = CAAnimationGroup()
            group.animations = [fade, contract]
            group.duration = 0.46
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.10
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.add(group, forKey: "controlLocator")
            CATransaction.commit()
        }
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
    nonisolated(unsafe) private var baseSensitivity: CGFloat = 1
    nonisolated(unsafe) private var remappedPointerPosition: CGPoint?
    private let sampleInterval: TimeInterval = 1.0 / 60.0
    var isRunning = false

    init(settings: SettingsStore) {
        self.settings = settings
        updateSensitivity(settings.active)
        settings.onApply = { [weak self] value in self?.updateSensitivity(value) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildOverlays()
        overlays.forEach { $0.orderFrontRegardless() }
        installEventTap()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown]
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
        if event.type == .keyDown && settings.active.hidePointerWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            recordPointerLocation()
        }
    }

    private func updateSensitivity(_ value: TrailSettings) {
        let speed = value.pointerSpeed
        // Windows' 6/11 setting is neutral (1:1); the endpoints are 0.25× and 2.25×.
        baseSensitivity = speed <= 6
            ? 0.25 + (speed - 1) * 0.15
            : 1 + (speed - 6) * 0.25
        remappedPointerPosition = nil
    }

    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
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
            } else {
                controller.applyBaseSensitivity(to: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func controlChanged(_ controlIsPressed: Bool) {
        if controlIsPressed && !controlWasPressed && settings.active.showLocationWithControl {
            // Read the AppKit global pointer location on the main run loop; it is not tied to window focus.
            showLocator(at: NSEvent.mouseLocation)
        }
        controlWasPressed = controlIsPressed
    }

    nonisolated private func applyBaseSensitivity(to event: CGEvent) {
        let incoming = event.location
        guard baseSensitivity != 1 else { remappedPointerPosition = incoming; return }
        let current = remappedPointerPosition ?? incoming
        let deltaX = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
        let deltaY = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
        let next = CGPoint(x: current.x + deltaX * baseSensitivity, y: current.y + deltaY * baseSensitivity)
        remappedPointerPosition = next
        event.location = next
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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 455), styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Mouse Properties"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
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
            WindowsTitleBar()
            WindowsTabBar()
            VStack(spacing: 8) {
                WindowsSection("Motion") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "cursorarrow.motionlines").font(.system(size: 24)).foregroundStyle(.secondary).frame(width: 42, height: 59)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Select a pointer speed:")
                            speedSlider(label: "Slow", value: binding(\.pointerSpeed), range: 1...11, trailing: "Fast")
                            Toggle("Enhance pointer precision", isOn: binding(\.enhancePrecision))
                        }
                    }
                }

                WindowsSection("Snap To") {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 42, height: 42)
                        Toggle("Automatically move pointer to the default button in a\ndialog box", isOn: binding(\.snapToDefaultButton))
                    }
                }

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
                        HStack(spacing: 10) { Image(systemName: "keyboard").font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 42); Toggle("Hide pointer while typing", isOn: binding(\.hidePointerWhileTyping)) }
                        HStack(spacing: 10) { Image(systemName: "scope").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 42); Toggle("Show location of pointer when I press the Control key", isOn: binding(\.showLocationWithControl)) }
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

    private func speedSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, trailing: String) -> some View {
        HStack(spacing: 5) {
            Text(label).frame(width: 31, alignment: .leading)
            Slider(value: value, in: range, step: 1).frame(width: 132)
            Text(trailing).frame(width: 27, alignment: .trailing)
        }
    }
}

private struct WindowsTitleBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "computermouse.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            Text("Mouse Properties").font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.leading, 44)
        .padding(.trailing, 12)
        .frame(height: 31)
        .background(.bar)
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
        toggleItem = menu.addItem(withTitle: "Stop Trail", action: #selector(toggleTrail), keyEquivalent: "")
        toggleItem.target = self
        let options = menu.addItem(withTitle: "Pointer Options…", action: #selector(showOptions), keyEquivalent: ",")
        options.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit TrailPoint", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        trail.start()
        showOptions()
    }

    func applicationWillTerminate(_ notification: Notification) { trail.stop() }
    @objc private func toggleTrail() { if trail.isRunning { trail.stop(); toggleItem.title = "Start Trail" } else { trail.start(); toggleItem.title = "Stop Trail" } }
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
