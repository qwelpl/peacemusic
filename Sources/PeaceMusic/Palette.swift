import AppKit
import SwiftUI

enum Palette {
    static let gridSize = 5

    static let fallback: [Color] = (0..<(gridSize * gridSize)).map { index in
        let hue = 0.72 + Double(index) / Double(gridSize * gridSize) * 0.2
        return Color(hue: hue, saturation: 0.6, brightness: 0.28)
    }

    /// Samples the artwork on a grid, so the background keeps the cover's layout
    /// of color and not only its average tones.
    static func meshColors(from image: NSImage) -> [Color] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil, width: gridSize, height: gridSize, bitsPerComponent: 8, bytesPerRow: gridSize * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return fallback }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
        guard let data = context.data else { return fallback }
        let pixels = data.bindMemory(to: UInt8.self, capacity: gridSize * gridSize * 4)

        return (0..<(gridSize * gridSize)).map { index in
            let red = CGFloat(pixels[index * 4]) / 255
            let green = CGFloat(pixels[index * 4 + 1]) / 255
            let blue = CGFloat(pixels[index * 4 + 2]) / 255
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            // Richer than the source, and never bright enough to wash out white text.
            return Color(
                hue: hue,
                saturation: min(saturation * 1.3, 1),
                brightness: min(max(brightness, 0.16), 0.68)
            )
        }
    }

    static func demoArtwork() -> NSImage {
        let size = 1000
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.36, blue: 0.42, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.17, blue: 0.75, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.42, blue: 0.72, alpha: 1),
        ])?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -55)
        NSColor(srgbRed: 1, green: 0.8, blue: 0.45, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 310, y: 330, width: 380, height: 380)).fill()
        image.unlockFocus()
        return image
    }
}

/// Used when Music.app has no artwork for a track, which happens with some streamed songs.
enum ArtworkFallback {
    private struct SearchResponse: Decodable {
        struct Item: Decodable { let artworkUrl100: String? }
        let results: [Item]
    }

    static func image(for track: Track) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(track.artist) \(track.title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let small = response.results.first?.artworkUrl100,
              let url = URL(string: small.replacingOccurrences(of: "100x100", with: "1000x1000")),
              let (imageData, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: imageData)
    }
}
