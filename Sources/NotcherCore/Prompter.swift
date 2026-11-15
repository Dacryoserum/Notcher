import Foundation
import CoreGraphics

/// Where the teleprompter is in its text. Every button leaves it in a state the next press can act on:
/// nothing here can end with a control that does nothing.
public struct PrompterScroll: Equatable, Sendable {
    public private(set) var offset: CGFloat = 0
    public private(set) var playing = false
    /// Height of the whole text, and of the window it scrolls through.
    public private(set) var contentHeight: CGFloat = 0
    public private(set) var viewport: CGFloat = 0
    public init() {}

    /// The scroll stops with the last lines still on screen, not after they have left it.
    public var end: CGFloat { max(0, contentHeight - viewport * 0.4) }
    public var atEnd: Bool { offset >= end }
    /// A text that fits in the window has nowhere to scroll to.
    public var canPlay: Bool { end > 0 }

    public mutating func measure(contentHeight: CGFloat, viewport: CGFloat) {
        self.contentHeight = contentHeight.isFinite ? max(0, contentHeight) : 0
        self.viewport = viewport.isFinite ? max(0, viewport) : 0
        // A text that got shorter must not leave the window past its end.
        offset = min(offset, end)
        if !canPlay { playing = false }
    }
    /// Play or pause. Pressing play at the end starts again from the top.
    public mutating func toggle() {
        if playing { playing = false; return }
        guard canPlay else { return }
        if atEnd { offset = 0 }
        playing = true
    }
    public mutating func pause() { playing = false }
    public mutating func reset() { offset = 0; playing = false }
    /// Moves on by `distance` points; reaching the end stops the scroll there.
    public mutating func advance(by distance: CGFloat) {
        guard playing, distance.isFinite, distance > 0 else { return }
        offset = min(end, offset + distance)
        if atEnd { playing = false }
    }
}
