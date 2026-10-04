import XCTest
import UIKit

/// WCAG contrast of what is actually on screen: the element's most common colour is its
/// background, and the pixel that differs from it most is its text (glyph cores are solid;
/// anti-aliased edges sit between the two, so they never win).
struct Contrast {
    struct RGB: Hashable, CustomStringConvertible {
        let r: UInt8, g: UInt8, b: UInt8
        var luminance: Double {
            func channel(_ c: UInt8) -> Double {
                let v = Double(c) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        var description: String { String(format: "#%02X%02X%02X", r, g, b) }
        /// Clearly red: a destructive role's tint.
        var isRed: Bool { Int(r) > Int(g) + 80 && Int(r) > Int(b) + 80 }
    }

    let background: RGB
    let text: RGB
    /// Share of the element's pixels drawn in a clear red.
    let redShare: Double
    var ratio: Double {
        let (a, b) = (background.luminance, text.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        (max(a.luminance, b.luminance) + 0.05) / (min(a.luminance, b.luminance) + 0.05)
    }

    /// `inset` trims the element's edges (rounded corners, neighbours' anti-aliasing).
    init(of element: XCUIElement, inset: CGFloat = 3) {
        let image = element.screenshot().image
        let pixels = Self.pixels(image, inset: inset * image.scale)
        var counts: [RGB: Int] = [:]
        for pixel in pixels { counts[pixel, default: 0] += 1 }
        let background = counts.max { $0.value < $1.value }?.key ?? RGB(r: 0, g: 0, b: 0)
        self.background = background
        text = pixels.max { Self.ratio($0, background) < Self.ratio($1, background) } ?? background
        redShare = pixels.isEmpty ? 0 : Double(pixels.filter(\.isRed).count) / Double(pixels.count)
    }

    private static func pixels(_ image: UIImage, inset: CGFloat) -> [RGB] {
        guard let cg = image.cgImage else { return [] }
        let (width, height) = (cg.width, cg.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let edge = Int(inset)
        var result: [RGB] = []
        for y in edge..<max(edge, height - edge) {
            for x in edge..<max(edge, width - edge) {
                let i = (y * width + x) * 4
                result.append(RGB(r: data[i], g: data[i + 1], b: data[i + 2]))
            }
        }
        return result
    }
}
