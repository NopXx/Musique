//
//  TextToShape.swift
//  Musique
//
//  Created by NopXx on 7/5/2569 BE.
//

import SwiftUI
import CoreText

#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
#endif

enum GlassTextVariant: String, CaseIterable, Identifiable {
    case regular
    case clear
    case tinted
    case interactive
    case solid
    case outline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: return "Regular"
        case .clear: return "Clear"
        case .tinted: return "Tinted"
        case .interactive: return "Interactive"
        case .solid: return "Solid"
        case .outline: return "Outline"
        }
    }
}

struct GlassEffectText: View {
    var text: String
    var font: PlatformFont
    var fallbackColor: Color = .primary
    var variant: GlassTextVariant = .regular
    var glassTint: Color = .clear

    var body: some View {
        let renderFont: PlatformFont = {
            #if canImport(AppKit)
            if variant == .outline {
                return NSFont.systemFont(ofSize: font.pointSize, weight: .ultraLight)
            }
            #endif
            return font
        }()
        let ctFont = renderFont as CTFont
        let textShape = TextToShape(value: text, ctFont: ctFont)
        let swiftFont = Font(ctFont)

        switch variant {
        case .solid:
            Text(text)
                .font(swiftFont)
                .opacity(0)
                .overlay(
                    textShape.fill(glassTint == .clear ? fallbackColor : glassTint)
                )
        case .outline:
            Text(text)
                .font(swiftFont)
                .opacity(0)
                .overlay(
                    textShape.stroke(
                        glassTint == .clear ? Color.white : glassTint,
                        lineWidth: max(1, renderFont.pointSize * 0.015)
                    )
                )
        default:
            Text(text)
                .font(swiftFont)
                .opacity(0)
                .glassEffect(resolvedGlass(), in: textShape)
        }
    }

    private func resolvedGlass() -> Glass {
        let base: Glass
        switch variant {
        case .regular:     base = .regular
        case .clear:       base = .clear
        case .tinted:      base = .regular.tint(glassTint == .clear ? .white.opacity(0.7) : glassTint)
        case .interactive: base = .regular.interactive()
        case .solid, .outline: base = .regular
        }
        if variant != .tinted, glassTint != .clear {
            return base.tint(glassTint)
        }
        return base
    }
}

struct TextToShape: Shape {
    var value: String
    var ctFont: CTFont

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        drawGlyphs(value, ctFont: ctFont) { (position, glyphPath) in
            let transform = CGAffineTransform(translationX: position.x, y: position.y).scaledBy(x: 1, y: -1)
            let newPath = Path(glyphPath).applying(transform)
            
            path.addPath(newPath)
        }
        
        let bounds = path.boundingRect
        let offsetX = rect.minX - bounds.minX
        let offsetY = rect.minY - bounds.minY
        let centerTransform = CGAffineTransform(translationX: offsetX, y: offsetY)
        
        return path.applying(centerTransform)
    }
}

nonisolated
private func drawGlyphs(
    _ value: String,
    ctFont: CTFont,
    draw: @escaping (_ position: CGPoint, _ glyphPath: CGPath) -> Void
) {
    let attributedString = NSAttributedString(
        string: value,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont]
    )

    let line = CTLineCreateWithAttributedString(attributedString)
    let runs = CTLineGetGlyphRuns(line)

    for runIndex in 0..<CFArrayGetCount(runs) {
        let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
        let runCount = CTRunGetGlyphCount(run)

        for index in 0..<runCount {
            let glyphRange = CFRangeMake(index, 1)
            var glyph = CGGlyph()
            var position = CGPoint()

            CTRunGetGlyphs(run, glyphRange, &glyph)
            CTRunGetPositions(run, glyphRange, &position)

            if let glyphPath = CTFontCreatePathForGlyph(ctFont, glyph, nil) {
                draw(position, glyphPath)
            }
        }
    }
}
