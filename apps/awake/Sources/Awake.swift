import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import ServiceManagement

@MainActor
final class AwakeDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var assertion: IOPMAssertionID = 0
    private var assertionHeld = false
    private var sleeping = false
    private var displaysSleeping = false
    private var sessionActive = true
    private var timer: Timer?
    private var lastJiggle = Date.distantPast
    private var powerError: String?
    private var jiggleActivity: NSObjectProtocol?
    private var keepAwake: Bool { defaults.bool(forKey: "keepAwake") }
    private var jiggle: Bool { defaults.bool(forKey: "jiggle") }
    // CGPreflightPostEventAccess caches its answer per process, so it stays false after the
    // user grants access; AXIsProcessTrusted reads the live state and needs no restart.
    private var canPostEvents: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }
    private var interval: Double { defaults.double(forKey: "interval") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["keepAwake": true, "jiggle": false, "interval": 60.0])
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(displaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        updatePower()
        updateJiggleActivity()
        let installedPaths = ["/Applications/Awake.app", NSHomeDirectory() + "/Applications/Awake.app"]
        if !defaults.bool(forKey: "loginInitialized"), installedPaths.contains(Bundle.main.bundlePath) {
            defaults.set(true, forKey: "loginInitialized")
            do {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
            } catch { showError("Launch at Login", error.localizedDescription) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        releasePower()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func releasePower() {
        if assertionHeld { IOPMAssertionRelease(assertion) }
        assertionHeld = false
    }

    private func updatePower() {
        powerError = nil
        if !keepAwake || sleeping {
            releasePower()
        } else if !assertionHeld {
            // Display-idle prevention also prevents idle system sleep.
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Awake: keep Mac and displays awake" as CFString, &assertion)
            assertionHeld = result == kIOReturnSuccess
            if !assertionHeld { powerError = "Keep Awake failed (\(result)). Toggle it to retry." }
        }
        statusItem.button?.image = NSImage(systemSymbolName: assertionHeld ? "sun.max.fill" : "moon", accessibilityDescription: "Awake")
        statusItem.button?.toolTip = powerError ?? (assertionHeld ? "Awake — Keep Awake is on" : "Awake — Keep Awake is off")
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            defer { statusItem.menu = nil }
            statusItem.button?.performClick(nil)
        } else {
            toggleAwake()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = menu.addItem(withTitle: "Awake", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        add(menu, "Keep Awake", #selector(toggleAwake), checked: keepAwake)
        add(menu, "Mouse Jiggle", #selector(toggleJiggle), checked: jiggle)
        if jiggle && !canPostEvents {
            let notice = menu.addItem(withTitle: "Mouse Jiggle needs Accessibility permission", action: nil, keyEquivalent: "")
            notice.isEnabled = false
            add(menu, "Grant Accessibility Permission…", #selector(grantPermission))
        }
        let intervalItem = menu.addItem(withTitle: "Jiggle Interval", action: nil, keyEquivalent: "")
        let intervals = NSMenu()
        for seconds in [30, 60, 120, 300] {
            let item = add(intervals, seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute\(seconds == 60 ? "" : "s")", #selector(setInterval), checked: interval == Double(seconds))
            item.tag = seconds
        }
        intervalItem.submenu = intervals
        menu.addItem(.separator())
        add(menu, "Launch at Login", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        if SMAppService.mainApp.status == .requiresApproval {
            add(menu, "Approve Login Item…", #selector(openLoginSettings))
        }
        if let powerError {
            let error = menu.addItem(withTitle: powerError, action: nil, keyEquivalent: "")
            error.isEnabled = false
        }
        add(menu, "About Awake…", #selector(about))
        menu.addItem(.separator())
        add(menu, "Quit Awake", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggleAwake() { defaults.set(!keepAwake, forKey: "keepAwake"); updatePower() }
    @objc private func toggleJiggle() {
        defaults.set(!jiggle, forKey: "jiggle")
        lastJiggle = Date()
        if jiggle && !canPostEvents { _ = CGRequestPostEventAccess() }
        updateJiggleActivity()
    }
    // Without this, App Nap throttles the background timer that drives the jiggle.
    private func updateJiggleActivity() {
        if jiggle, jiggleActivity == nil {
            jiggleActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Awake: Mouse Jiggle")
        } else if !jiggle, let activity = jiggleActivity {
            ProcessInfo.processInfo.endActivity(activity)
            jiggleActivity = nil
        }
    }
    @objc private func setInterval(_ item: NSMenuItem) { defaults.set(Double(item.tag), forKey: "interval"); lastJiggle = Date() }
    @objc private func grantPermission() {
        _ = CGRequestPostEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func toggleLogin() {
        defaults.set(true, forKey: "loginInitialized")
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { openLoginSettings() }
            }
        } catch { showError("Launch at Login", error.localizedDescription) }
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func willSleep() { sleeping = true; updatePower() }
    @objc private func didWake() { sleeping = false; lastJiggle = Date(); updatePower() }
    @objc private func displaySleep() { displaysSleeping = true }
    @objc private func displayWake() { displaysSleeping = false; lastJiggle = Date() }
    @objc private func sessionResigned() { sessionActive = false }
    @objc private func sessionActivated() { sessionActive = true; lastJiggle = Date() }

    @objc private func tick() {
        guard jiggle, !sleeping, !displaysSleeping, sessionActive,
              canPostEvents, Date().timeIntervalSince(lastJiggle) >= interval,
              // ~0 is kCGAnyInputEventType; .null would measure time since the last null event.
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) >= interval,
              NSEvent.pressedMouseButtons == 0,
              let location = CGEvent(source: nil)?.location else { return }
        // Keep the nudge within the display containing the pointer, including monitors
        // with negative coordinates. No clicks, keystrokes, or delayed return that
        // could overwrite a real user's movement.
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return }
        let bounds = CGDisplayBounds(display)
        let nudge = CGPoint(x: location.x + (location.x + 1 < bounds.maxX ? 1 : -1), y: location.y)
        guard let out = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nudge, mouseButton: .left),
              let back = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left) else { return }
        out.post(tap: .cghidEventTap)
        back.post(tap: .cghidEventTap)
        lastJiggle = Date()
    }

    private func showError(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
    @objc private func about() {
        showError("Awake 0.1", "One switch keeps your Mac and connected displays awake. Mouse Jiggle is independent. Settings are stored locally. No network access or telemetry.\n\nIdle-sleep prevention does not override deliberate sleep, a depleted battery, or unsupported closed-lid configurations.")
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct AwakeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AwakeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
