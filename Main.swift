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
    var pointerSpeed = 5.0
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
    }

    func cancel() { draft = active }
    func reset() { draft = TrailSettings() }

    /// `com.apple.mouse.scaling` is the tracking-speed value used by macOS Mouse settings.
    /// Starting with Sonoma, `com.apple.mouse.linear` controls the Advanced pointer-acceleration switch.
    private func applyMacMouseSettings(_ settings: TrailSettings) {
        let scaling = 0.125 + ((settings.pointerSpeed - 1) / 9) * 2.875
        runDefaults(["write", "NSGlobalDomain", "com.apple.mouse.scaling", "-float", String(format: "%.4f", scaling)])
        // A linear pointer is macOS terminology for acceleration being disabled.
        runDefaults(["write", "NSGlobalDomain", "com.apple.mouse.linear", "-bool", settings.enhancePrecision ? "false" : "true"])
    }

    private func loadMacMouseSettings(into settings: inout TrailSettings) {
        if let scaling = readDefaults("com.apple.mouse.scaling"), let value = Double(scaling) {
            settings.pointerSpeed = min(10, max(1, 1 + ((value - 0.125) / 2.875) * 9))
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
    private let sampleInterval: TimeInterval = 1.0 / 60.0
    var isRunning = false

    init(settings: SettingsStore) { self.settings = settings }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildOverlays()
        overlays.forEach { $0.orderFrontRegardless() }
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
            let controlIsPressed = event.modifierFlags.contains(.control)
            if controlIsPressed && !controlWasPressed && settings.active.showLocationWithControl { showLocator(at: location) }
            controlWasPressed = controlIsPressed
        } else if event.type == .keyDown && settings.active.hidePointerWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            recordPointerLocation()
        }
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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 550, height: 575), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "TrailPoint — Pointer Options"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
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
        VStack(spacing: 10) {
            GroupBox("Motion") {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 31)).foregroundStyle(.secondary).frame(width: 58, height: 72)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Select a pointer speed:")
                        HStack(spacing: 8) { Text("Slow").frame(width: 34, alignment: .leading); Slider(value: binding(\.pointerSpeed), in: 1...10, step: 1).frame(width: 210); Text("Fast").frame(width: 30, alignment: .trailing) }
                        Toggle("Enhance pointer precision", isOn: binding(\.enhancePrecision))
                    }
                    Spacer(minLength: 0)
                }.padding(7)
            }.frame(maxWidth: .infinity)

            GroupBox("Snap To") {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 27)).foregroundStyle(.secondary).frame(width: 58, height: 45)
                    Toggle("Automatically move pointer to the default button in a\ndialog box", isOn: binding(\.snapToDefaultButton))
                    Spacer(minLength: 0)
                }.padding(7)
            }.frame(maxWidth: .infinity)

            GroupBox("Visibility") {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "cursorarrow.motionlines").font(.system(size: 27)).foregroundStyle(.secondary).frame(width: 58, height: 57)
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Display pointer trails", isOn: binding(\.displayTrails))
                            HStack(spacing: 8) { Text("Short").frame(width: 34, alignment: .leading); Slider(value: binding(\.trailLength), in: 1...20, step: 1).frame(width: 210).disabled(!store.draft.displayTrails); Text("Long").frame(width: 30, alignment: .trailing) }
                        }
                        Spacer(minLength: 0)
                    }
                    Divider()
                    HStack(spacing: 14) { Image(systemName: "keyboard").font(.system(size: 23)).foregroundStyle(.secondary).frame(width: 58); Toggle("Hide pointer while typing", isOn: binding(\.hidePointerWhileTyping)); Spacer(minLength: 0) }
                    Divider()
                    HStack(spacing: 14) { Image(systemName: "scope").font(.system(size: 27)).foregroundStyle(.secondary).frame(width: 58); Toggle("Show location of pointer when I press the Control key", isOn: binding(\.showLocationWithControl)); Spacer(minLength: 0) }
                }.padding(7)
            }.frame(maxWidth: .infinity)

            Spacer(minLength: 0)
            Divider().opacity(0.45)
            MadeWithLoveFooter()
            HStack { Spacer(); Button("Reset") { store.reset() }.frame(width: 88); Button("Cancel") { store.cancel(); close() }.frame(width: 88); Button("Apply") { store.apply() }.frame(width: 88).keyboardShortcut(.defaultAction) }
        }
        .padding(14)
        .frame(width: 550, height: 575)
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
