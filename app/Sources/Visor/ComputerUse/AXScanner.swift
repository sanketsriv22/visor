import AppKit
import ApplicationServices

/// Reads the macOS Accessibility tree of an app and lets us act on real UI
/// elements — the advantage Anthropic's and OpenAI's computer-use tools don't
/// have, because they run against a screenshot in a VM. Visor runs natively
/// with Accessibility permission, so instead of *guessing* where a button is
/// from pixels (which is what makes a vision-only agent click-loop), we read the
/// exact element and its exact frame, and can press it or set its value by
/// reference — no coordinate guessing.
///
/// Everything here is synchronous AX messaging; a per-app timeout keeps an
/// unresponsive target from hanging us.
enum AXScanner {
    /// One interactive element: what it is, its best human label, its current
    /// value (for fields), where it is on screen, and the live reference we use
    /// to act on it.
    struct Node {
        let id: Int
        let role: String
        let label: String
        let value: String?
        let frame: CGRect          // global, top-left origin — DesktopActuator's space
        let element: AXUIElement
        let actions: [String]

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        var pressable: Bool { actions.contains("AXPress") }
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// The interactive elements of an app's focused window (falling back to the
    /// whole app), numbered for the model to pick from.
    static func snapshot(pid: pid_t, limit: Int = 110) -> [Node] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        // Electron/Chromium apps (Slack, VS Code, Discord, Chrome…) build their
        // accessibility tree lazily, only once a client asks. Without this flag
        // their element list comes back empty — which is exactly the apps we
        // care about. Setting it coaxes them into exposing the tree.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let root: AXUIElement = (copy(app, kAXFocusedWindowAttribute as String)
            .map { $0 as! AXUIElement }) ?? app
        var out: [Node] = []
        var counter = 0
        var visited = 0
        walk(root, out: &out, counter: &counter, visited: &visited, limit: limit)
        return out
    }

    // MARK: Actions

    /// Press an element by reference — a button, link, menu item. No mouse
    /// movement, and it works even for something just off-screen. Returns
    /// whether the AX press was available; callers fall back to a click.
    @discardableResult
    static func press(_ node: Node) -> Bool {
        guard node.pressable else { return false }
        return AXUIElementPerformAction(node.element, "AXPress" as CFString) == .success
    }

    /// Set focus on an element (so typing lands in it).
    @discardableResult
    static func focus(_ node: Node) -> Bool {
        AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString,
                                     kCFBooleanTrue) == .success
    }

    // MARK: Tree walk

    private static let interesting: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField",
        "AXCheckBox", "AXRadioButton", "AXLink", "AXTabButton", "AXDisclosureTriangle",
        "AXCell", "AXOutlineRow", "AXSlider", "AXIncrementor", "AXStepper", "AXSegment",
    ]

    private static func walk(_ el: AXUIElement, out: inout [Node],
                             counter: inout Int, visited: inout Int, limit: Int) {
        if out.count >= limit || visited > 6000 { return }
        visited += 1

        let role = str(el, kAXRoleAttribute as String) ?? ""
        if let node = node(from: el, role: role, id: counter) {
            out.append(node)
            counter += 1
        }
        if let children = copy(el, kAXChildrenAttribute as String) as? [AXUIElement] {
            for child in children {
                if out.count >= limit { break }
                walk(child, out: &out, counter: &counter, visited: &visited, limit: limit)
            }
        }
    }

    private static func node(from el: AXUIElement, role: String, id: Int) -> Node? {
        let acts = actions(el)
        // Keep it if it's a role we care about, or anything that can be pressed.
        guard interesting.contains(role) || acts.contains("AXPress") else { return nil }
        // Enabled and on-screen only.
        if let enabled = copy(el, kAXEnabledAttribute as String) as? Bool, !enabled { return nil }
        guard let frame = frame(el), frame.width > 3, frame.height > 3 else { return nil }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flip(frame)) }) else { return nil }

        let value = str(el, kAXValueAttribute as String)
        let label = bestLabel(el, role: role, value: value)
        // Drop unlabeled, unpressable filler (containers that slipped through).
        if label.isEmpty, value == nil, !acts.contains("AXPress") { return nil }

        return Node(id: id, role: role, label: label,
                    value: (value?.isEmpty == false) ? value : nil,
                    frame: frame, element: el, actions: acts)
    }

    private static func bestLabel(_ el: AXUIElement, role: String, value: String?) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                     "AXPlaceholderValue", kAXRoleDescriptionAttribute] as [String] {
            if let s = str(el, attr), !s.isEmpty { return trim(s) }
        }
        // A text field with no title is worth showing by its value or role.
        if let value, !value.isEmpty, value.count < 60 { return trim(value) }
        return ""
    }

    // MARK: AX plumbing

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    private static func str(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    private static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(el, &names) == .success ? (names as? [String] ?? []) : []
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posVal = copy(el, kAXPositionAttribute as String),
              let sizeVal = copy(el, kAXSizeAttribute as String) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// AX frames are top-left origin; NSScreen.frame is bottom-left. Flip so the
    /// on-screen test compares like with like.
    private static func flip(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let maxY = primary.frame.maxY
        return CGRect(x: rect.minX, y: maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 70 ? String(t.prefix(70)) + "…" : t
    }
}
