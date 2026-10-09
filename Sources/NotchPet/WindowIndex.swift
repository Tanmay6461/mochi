import AppKit
import ApplicationServices

/// One on-screen (or minimized) window of a regular app, found through the Accessibility API.
struct WindowRef: Identifiable {
    let id = UUID()
    let pid: pid_t
    let appName: String
    let title: String
    let element: AXUIElement
}

/// Lists and raises other apps' windows. Needs Accessibility permission.
enum WindowIndex {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Walks every regular app's windows. Slow apps are cut off by a short AX timeout.
    /// Safe to call off the main thread; pass in the apps gathered on main.
    static func snapshot(of apps: [(pid: pid_t, name: String)]) -> [WindowRef] {
        guard isTrusted else { return [] }
        var result: [WindowRef] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard let windows: [AXUIElement] = copy(axApp, kAXWindowsAttribute) else { continue }
            for window in windows {
                guard let title: String = copy(window, kAXTitleAttribute), !title.isEmpty else { continue }
                result.append(WindowRef(pid: app.pid, appName: app.name, title: title, element: window))
            }
        }
        return result
    }

    /// Brings one window to the front (un-minimizing it if needed) along with its app.
    static func raise(_ window: WindowRef) {
        if let minimized: Bool = copy(window.element, kAXMinimizedAttribute), minimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        activate(pid: window.pid)
    }

    /// Activates an app. Goes through AX because a background accessory app's
    /// NSRunningApplication.activate() request can be refused by cooperative activation.
    static func activate(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        if AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Does this window title mention the project folder as a whole word? ("App" must not match "Apple")
    static func title(_ title: String, mentions project: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: project)
        let pattern = "(^|[^A-Za-z0-9_-])\(escaped)($|[^A-Za-z0-9_-])"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
