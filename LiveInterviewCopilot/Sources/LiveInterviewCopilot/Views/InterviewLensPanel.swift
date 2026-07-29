import AppKit

enum InterviewLensTopAnchor: CaseIterable, Sendable {
    case left
    case center
    case right
}

/// Pure window geometry for the compact interview lens.
///
/// AppKit screen coordinates use a bottom-left origin. Consequently, a frame
/// positioned near the top of a screen has a large `minY` value.
enum InterviewLensGeometry {
    static let minimumSize = CGSize(width: 440, height: 150)
    static let maximumWidth: CGFloat = 680
    static let maximumHeight: CGFloat = 760
    static let maximumVisibleHeightFraction: CGFloat = 0.82
    static let topInset: CGFloat = 12
    static let snapThreshold: CGFloat = 24

    static func defaultSize(for visibleFrame: CGRect) -> CGSize {
        let proposedSize: CGSize
        if visibleFrame.width <= 1_280, visibleFrame.height <= 720 {
            proposedSize = CGSize(width: 480, height: 240)
        } else if visibleFrame.width >= 1_920 {
            proposedSize = CGSize(width: 620, height: 320)
        } else {
            proposedSize = CGSize(width: 560, height: 288)
        }
        return constrainedSize(proposedSize, in: visibleFrame)
    }

    static func maximumSize(in visibleFrame: CGRect) -> CGSize {
        let frame = visibleFrame.standardized
        return CGSize(
            width: min(maximumWidth, max(0, frame.width)),
            height: min(
                maximumHeight,
                max(0, frame.height) * maximumVisibleHeightFraction
            )
        )
    }

    static func constrainedSize(_ proposedSize: CGSize, in visibleFrame: CGRect) -> CGSize {
        let maximum = maximumSize(in: visibleFrame)
        let minimumWidth = min(minimumSize.width, maximum.width)
        let minimumHeight = min(minimumSize.height, maximum.height)

        return CGSize(
            width: min(max(proposedSize.width, minimumWidth), maximum.width),
            height: min(max(proposedSize.height, minimumHeight), maximum.height)
        )
    }

    static func defaultFrame(in visibleFrame: CGRect) -> CGRect {
        topAnchoredFrame(
            size: defaultSize(for: visibleFrame),
            in: visibleFrame,
            anchor: .center
        )
    }

    static func topAnchoredFrame(
        size proposedSize: CGSize,
        in visibleFrame: CGRect,
        anchor: InterviewLensTopAnchor
    ) -> CGRect {
        let screen = visibleFrame.standardized
        let size = constrainedSize(proposedSize, in: screen)
        let originX: CGFloat = switch anchor {
        case .left:
            screen.minX + topInset
        case .center:
            screen.midX - size.width / 2
        case .right:
            screen.maxX - topInset - size.width
        }
        let originY = screen.maxY - topInset - size.height

        return clampedFrame(
            CGRect(origin: CGPoint(x: originX, y: originY), size: size),
            to: screen
        )
    }

    static func clampedFrame(_ proposedFrame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let screen = visibleFrame.standardized
        let frame = proposedFrame.standardized
        let size = constrainedSize(frame.size, in: screen)

        let maximumOriginX = max(screen.minX, screen.maxX - size.width)
        let maximumOriginY = max(screen.minY, screen.maxY - size.height)
        let origin = CGPoint(
            x: min(max(frame.minX, screen.minX), maximumOriginX),
            y: min(max(frame.minY, screen.minY), maximumOriginY)
        )
        return CGRect(origin: origin, size: size)
    }

