import Foundation

/// Apple TTML marks backing vocals with `<span ttm:role="x-bg">`. MusanovaKit's
/// parser drops the role and folds them into the line's text and segments, so a
/// "Forever" line reads "Forever (Like I'mma live forever)" with both voices
/// wiping at once. These find them again and move them onto their own row.
enum BackgroundVocals {
    /// Start/end, in ms, of every syllable inside an x-bg span.
    static func keys(in ttml: String) -> Set<[Int]> {
        guard let block = try? NSRegularExpression(
                  pattern: #"<span[^>]*ttm:role="x-bg"[^>]*>((?:\s*<span[^>]*>[^<]*</span>)+)\s*</span>"#),
              let times = try? NSRegularExpression(pattern: #"begin="([^"]+)"[^>]*end="([^"]+)""#)
        else { return [] }
        let doc = ttml as NSString
        var out = Set<[Int]>()
        for m in block.matches(in: ttml, range: NSRange(location: 0, length: doc.length)) {
            let inner = doc.substring(with: m.range(at: 1)) as NSString
            for t in times.matches(in: inner as String, range: NSRange(location: 0, length: inner.length)) {
                if let s = seconds(inner.substring(with: t.range(at: 1))),
                   let e = seconds(inner.substring(with: t.range(at: 2))) {
                    out.insert([ms(s), ms(e)])
                }
            }
        }
        return out
    }

    /// Moves the line's backing-vocal syllables out of `text`/`segments` into
    /// `backgroundText`/`background`. The line comes back unchanged unless they
    /// form one run that can be found in the text — or if they're the whole line.
    static func split(_ line: LyricLine, keys: Set<[Int]>) -> LyricLine {
        let isBG = line.segments.map { keys.contains([ms($0.start), ms($0.end)]) }
        guard let first = isBG.firstIndex(of: true), let last = isBG.lastIndex(of: true),
              isBG[first...last].allSatisfy({ $0 }), isBG.contains(false) else { return line }

        // Locate every syllable in order, as the karaoke renderer does.
        let text = line.text
        var cursor = text.startIndex
        var ranges: [Range<String.Index>] = []
        for segment in line.segments {
            guard let r = text.range(of: segment.text, range: cursor..<text.endIndex) else { return line }
            ranges.append(r)
            cursor = r.upperBound
        }
        let bgRange = ranges[first].lowerBound..<ranges[last].upperBound
        var main = text
        main.removeSubrange(bgRange)

        var bgText = String(text[bgRange])
        var bg = Array(line.segments[first...last])
        // On a row of its own the brackets go, as in Apple Music.
        if bgText.hasPrefix("("), bgText.hasSuffix(")"),
           bg[0].text.hasPrefix("("), bg[bg.count - 1].text.hasSuffix(")") {
            bgText = String(bgText.dropFirst().dropLast())
            bg[0] = TimedLyricSegment(text: String(bg[0].text.dropFirst()), start: bg[0].start, end: bg[0].end)
            let l = bg.count - 1
            bg[l] = TimedLyricSegment(text: String(bg[l].text.dropLast()), start: bg[l].start, end: bg[l].end)
        }

        var out = LyricLine(time: line.time, end: line.end,
                            text: main.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                            segments: Array(line.segments[..<first]) + line.segments[(last + 1)...])
        out.background = bg
        out.backgroundText = bgText
        out.provider = line.provider
        return out
    }

    private static func ms(_ t: Double) -> Int { Int((t * 1000).rounded()) }

    /// "1:10.481", "70.481" or "0:01:10.481".
    private static func seconds(_ s: String) -> Double? {
        var total = 0.0
        for part in s.split(separator: ":") {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
