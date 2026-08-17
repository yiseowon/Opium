import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Screen/input control for the agent. Every tool here is gated behind the separate
/// "컴퓨터 사용" permission toggle (off by default, never auto-approved regardless of
/// the file-tool policy) because it can act on anything visible on screen, not just
/// the sandboxed file/terminal surface the rest of `FileTools` covers.
enum ComputerUse {
    static let toolNames: Set<String> = [
        "list_ui_elements", "click_ui_element", "take_screenshot", "click_at", "type_text", "press_key"
    ]

    // MARK: - Permissions

    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Execution

    struct Result {
        var text: String
        var imageBase64: String? = nil
    }

    static func run(_ call: PendingToolCall) async throws -> Result {
        let arguments = decodedArguments(call.arguments)
        switch call.name {
        case "list_ui_elements":
            guard hasAccessibilityAccess else { throw AgentError.message("접근성 권한이 없습니다. 설정에서 권한을 허용해 주세요.") }
            let app = try string("app", in: arguments)
            return Result(text: try listElements(appName: app))
        case "click_ui_element":
            guard hasAccessibilityAccess else { throw AgentError.message("접근성 권한이 없습니다. 설정에서 권한을 허용해 주세요.") }
            let app = try string("app", in: arguments)
            let query = try string("query", in: arguments)
            return Result(text: try clickElement(appName: app, query: query))
        case "take_screenshot":
            guard hasScreenRecordingAccess else { throw AgentError.message("화면 기록 권한이 없습니다. 설정에서 권한을 허용해 주세요.") }
            let (text, base64) = try await screenshot()
            return Result(text: text, imageBase64: base64)
        case "click_at":
            guard hasAccessibilityAccess else { throw AgentError.message("접근성 권한이 없습니다. 설정에서 권한을 허용해 주세요.") }
            guard let x = Double(arguments["x"] ?? ""), let y = Double(arguments["y"] ?? "") else {
                throw AgentError.message("x, y 좌표가 필요합니다.")
            }
            clickAt(x: x, y: y)
            return Result(text: "(\(Int(x)), \(Int(y)))을 클릭했습니다.")
        case "type_text":
            guard hasAccessibilityAccess else { throw AgentError.message("접근성 권한이 없습니다. 설정에서 권한을 허용해 주세요.") }
            let text = try string("text", in: arguments)
            typeText(text)
            return Result(text: "\(text.count)자를 입력했습니다.")
        case "press_key":
            guard hasAccessibilityAccess else { throw AgentError.message("접근성 권한이 없습니다. 설정에서 권한을 허용해 주세요.") }
            let key = try string("key", in: arguments)
            try pressKey(key)
            return Result(text: "\(key) 키를 눌렀습니다.")
        default:
            throw AgentError.message("지원하지 않는 컴퓨터 사용 도구입니다: \(call.name)")
        }
    }

    // MARK: - AXUIElement (structured control)

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink", "AXPopUpButton", "AXMenuButton"
    ]

    private static func runningApp(named name: String) throws -> NSRunningApplication {
        let lowered = name.lowercased()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased().contains(lowered)
        }) else { throw AgentError.message("실행 중인 앱을 찾지 못했습니다: \(name)") }
        return app
    }

    private struct FoundElement { let role: String; let title: String; let element: AXUIElement }

    private static func collectClickable(_ element: AXUIElement, depth: Int, into results: inout [FoundElement]) {
        guard depth < 6, results.count < 200 else { return }

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? ""

        if clickableRoles.contains(role) {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
            var descriptionValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descriptionValue)
            let title = (titleValue as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (descriptionValue as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let title { results.append(FoundElement(role: role, title: title, element: element)) }
        }

        var childrenValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        for child in (childrenValue as? [AXUIElement]) ?? [] {
            collectClickable(child, depth: depth + 1, into: &results)
        }
    }

    private static func windowElement(for app: NSRunningApplication) throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard let window = (windowsValue as? [AXUIElement])?.first else {
            throw AgentError.message("앱의 창을 찾지 못했습니다.")
        }
        return window
    }

    private static func listElements(appName: String) throws -> String {
        let app = try runningApp(named: appName)
        let window = try windowElement(for: app)
        var found: [FoundElement] = []
        collectClickable(window, depth: 0, into: &found)
        guard !found.isEmpty else { return "클릭 가능한 요소를 찾지 못했습니다." }
        return found.enumerated().map { "\($0.offset). [\($0.element.role)] \($0.element.title)" }.joined(separator: "\n")
    }

    private static func clickElement(appName: String, query: String) throws -> String {
        let app = try runningApp(named: appName)
        let window = try windowElement(for: app)
        var found: [FoundElement] = []
        collectClickable(window, depth: 0, into: &found)
        let lowered = query.lowercased()
        guard let match = found.first(where: { $0.title.lowercased().contains(lowered) }) else {
            throw AgentError.message("'\(query)'와 일치하는 요소를 찾지 못했습니다.")
        }
        let status = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        guard status == .success else { throw AgentError.message("클릭에 실패했습니다: \(match.title)") }
        return "'\(match.title)'을(를) 클릭했습니다."
    }

    // MARK: - Pixel-based control

    /// Captures at exactly the display's point resolution — the same coordinate space
    /// `click_at`/CGEvent use — so a coordinate the model reads off the image maps 1:1
    /// onto the real screen. Downscaling the image to save tokens breaks that mapping
    /// unless click_at also rescales, so this deliberately doesn't.
    private static func screenshot() async throws -> (String, String) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw AgentError.message("화면을 찾지 못했습니다.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw AgentError.message("화면을 캡처하지 못했습니다: \(error.localizedDescription)")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AgentError.message("스크린샷을 인코딩하지 못했습니다.")
        }
        return (
            "현재 화면을 캡처했습니다 (\(display.width)x\(display.height)). "
                + "이미지 속 좌표는 click_at의 x, y와 동일한 좌표계입니다 — 그대로 사용하세요.",
            png.base64EncodedString()
        )
    }

    private static func clickAt(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func typeText(_ text: String) {
        for scalar in text.utf16 {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar])
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar])
            up?.post(tap: .cghidEventTap)
        }
    }

    private static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    private static func pressKey(_ name: String) throws {
        guard let code = namedKeyCodes[name.lowercased()] else {
            throw AgentError.message("지원하지 않는 키입니다: \(name)")
        }
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Argument helpers

    private static func decodedArguments(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private static func string(_ key: String, in arguments: [String: String]) throws -> String {
        guard let value = arguments[key] else { throw AgentError.message("Missing argument: \(key)") }
        return value
    }
}