    /// Fits the lens to the current semantic card while keeping its top edge
    /// stable, so advancing between cards does not make the camera-adjacent
    /// title bar jump around.
    static func contentFittedFrame(
        _ currentFrame: CGRect,
        preferredHeight: CGFloat,
        in visibleFrame: CGRect
    ) -> CGRect {
        let screen = visibleFrame.standardized
        let current = currentFrame.standardized
        let size = constrainedSize(
            CGSize(width: current.width, height: preferredHeight),
            in: screen
        )
        return clampedFrame(
            CGRect(
                x: current.minX,
                y: current.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            to: screen
        )
    }

    static func snappedFrame(
        _ proposedFrame: CGRect,
        in visibleFrame: CGRect,
        threshold: CGFloat = snapThreshold
    ) -> CGRect {
        let screen = visibleFrame.standardized
        let size = constrainedSize(proposedFrame.standardized.size, in: screen)
        let frame = CGRect(origin: proposedFrame.standardized.origin, size: size)
        let topOriginY = screen.maxY - topInset - size.height

        guard abs(frame.minY - topOriginY) <= threshold else {
            return clampedFrame(frame, to: screen)
        }

        var bestMatch: (frame: CGRect, distance: CGFloat)?
        for anchor in InterviewLensTopAnchor.allCases {
            let candidate = topAnchoredFrame(size: size, in: screen, anchor: anchor)
            let horizontalDistance = abs(frame.minX - candidate.minX)
            guard horizontalDistance <= threshold else { continue }

            let verticalDistance = abs(frame.minY - candidate.minY)
            let distance = hypot(horizontalDistance, verticalDistance)
            if bestMatch == nil || distance < bestMatch!.distance {
                bestMatch = (candidate, distance)
            }
        }

        return bestMatch?.frame ?? clampedFrame(frame, to: screen)
    }

    /// Returns a position in the movable range of the screen. `(0, 0)` is the
    /// bottom-left position and `(1, 1)` is the top-right position.
    static func normalizedOrigin(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let screen = visibleFrame.standardized
        let clamped = clampedFrame(frame, to: screen)
        let horizontalTravel = max(0, screen.width - clamped.width)
        let verticalTravel = max(0, screen.height - clamped.height)

        return CGPoint(
            x: horizontalTravel > 0
                ? (clamped.minX - screen.minX) / horizontalTravel
                : 0.5,
            y: verticalTravel > 0
                ? (clamped.minY - screen.minY) / verticalTravel
                : 0.5
        )
    }

    static func restoredFrame(
        size proposedSize: CGSize,
        normalizedOrigin: CGPoint,
        in visibleFrame: CGRect
    ) -> CGRect {
        let screen = visibleFrame.standardized
        let size = constrainedSize(proposedSize, in: screen)
        let normalizedX = min(max(normalizedOrigin.x, 0), 1)
        let normalizedY = min(max(normalizedOrigin.y, 0), 1)
        let horizontalTravel = max(0, screen.width - size.width)
        let verticalTravel = max(0, screen.height - size.height)

        return clampedFrame(
            CGRect(
                x: screen.minX + horizontalTravel * normalizedX,
                y: screen.minY + verticalTravel * normalizedY,
                width: size.width,
                height: size.height
            ),
            to: screen
        )
    }

    static func visibleFrameContainingLargestPortion(
        of frame: CGRect,
        among visibleFrames: [CGRect]
    ) -> CGRect? {
        var bestMatch: (frame: CGRect, intersectionArea: CGFloat)?
        for candidate in visibleFrames {
            let screen = candidate.standardized
            let intersection = frame.standardized.intersection(screen)
            guard !intersection.isNull, !intersection.isEmpty else { continue }

            let area = intersection.width * intersection.height
            if bestMatch == nil || area > bestMatch!.intersectionArea {
                bestMatch = (screen, area)
            }
        }
        return bestMatch?.frame
    }

    /// Keeps a saved frame on its current display when possible. If that
    /// display was disconnected, the first available frame is treated as the
    /// fallback (callers should put the main screen first) and the normalized
    /// position is restored there.
    static func recoveredFrame(
        _ savedFrame: CGRect,
        normalizedOrigin: CGPoint,
        availableVisibleFrames: [CGRect]
    ) -> CGRect? {
        guard let fallback = availableVisibleFrames.first else { return nil }
        if let currentScreen = visibleFrameContainingLargestPortion(
            of: savedFrame,
            among: availableVisibleFrames
        ) {
            return clampedFrame(savedFrame, to: currentScreen)
        }

        return restoredFrame(
            size: savedFrame.standardized.size,
            normalizedOrigin: normalizedOrigin,
            in: fallback
        )
    }
}

/// Non-activating shell for the compact interview lens. SwiftUI content and
/// lifecycle management are intentionally supplied by a later manager.
@MainActor
final class InterviewLensPanel: NSPanel {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("liveinterviewcopilot.interview-lens")

    init(
        contentRect: NSRect,
        hideFromScreenShare: Bool,
        screenVisibleFrame: NSRect? = nil
    ) {
        let visibleFrame = screenVisibleFrame ?? Self.inferredVisibleFrame(for: contentRect)
        let initialFrame = InterviewLensGeometry.clampedFrame(contentRect, to: visibleFrame)

        super.init(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        identifier = Self.panelIdentifier
        isFloatingPanel = true
        level = .floating
        sharingType = hideFromScreenShare ? .none : .readOnly
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false

        // The eventual SwiftUI title bar owns performDrag. Body content must
        // never turn into an implicit drag region.
        isMovableByWindowBackground = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        updateSizeLimits(for: visibleFrame)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateSizeLimits(for screenVisibleFrame: NSRect) {
        let maximum = InterviewLensGeometry.maximumSize(in: screenVisibleFrame)
        maxSize = maximum
        minSize = CGSize(
            width: min(InterviewLensGeometry.minimumSize.width, maximum.width),
            height: min(InterviewLensGeometry.minimumSize.height, maximum.height)
        )
    }

    private static func inferredVisibleFrame(for contentRect: NSRect) -> NSRect {
        let availableFrames = NSScreen.screens.map(\.visibleFrame)
        return InterviewLensGeometry.visibleFrameContainingLargestPortion(
            of: contentRect,
            among: availableFrames
        ) ?? NSScreen.main?.visibleFrame
            ?? availableFrames.first
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    }
}

/// Breaks the intrinsic-size feedback path between SwiftUI and the panel.
/// The manager alone owns the window frame; the hosting view fills this
/// frame-bound AppKit container.
@MainActor
final class InterviewLensContentContainerView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric
        )
    }
}
