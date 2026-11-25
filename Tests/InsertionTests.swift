import Foundation

// Pure regression checks: these do not send events or require permissions.
enum WisprError: Error { case message(String) }

@main
struct InsertionTests {
    @MainActor
    static func main() async {
        let examples = ["", "Hello world", String(repeating: "word ", count: 500),
                        "English ภาษาไทย 中文 日本語", "1234567890123456789😀👩🏽‍💻 café e\u{301}"]
        for original in examples {
            let chunks = TextInsertion.unicodeChunks(original)
            precondition(chunks.allSatisfy { (1...2).contains($0.count) })
            precondition(chunks.allSatisfy { String(decoding: $0, as: UTF16.self).unicodeScalars.count == 1 })
            let decoded = chunks.map { String(decoding: $0, as: UTF16.self) }.joined()
            precondition(decoded == original, "Unicode text changed across typing chunks")
        }
        typealias Snapshot = TextInsertion.Snapshot
        let before = Snapshot(value: "Hello world!", selection: CFRange(location: 6, length: 5))
        precondition(TextInsertion.expectedValue(before: before, inserting: "everyone") == "Hello everyone!")
        precondition(TextInsertion.isUnchanged(before, before), "A silent AX no-op must allow the typing fallback")
        precondition(!TextInsertion.confirms("everyone", before: before, after: before), "A successful API call alone cannot confirm insertion")
        let partial = Snapshot(value: "Hello every!", selection: CFRange(location: 11, length: 0))
        precondition(!TextInsertion.isUnchanged(before, partial), "Partial insertion must not trigger duplicate fallback")
        precondition(!TextInsertion.confirms("everyone", before: before, after: partial))
        let complete = Snapshot(value: "Hello everyone!", selection: CFRange(location: 14, length: 0))
        precondition(TextInsertion.confirms("everyone", before: before, after: complete))
        let emoji = Snapshot(value: "😀 apple", selection: CFRange(location: 3, length: 5))
        precondition(TextInsertion.expectedValue(before: emoji, inserting: "ภาษาไทย") == "😀 ภาษาไทย", "AX ranges use UTF-16 offsets")
        let empty = Snapshot(value: "", selection: CFRange(location: 0, length: 0))
        precondition(TextInsertion.expectedValue(before: empty, inserting: "Hi") == "Hi")
        let list = "- **Cucumbers**\n- *Carrots*\n- APPLES"
        precondition(TextInsertion.expectedValue(before: before, inserting: list) == "Hello " + list + "!")
        precondition(TextInsertion.confirms(list, before: before,
                                           after: Snapshot(value: "Hello " + list + "!", selection: nil)))
        let identical = Snapshot(value: "Hello", selection: CFRange(location: 0, length: 5))
        precondition(!TextInsertion.confirms("Hello", before: identical, after: identical))
        precondition(TextInsertion.confirms("Hello", before: identical,
                                           after: Snapshot(value: "Hello", selection: CFRange(location: 5, length: 0))))
        let invalid = Snapshot(value: "Hello", selection: CFRange(location: Int.max, length: 1))
        precondition(TextInsertion.expectedValue(before: invalid, inserting: "Hi") == nil)
        let hidden = Snapshot(value: nil, selection: nil)
        precondition(!TextInsertion.isUnchanged(hidden, hidden), "Missing readback cannot prove a no-op")
        precondition(!TextInsertion.confirms("Hi", before: hidden, after: hidden))

        // Reproduce editors that ignore SelectedText but accept the complete Value.
        // A formatted single line must take the same successful route as a list.
        for text in ["A normal sentence.", "These **cucumbers** are *fresh*.", list, "ภาษาไทย 😀"] {
            var state = before
            var attempts: [TextInsertion.ReplacementAttribute] = []
            var caret: Int?
            let access = TextInsertion.ReplacementAccess(
                canSet: { _ in true },
                write: { attribute, value in
                    attempts.append(attribute)
                    if attribute == .value { state = Snapshot(value: value, selection: nil) }
                    return true
                },
                read: { state }, validateFocus: {}, moveCaret: { caret = $0 })
            let result = try! await TextInsertion.replaceUsingAccessibility(text, before: before, access: access, pause: {})
            precondition(result == .confirmed)
            precondition(attempts == [.selectedText, .value])
            precondition(state.value == "Hello " + text + "!", "The fallback must preserve text outside the selection")
            precondition(caret == 6 + text.utf16.count)
        }
        // An AX error does not block fallback when readback proves no text changed.
        var rejectedState = before
        let rejected = TextInsertion.ReplacementAccess(canSet: { _ in true }, write: { attribute, value in
            if attribute == .selectedText { return false }
            rejectedState = Snapshot(value: value, selection: nil)
            return true
        }, read: { rejectedState }, validateFocus: {}, moveCaret: { _ in })
        let rejectedResult = try! await TextInsertion.replaceUsingAccessibility("**fresh**", before: before, access: rejected, pause: {})
        precondition(rejectedResult == .confirmed)

        // A partial edit, missing readback, or moved cursor must never retry a write.
        for changed in [partial, hidden, Snapshot(value: before.value, selection: CFRange(location: 1, length: 0))] {
            var state = before
            var attempts = 0
            let access = TextInsertion.ReplacementAccess(canSet: { _ in true }, write: { _, _ in
                attempts += 1; state = changed; return true
            }, read: { state }, validateFocus: {}, moveCaret: { _ in })
            let result = try! await TextInsertion.replaceUsingAccessibility("everyone", before: before, access: access, pause: {})
            precondition(result == .uncertain && attempts == 1)
        }
        var focusChecks = 0, focusWrites = 0
        let lostFocus = TextInsertion.ReplacementAccess(canSet: { _ in true }, write: { _, _ in
            focusWrites += 1; return false
        }, read: { before }, validateFocus: {
            focusChecks += 1
            if focusChecks == 2 { throw WisprError.message("Focus changed") }
        }, moveCaret: { _ in })
        do {
            _ = try await TextInsertion.replaceUsingAccessibility("everyone", before: before, access: lostFocus, pause: {})
            preconditionFailure("A changed destination must stop the next write")
        } catch { precondition(focusWrites == 1) }
        print("PASS: Unicode typing preserves Thai, Chinese, emoji and surrogate pairs")
        print("PASS: readback rejects silent no-ops, partial insertion and missing values; confirms exact UTF-16 replacement")
        print("PASS: plain sentences, Markdown sentences and lists all fall back to verified Value replacement")
        print("PASS: rejected writes can fall back; partial edits, missing readback and changed focus cannot duplicate text")
    }
}
