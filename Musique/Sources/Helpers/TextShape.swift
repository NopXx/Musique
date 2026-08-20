import SwiftUI
import CoreText

/// The clock's digits as a real `Shape`, so Liquid Glass can be applied to the
/// glyphs themselves.
///
/// `.glassEffect(_:in:)` takes a `Shape`, and `Text` is not one — glass on a `Text`
/// only ever frosts the box around it, which is the card look, not the iOS 26 lock
/// screen clock. Core Text hands back the glyph outlines, and glass poured into
/// those refracts the artwork per numeral, rim and all.
struct TextShape: Shape {
    let string: String
    let font: NSFont

    /// Tight bounds of the rendered glyphs. A `Shape` has no intrinsic size, so the
    /// caller frames itself from this before pouring glass into the outline.
    // ponytail: the outline is built again here and once more in path(in:) — twice
    // a minute, on a view that redraws once a minute. A cache would cost more code
    // than the two CTLine passes it saves.
    var size: CGSize { Self.outline(string, font).boundingBoxOfPath.size }

    func path(in rect: CGRect) -> Path {
        let cg = Self.outline(string, font)
        let box = cg.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return Path() }
        // Core Text draws y-up from a baseline at the origin; flip it, then centre
        // the glyphs' own bounding box on the rect we were handed.
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: 1, y: -1)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(cg.copy(using: &t) ?? cg)
    }

    private static func outline(_ string: String, _ font: NSFont) -> CGPath {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let runFont = unsafeBitCast(
                CFDictionaryGetValue(CTRunGetAttributes(run),
                                     unsafeBitCast(kCTFontAttributeName, to: UnsafeRawPointer.self)),
                to: CTFont.self)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let g = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                path.addPath(g, transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
        }
        return path
    }

    /// System rounded, monospaced digits so the clock doesn't shuffle every minute.
    static func clockFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }
}
