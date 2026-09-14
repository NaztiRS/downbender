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

@MainActor
@Test func queueFilterButtonsAcceptClicksAcrossTheirVisualSurface() throws {
    let compactClicks = ClickRecorder()
    let compact = QueueFilterButton(
        label: "ACTIVE",
        value: 1,
        color: .cyan,
        selected: false,
        layout: .compact,
        action: { compactClicks.count += 1 }
    )
    .fixedSize()

    let compactSize = try hostedSize(of: compact)
    try clickHostedView(compact, size: compactSize, at: CGPoint(x: 2, y: compactSize.height / 2))
    #expect(compactClicks.count == 1, "The compact filter's padded leading edge must be clickable")

    let railClicks = ClickRecorder()
    let rail = QueueFilterButton(
        label: "ACTIVE",
        value: 1,
        color: .cyan,
        selected: false,
        layout: .rail,
        action: { railClicks.count += 1 }
    )
    .frame(width: 132, height: 32)

    try clickHostedView(rail, size: CGSize(width: 132, height: 32), at: CGPoint(x: 66, y: 16))
    #expect(railClicks.count == 1, "The rail filter's empty center must be clickable")
}

@MainActor
private final class ClickRecorder {
    var count = 0
}

@MainActor
private func hostedSize<Content: View>(of view: Content) throws -> CGSize {
    let hostingView = NSHostingView(rootView: view)
    let size = hostingView.fittingSize
    #expect(size.width > 0 && size.height > 0)
    return size
}

@MainActor
private func clickHostedView<Content: View>(
    _ view: Content,
    size: CGSize,
    at point: CGPoint
) throws {
    let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = CGRect(origin: .zero, size: size)
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    hostingView.layoutSubtreeIfNeeded()

    defer { window.orderOut(nil) }

    for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(
            with: eventType,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: eventType == .leftMouseDown ? 1 : 0
        ))
        window.sendEvent(event)
    }
}
