import AppKit
import SwiftUI
import Testing
@testable import downbender

@MainActor
@Test func determinateProgressFillRendersThePublishedFraction() throws {
    let cases: [(fraction: Double, expectedWidth: Int)] = [
        (-0.10, 0),
        (0, 0),
        (0.001, 4),
        (0.10, 20),
        (0.50, 100),
        (0.85, 170),
        (1, 200),
        (1.10, 200),
    ]

    for testCase in cases {
        let renderer = ImageRenderer(content:
            WaveProgress(fraction: testCase.fraction)
                .frame(width: 200, height: 4)
        )
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let bitmap = try #require(makeBitmap(from: image))

        let renderedWidth = accentPixelWidth(in: bitmap)
        #expect(
            abs(renderedWidth - testCase.expectedWidth) <= 1,
            "fraction \(testCase.fraction) must occupy \(testCase.expectedWidth) of 200 pixels"
        )
    }
}

private func makeBitmap(from image: NSImage) -> NSBitmapImageRep? {
    guard let data = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: data)
}

private func accentPixelWidth(in bitmap: NSBitmapImageRep) -> Int {
    var minimumX = bitmap.pixelsWide
    var maximumX = -1

    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let isAccent = color.redComponent > 0.30
                && color.redComponent < 0.55
                && color.greenComponent > 0.75
                && color.blueComponent > 0.90
            if isAccent {
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
            }
        }
    }

    return maximumX >= minimumX ? maximumX - minimumX + 1 : 0
}
