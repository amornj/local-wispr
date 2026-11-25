import Foundation

struct TimedSpeechWord {
    let text: String
    let start: Double
    let end: Double
}

struct RecognizedSpeech {
    let text: String
    let words: [TimedSpeechWord]
}

struct WordStyle: OptionSet, Equatable {
    let rawValue: Int
    static let italic = WordStyle(rawValue: 1)
    static let bold = WordStyle(rawValue: 2)
    static let capitals = WordStyle(rawValue: 4)
}

struct DictationDraft {
    struct Line {
        let text: String
        let bullet: Bool
        let styles: [WordStyle]
    }
    let lines: [Line]

    static func plain(_ text: String) -> DictationDraft {
        DictationDraft(lines: [Line(text: text, bullet: false, styles: [])])
    }
}

enum DictationFormatting {
    private struct Word {
        let range: NSRange
        let key: String
    }
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}'’\-]*"#)

    private static func words(in text: String) -> [Word] {
        let source = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            Word(range: $0.range, key: source.substring(with: $0.range)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "’", with: "'"))
        }
    }

    static func prepare(_ speech: RecognizedSpeech, samples: [Float], enabled: Bool) -> DictationDraft {
        // The ordinary path neither analyzes audio nor interprets formatting commands.
        guard enabled else { return .plain(speech.text) }
        return parse(speech.text, acousticStyles: emphasis(speech, samples: samples))
    }

    // Deliberate command pairs avoid treating ordinary words such as "bold" as commands.
    // Commands are handled locally, before the remaining text reaches Qwen.
    static func parse(_ text: String, acousticStyles: [Int: WordStyle] = [:]) -> DictationDraft {
        let tokens = words(in: text)
        let source = text as NSString
        var lines: [DictationDraft.Line] = []
        var current = ""
        var styles: [WordStyle] = []
        var active: WordStyle = []
        var bullet = false
        var cursor = 0
        var index = 0
        var afterCommand = false

        func appendGap(to end: Int) {
            guard end >= cursor else { return }
            let gap = source.substring(with: NSRange(location: cursor, length: end - cursor))
            if !afterCommand { current += gap }
            cursor = end
        }
        func flush() {
            let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(.init(text: line, bullet: bullet, styles: styles)) }
            current = ""; styles = []
        }

        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1].key : ""
            var commandStyle: WordStyle = []
            switch token.key {
            case "bold": commandStyle = .bold
            case "italic", "italics": commandStyle = .italic
            case "caps", "capitals", "uppercase": commandStyle = .capitals
            default: break
            }
            let styleCommand = !commandStyle.isEmpty && ["on", "off"].contains(next)
            let startList = token.key == "start" && next == "list"
            let nextItem = bullet && token.key == "next" && next == "item"
            let endList = bullet && token.key == "end" && next == "list"
            // Only whitespace or punctuation may separate a command's two words.
            let commandGap = index + 1 < tokens.count
                ? source.substring(with: NSRange(location: NSMaxRange(token.range),
                                                  length: tokens[index + 1].range.location - NSMaxRange(token.range))) : ""
            if (styleCommand || startList || nextItem || endList), !commandGap.contains(where: { $0.isNewline }) {
                appendGap(to: token.range.location)
                if styleCommand {
                    if next == "on" { active.insert(commandStyle) } else { active.remove(commandStyle) }
                } else {
                    flush()
                    if startList { bullet = true }
                    if endList { bullet = false }
                }
                cursor = NSMaxRange(tokens[index + 1].range)
                index += 2
                afterCommand = true
                continue
            }
            appendGap(to: token.range.location)
            // Supply a space if removing an inline command also removed its surrounding punctuation.
            if afterCommand, !current.isEmpty, current.last?.isWhitespace == false { current += " " }
            current += source.substring(with: token.range)
            styles.append(active.isEmpty ? acousticStyles[index, default: []] : active)
            cursor = NSMaxRange(token.range)
            afterCommand = false
            index += 1
        }
        appendGap(to: source.length)
        flush()
        return DictationDraft(lines: lines)
    }

    // Qwen edits plain text. Apply Markdown afterwards so the model cannot drop the annotations.
    // Only matching words receive styles: uncertain rewrites are left unstyled.
    static func render(_ draft: DictationDraft, cleanedLines: [String]) -> String {
        guard draft.lines.count == cleanedLines.count else { return "" }
        var result = ""
        for index in draft.lines.indices {
            let line = draft.lines[index]
            let cleaned = cleanedLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let formatted = renderLine(cleaned, original: line)
            if index > 0 { result += line.bullet && draft.lines[index - 1].bullet ? "\n" : "\n\n" }
            result += (line.bullet ? "- " : "") + formatted
        }
        return result
    }

    private static func renderLine(_ text: String, original: DictationDraft.Line) -> String {
        guard original.styles.contains(where: { !$0.isEmpty }) else { return text }
        let old = words(in: original.text), new = words(in: text)
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= 1_000_000 else { return text }
        let columns = new.count + 1
        var lengths = [UInt16](repeating: 0, count: (old.count + 1) * columns)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[i * columns + j] = old[i].key == new[j].key
                    ? lengths[(i + 1) * columns + j + 1] + 1
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }
        let oldCounts = Dictionary(grouping: old, by: \.key).mapValues(\.count)
        let newCounts = Dictionary(grouping: new, by: \.key).mapValues(\.count)
        var projected = [WordStyle](repeating: [], count: new.count)
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i].key == new[j].key {
                // Repeated words removed by cleanup have ambiguous correspondence.
                if i < original.styles.count, oldCounts[old[i].key] == newCounts[new[j].key] {
                    projected[j] = original.styles[i]
                }
                i += 1; j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] { i += 1 }
            else { j += 1 }
        }
        let source = text as NSString
        var result = "", cursor = 0
        j = 0
        while j < new.count {
            let style = projected[j]
            var last = j
            while !style.isEmpty, last + 1 < new.count, projected[last + 1] == style {
                let gap = source.substring(with: NSRange(location: NSMaxRange(new[last].range),
                                                          length: new[last + 1].range.location - NSMaxRange(new[last].range)))
                guard gap.allSatisfy(\.isWhitespace) else { break }
                last += 1
            }
            let start = new[j].range.location, end = NSMaxRange(new[last].range)
            result += source.substring(with: NSRange(location: cursor, length: start - cursor))
            var content = source.substring(with: NSRange(location: start, length: end - start))
            if style.contains(.capitals) { content = content.uppercased() }
            let marker = (style.contains(.bold) ? "**" : "") + (style.contains(.italic) ? "*" : "")
            result += marker + content + marker
            cursor = end; j = last + 1
        }
        result += source.substring(from: cursor)
        return result
    }

    // Experimental relative prosody, not an emotion or intent classifier. A word must
    // stand out from at least four usable words in the same utterance. No extra model.
    static func emphasis(_ speech: RecognizedSpeech, samples: [Float]) -> [Int: WordStyle] {
        struct Feature { let index: Int; let db: Double; let pitch: Double? }
        let tokens = words(in: speech.text)
        var cursor = 0
        var features: [Feature] = []
        for segment in speech.words {
            let parts = words(in: segment.text)
            guard !parts.isEmpty else { continue }
            guard cursor + parts.count <= tokens.count,
                  parts.indices.allSatisfy({ parts[$0].key == tokens[cursor + $0].key }) else { return [:] }
            let ordinal = cursor
            cursor += parts.count
            guard parts.count == 1, segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start,
                  segment.end - segment.start >= 0.08, segment.end - segment.start <= 2,
                  segment.end <= Double(samples.count) / 16_000 + 0.03 else { continue }
            let start = min(samples.count, Int(segment.start * 16_000))
            let end = min(samples.count, Int(segment.end * 16_000))
            guard end - start >= 480 else { continue }
            var levels: [Double] = []
            for frame in stride(from: start, through: end - 480, by: 240) {
                var sum = 0.0
                for offset in 0..<480 { let value = Double(samples[frame + offset]); sum += value * value }
                let rms = sqrt(sum / 480)
                if rms > 0.0008, rms.isFinite { levels.append(20 * log10(rms)) }
            }
            guard !levels.isEmpty else { continue }
            levels.sort()
            let db = levels[min(levels.count - 1, levels.count * 3 / 4)]
            features.append(Feature(index: ordinal, db: db, pitch: pitch(samples, start: start, end: end)))
        }
        guard features.count >= 4 else { return [:] }
        let baseline = median(features.map(\.db))
        let pitches = features.compactMap(\.pitch)
        let baselinePitch = pitches.count >= 3 ? median(pitches) : nil
        var styles: [Int: WordStyle] = [:]
        for feature in features {
            let lift = feature.db - baseline
            let pitchLift = feature.pitch.flatMap { pitch in baselinePitch.map { 12 * log2(pitch / $0) } } ?? 0
            if lift >= 11, feature.db >= -24 { styles[feature.index] = .capitals }
            else if lift >= 6.5 { styles[feature.index] = .bold }
            else if lift >= 3, pitchLift >= 1.5 { styles[feature.index] = .italic }
        }
        return styles
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // Normalized autocorrelation on short 8 kHz frames; silence/unvoiced frames are ignored.
    private static func pitch(_ samples: [Float], start: Int, end: Int) -> Double? {
        guard end - start >= 512 else { return nil }
        var estimates: [Double] = []
        let step = max(512, (end - start - 512) / 8)
        for position in stride(from: start, through: end - 512, by: step) {
            var frame = (0..<256).map { Double(samples[position + $0 * 2]) }
            let mean = frame.reduce(0, +) / 256
            for index in frame.indices { frame[index] -= mean }
            guard frame.reduce(0, { $0 + $1 * $1 }) / 256 > 0.000001 else { continue }
            var correlations = [Double](repeating: 0, count: 135)
            for lag in 20...133 {
                var dot = 0.0, a = 0.0, b = 0.0
                for index in 0..<(256 - lag) {
                    dot += frame[index] * frame[index + lag]
                    a += frame[index] * frame[index]; b += frame[index + lag] * frame[index + lag]
                }
                correlations[lag] = dot / max(0.000000001, sqrt(a * b))
            }
            let best = correlations.max() ?? 0
            guard best >= 0.7,
                  let lag = (21...132).first(where: { correlations[$0] >= max(0.7, best * 0.95)
                      && correlations[$0] >= correlations[$0 - 1] && correlations[$0] > correlations[$0 + 1] }) else { continue }
            estimates.append(8_000 / Double(lag))
        }
        return estimates.count >= 2 ? median(estimates) : nil
    }
}
