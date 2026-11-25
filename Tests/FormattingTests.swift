import Foundation

@main
struct FormattingTests {
    static func check(_ raw: String, cleaned: [String], expected: String) {
        let draft = DictationFormatting.parse(raw)
        let actual = DictationFormatting.render(draft, cleanedLines: cleaned)
        precondition(actual == expected, "Expected \(expected.debugDescription), got \(actual.debugDescription)")
    }

    static func acousticFixture(amplitudes: [Double], pitches: [Double]) -> (RecognizedSpeech, [Float]) {
        var words: [TimedSpeechWord] = [], samples: [Float] = []
        let labels = ["please", "bring", "some", "fresh", "cucumbers", "from", "the", "market"]
        for index in amplitudes.indices {
            let start = Double(samples.count) / 16_000
            for frame in 0..<5_600 {
                samples.append(Float(amplitudes[index] * sin(2 * .pi * pitches[index] * Double(frame) / 16_000)))
            }
            words.append(.init(text: labels[index], start: start, end: Double(samples.count) / 16_000))
            samples.append(contentsOf: repeatElement(0, count: 800))
        }
        return (RecognizedSpeech(text: words.map(\.text).joined(separator: " "), words: words), samples)
    }

    static func main() {
        check("Please bring bold on cucumbers bold off and italic on fresh carrots italic off.",
              cleaned: ["Please bring cucumbers and fresh carrots."],
              expected: "Please bring **cucumbers** and *fresh carrots*.")
        check("Shopping. Start list bold on cucumbers bold off next item italic on carrots italic off next item caps on apples caps off end list That is all.",
              cleaned: ["Shopping.", "Cucumbers", "Carrots", "Apples", "That is all."],
              expected: "Shopping.\n\n- **Cucumbers**\n- *Carrots*\n- APPLES\n\nThat is all.")
        check("Um I want bold on cucumbers bold off today.", cleaned: ["I want cucumbers today."],
              expected: "I want **cucumbers** today.")
        check("bold on are bold off delicious.", cleaned: ["Is delicious."], expected: "Is delicious.")
        check("bold on very bold off very good.", cleaned: ["Very good."], expected: "Very good.")
        check("bold on italic on cucumbers italic off carrots bold off.",
              cleaned: ["Cucumbers carrots."], expected: "***Cucumbers*** **carrots**.")
        check("italic on ภาษาไทย italic off", cleaned: ["ภาษาไทย"], expected: "*ภาษาไทย*")
        let ordinary = "The next item is a cucumber and the word bold has a meaning."
        check(ordinary, cleaned: [ordinary], expected: ordinary)
        precondition(DictationFormatting.parse("Start list bold on bold off end list").lines.isEmpty)
        print("PASS: explicit styles, bullets, nested styles and Unicode survive cleanup")
        print("PASS: removed words and ambiguous repetitions never transfer styles to unrelated words")

        let normal = acousticFixture(amplitudes: [0.02, 0.018, 0.022, 0.021, 0.023, 0.019, 0.02, 0.021],
                                     pitches: Array(repeating: 160, count: 8))
        precondition(DictationFormatting.emphasis(normal.0, samples: normal.1).isEmpty)
        for (amplitude, frequency, expected) in [(0.1, 180.0, WordStyle.capitals),
                                                  (0.05, 180.0, WordStyle.bold),
                                                  (0.032, 210.0, WordStyle.italic)] {
            var levels = Array(repeating: 0.02, count: 8), pitches = Array(repeating: 160.0, count: 8)
            levels[4] = amplitude; pitches[4] = frequency
            let fixture = acousticFixture(amplitudes: levels, pitches: pitches)
            let styles = DictationFormatting.emphasis(fixture.0, samples: fixture.1)
            precondition(styles == [4: expected], "Unexpected acoustic styles: \(styles)")
            let disabled = DictationFormatting.prepare(fixture.0, samples: fixture.1, enabled: false)
            precondition(disabled.lines.count == 1 && disabled.lines[0].styles.isEmpty)
            precondition(DictationFormatting.render(disabled, cleanedLines: [fixture.0.text]) == fixture.0.text)
        }
        let short = acousticFixture(amplitudes: [0.02, 0.02, 0.15], pitches: [160, 160, 200])
        precondition(DictationFormatting.emphasis(short.0, samples: short.1).isEmpty)
        let mismatched = RecognizedSpeech(text: "different words altogether here", words: normal.0.words)
        precondition(DictationFormatting.emphasis(mismatched, samples: normal.1).isEmpty)
        let commands = "bold on cucumbers bold off"
        let disabled = DictationFormatting.prepare(.init(text: commands, words: []), samples: [], enabled: false)
        precondition(disabled.lines[0].text == commands && disabled.lines[0].styles.isEmpty)
        print("PASS: relative loudness/pitch distinguish synthetic emphasis; normal and short speech stay plain")
        print("PASS: disabling experimental formatting bypasses both acoustic analysis and commands")
    }
}
