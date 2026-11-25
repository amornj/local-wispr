import AppKit
import ApplicationServices

// The destination is captured before recording. No clipboard or paste command is used.
@MainActor
final class TextInsertion {
    enum Outcome { case confirmed, unverified }

    struct Snapshot {
        let value: String?
        let selection: CFRange?
    }

    struct Destination {
        let processID: pid_t
        let appName: String
        let element: AXUIElement
        let snapshot: Snapshot
    }

    enum ReplacementAttribute { case selectedText, value }
    enum ReplacementOutcome: Equatable { case confirmed, unchanged, uncertain }

    // Keep the replacement sequence testable without sending events to another app.
    struct ReplacementAccess {
        var canSet: (ReplacementAttribute) -> Bool
        var write: (ReplacementAttribute, String) -> Bool
        var read: () -> Snapshot
        var validateFocus: () throws -> Void
        var moveCaret: (Int) -> Void
    }

    var hasPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func capture() throws -> Destination {
        guard hasPermission else {
            throw WisprError.message("Allow Local Wispr in System Settings → Privacy & Security → Accessibility to insert text into other apps.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw WisprError.message("Click a text field in another app before holding Fn.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let element = focusedElement(in: application) else {
            throw WisprError.message("Click inside a text field before holding Fn.")
        }
        AXUIElementSetMessagingTimeout(element, 0.5)
        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        guard subrole != kAXSecureTextFieldSubrole else {
            throw WisprError.message("Dictation is unavailable in password fields.")
        }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              boolAttribute(kAXEnabledAttribute, of: element) != false else {
            throw WisprError.message("This app does not expose an editable text field. Click its text box and try again.")
        }
        return Destination(processID: app.processIdentifier, appName: app.localizedName ?? "the app",
                           element: element, snapshot: snapshot(of: element))
    }

    func insert(_ text: String, into destination: Destination) async throws -> Outcome {
        guard !text.isEmpty else { return .confirmed }
        guard hasPermission else {
            throw WisprError.message("Accessibility access is needed to insert the cleaned text.")
        }
        try validateFocus(destination)
        let before = snapshot(of: destination.element)
        let expected = Self.expectedValue(before: before, inserting: text)
        let element = destination.element
        let replacement = try await Self.replaceUsingAccessibility(text, before: before, access: ReplacementAccess(
            canSet: { attribute in
                var settable = DarwinBoolean(false)
                let name = attribute == .selectedText ? kAXSelectedTextAttribute : kAXValueAttribute
                return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
            },
            write: { attribute, value in
                let name = attribute == .selectedText ? kAXSelectedTextAttribute : kAXValueAttribute
                return AXUIElementSetAttributeValue(element, name as CFString, value as CFString) == .success
            },
            read: { self.snapshot(of: element) },
            validateFocus: { try self.validateFocus(destination) },
            moveCaret: { location in
                var caret = CFRange(location: location, length: 0)
                if let value = AXValueCreate(.cfRange, &caret) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
                }
            }
        ))
        switch replacement {
        case .confirmed: return .confirmed
        case .uncertain: throw unconfirmedError(destination)
        case .unchanged: break
        }
        // Browser and Electron editors often expose their selection as read-only.
        // Route individual Unicode characters through macOS's normal keyboard input path.
        guard !text.contains(where: { $0.isNewline }),
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw WisprError.message("This field does not support direct multiline insertion. Your formatted text is ready in Local Wispr.")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw WisprError.message("macOS could not create a typing event. Your cleaned text is still in Local Wispr.")
        }
        var sentText = false
        for chunk in Self.unicodeChunks(text) {
            do { try validateFocus(destination, checkSelection: !sentText) }
            catch {
                if sentText { throw WisprError.message("Focus changed before typing finished. Some text may have been inserted; the full result is still in Local Wispr.") }
                throw error
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw WisprError.message("macOS could not finish typing. Your full cleaned text is still in Local Wispr.")
            }
            down.flags = []; up.flags = []
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            sentText = true
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard expected != nil else { return .unverified }
        guard await waitForConfirmation(text, before: before, in: destination.element) else {
            throw unconfirmedError(destination)
        }
        return .confirmed
    }

    static func replaceUsingAccessibility(_ text: String, before: Snapshot, access: ReplacementAccess,
                                         pause: () async -> Void = { try? await Task.sleep(nanoseconds: 25_000_000) }) async throws -> ReplacementOutcome {
        guard let expected = expectedValue(before: before, inserting: text) else { return .unchanged }
        // SelectedText may be read-only or silently ignored by web editors while
        // Value works. Try both for sentences and lists, preserving surrounding text.
        // No Return events or clipboard paste commands are used for line breaks.
        for attribute in [ReplacementAttribute.selectedText, .value] where access.canSet(attribute) {
            try access.validateFocus()
            let accepted = access.write(attribute, attribute == .selectedText ? text : expected)
            for attempt in 0..<(accepted ? 20 : 1) {
                if confirms(text, before: before, after: access.read()) {
                    if attribute == .value, let selection = before.selection {
                        access.moveCaret(selection.location + text.utf16.count)
                    }
                    return .confirmed
                }
                if attempt < 19, accepted { await pause() }
            }
            // Never fall back after a partial edit or a changed cursor: that can
            // duplicate text or insert in the wrong position.
            guard isUnchanged(before, access.read()) else { return .uncertain }
        }
        return .unchanged
    }

    // A multi-character event can be dropped by web editors. Keep each scalar's
    // UTF-16 surrogate pair together; combining marks arrive in their original order.
    nonisolated static func unicodeChunks(_ text: String) -> [[UniChar]] {
        text.unicodeScalars.map { Array(String($0).utf16) }
    }

    nonisolated static func expectedValue(before: Snapshot, inserting text: String) -> String? {
        guard let value = before.value, let range = before.selection,
              range.location >= 0, range.length >= 0 else { return nil }
        let string = value as NSString
        guard range.location <= string.length, range.length <= string.length - range.location else { return nil }
        return string.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }

    nonisolated static func isUnchanged(_ before: Snapshot, _ after: Snapshot) -> Bool {
        guard let oldValue = before.value, let newValue = after.value, oldValue == newValue else { return false }
        if let oldRange = before.selection {
            guard let newRange = after.selection,
                  oldRange.location == newRange.location, oldRange.length == newRange.length else { return false }
        }
        return true
    }

    nonisolated static func confirms(_ text: String, before: Snapshot, after: Snapshot) -> Bool {
        guard let expected = expectedValue(before: before, inserting: text), after.value == expected else { return false }
        if expected != before.value { return true }
        // Replacing a selection with identical text must still move the caret.
        guard let oldRange = before.selection, let newRange = after.selection else { return false }
        return newRange.length == 0 && newRange.location == oldRange.location + text.utf16.count
    }

    private func waitForConfirmation(_ text: String, before: Snapshot, in element: AXUIElement) async -> Bool {
        for attempt in 0..<20 {
            if Self.confirms(text, before: before, after: snapshot(of: element)) { return true }
            if attempt < 19 { try? await Task.sleep(nanoseconds: 25_000_000) }
        }
        return false
    }

    private func unconfirmedError(_ destination: Destination) -> WisprError {
        .message("Could not verify the text in \(destination.appName). Check that field before trying again; the full cleaned text is still in Local Wispr.")
    }

    private func validateFocus(_ destination: Destination, checkSelection: Bool = true) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processID,
              let current = focusedElement(in: AXUIElementCreateApplication(destination.processID)),
              CFEqual(current, destination.element) else {
            throw WisprError.message("The focused text field changed, so nothing was inserted. Your cleaned text is still in Local Wispr.")
        }
        if checkSelection {
            let now = snapshot(of: current)
            if let before = destination.snapshot.selection {
                guard let range = now.selection, before.location == range.location, before.length == range.length else {
                    throw WisprError.message("The cursor moved while processing, so nothing was inserted. Your cleaned text is still in Local Wispr.")
                }
            }
            if let value = destination.snapshot.value, now.value != value {
                throw WisprError.message("The field changed while processing, so nothing was inserted. Your cleaned text is still in Local Wispr.")
            }
        }
    }

    private func snapshot(of element: AXUIElement) -> Snapshot {
        Snapshot(value: optionalStringAttribute(kAXValueAttribute, of: element), selection: selectedRange(of: element))
    }

    private func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String {
        optionalStringAttribute(attribute, of: element) ?? ""
    }

    private func optionalStringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
