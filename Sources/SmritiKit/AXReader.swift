import Foundation
import AppKit
import ApplicationServices

/// Reads text from the frontmost application's focused window using the
/// macOS Accessibility API. Text only — no screenshots, no recording.
public enum AXReader {

    struct WindowCapture {
        let bundleId: String
        let appName: String
        let windowTitle: String
        let content: String
        /// Page URL when the frontmost app is a browser; "" otherwise.
        let url: String
    }

    /// Prompts the user for Accessibility permission if not yet granted.
    public static func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Capture the frontmost app's focused window. Returns nil when there is
    /// nothing meaningful to capture.
    static func captureFrontmost() -> WindowCapture? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        guard let window = copyAttribute(appElement, kAXFocusedWindowAttribute) else {
            return nil
        }
        let windowElement = window as! AXUIElement

        let title = (copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        let url = BrowserURL.url(bundleId: bundleId, window: windowElement) ?? ""

        var lines: [String] = []
        var budget = 50_000 // character budget while walking the tree
        collectText(windowElement, depth: 0, into: &lines, budget: &budget)

        let content = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        return WindowCapture(
            bundleId: bundleId,
            appName: app.localizedName ?? bundleId,
            windowTitle: title,
            content: content,
            url: url
        )
    }

    // MARK: - Tree walking

    private static let textBearingRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
        "AXLink", "AXHeading", "AXCell", "AXMenuItem", "AXButton",
    ]

    private static func collectText(
        _ element: AXUIElement,
        depth: Int,
        into lines: inout [String],
        budget: inout Int
    ) {
        guard depth < 40, budget > 0 else { return }

        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""

        if textBearingRoles.contains(role) {
            if let value = copyAttribute(element, kAXValueAttribute) as? String,
               !value.isEmpty {
                append(value, to: &lines, budget: &budget)
            } else if let title = copyAttribute(element, kAXTitleAttribute) as? String,
                      !title.isEmpty, role != kAXButtonRole {
                append(title, to: &lines, budget: &budget)
            }
        }

        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return }
        for child in children {
            guard budget > 0 else { return }
            collectText(child, depth: depth + 1, into: &lines, budget: &budget)
        }
    }

    private static func append(_ text: String, to lines: inout [String], budget: inout Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = String(trimmed.prefix(budget))
        lines.append(clipped)
        budget -= clipped.count
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }
}
