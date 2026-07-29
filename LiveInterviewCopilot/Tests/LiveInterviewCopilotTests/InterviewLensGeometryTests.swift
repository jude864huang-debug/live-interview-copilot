import AppKit
import XCTest
@testable import LiveInterviewCopilotKit

final class InterviewLensGeometryTests: XCTestCase {
    @MainActor
    func testHostingContainerDoesNotAdvertiseIntrinsicWindowSize() {
        let container = InterviewLensContentContainerView(
            frame: CGRect(x: 0, y: 0, width: 560, height: 240)
        )

        XCTAssertEqual(container.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(container.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    @MainActor
    func testPanelFloatsWithoutTakingKeyOrMainWindowFocus() {
        let panel = InterviewLensPanel(
            contentRect: CGRect(x: 100, y: 100, width: 560, height: 288),
            hideFromScreenShare: false,
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
        )

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.sharingType, .readOnly)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testDefaultSizesAtSupportedBreakpoints() {
        XCTAssertSize(
            InterviewLensGeometry.defaultSize(
                for: CGRect(x: 0, y: 0, width: 1_280, height: 720)
            ),
            equals: CGSize(width: 480, height: 240)
        )
        XCTAssertSize(
            InterviewLensGeometry.defaultSize(
                for: CGRect(x: 0, y: 0, width: 1_512, height: 944)
            ),
            equals: CGSize(width: 560, height: 288)
        )
        XCTAssertSize(
            InterviewLensGeometry.defaultSize(
                for: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            ),
            equals: CGSize(width: 620, height: 320)
        )
    }

    func testDefaultFrameUsesAppKitTopCenterCoordinates() {
        let screen = CGRect(x: 100, y: 50, width: 1_512, height: 944)

        XCTAssertRect(
            InterviewLensGeometry.defaultFrame(in: screen),
            equals: CGRect(x: 576, y: 694, width: 560, height: 288)
        )
    }

    func testMaximumHeightUsesMostOfVisibleHeightUntilCapped() {
        XCTAssertSize(
            InterviewLensGeometry.maximumSize(
                in: CGRect(x: 0, y: 0, width: 1_280, height: 720)
            ),
            equals: CGSize(width: 680, height: 590.4)
        )
        XCTAssertSize(
            InterviewLensGeometry.maximumSize(
                in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            ),
            equals: CGSize(width: 680, height: 760)
        )
    }

    func testVeryShortDisplayKeepsMinimumAtOrBelowMaximum() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 500)
        let maximum = InterviewLensGeometry.maximumSize(in: screen)
        let constrainedMinimum = InterviewLensGeometry.constrainedSize(
            InterviewLensGeometry.minimumSize,
            in: screen
        )

        XCTAssertLessThanOrEqual(constrainedMinimum.width, maximum.width)
        XCTAssertLessThanOrEqual(constrainedMinimum.height, maximum.height)
        XCTAssertEqual(constrainedMinimum.height, 150, accuracy: 0.000_001)
    }

    func testClampConstrainsSizeAndOriginOnOffsetDisplay() {
        let externalDisplay = CGRect(x: 1_440, y: -200, width: 1_920, height: 1_080)

        XCTAssertRect(
            InterviewLensGeometry.clampedFrame(
                CGRect(x: 3_300, y: 1_000, width: 900, height: 500),
                to: externalDisplay
            ),
            equals: CGRect(x: 2_680, y: 380, width: 680, height: 500)
        )
        XCTAssertRect(
            InterviewLensGeometry.clampedFrame(
                CGRect(x: 1_000, y: -600, width: 560, height: 288),
                to: externalDisplay
            ),
            equals: CGRect(x: 1_440, y: -200, width: 560, height: 288)
        )
    }

    func testContentFittedFramePreservesTopEdgeAndClampsHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let current = CGRect(x: 476, y: 644, width: 560, height: 288)
        let short = InterviewLensGeometry.contentFittedFrame(
            current,
            preferredHeight: 180,
            in: screen
        )
        XCTAssertEqual(short.maxY, current.maxY, accuracy: 0.000_001)
        XCTAssertEqual(short.height, 180, accuracy: 0.000_001)

        let oversized = InterviewLensGeometry.contentFittedFrame(
            short,
            preferredHeight: 2_000,
            in: screen
        )
        XCTAssertEqual(oversized.height, 760, accuracy: 0.000_001)
        XCTAssertTrue(screen.contains(oversized))
    }

    func testTopSnapSupportsLeftCenterAndRightAnchors() {
        let screen = CGRect(x: 100, y: 50, width: 1_512, height: 944)
        let size = CGSize(width: 560, height: 288)
        let expected: [(InterviewLensTopAnchor, CGRect)] = [
            (.left, CGRect(x: 112, y: 694, width: 560, height: 288)),
            (.center, CGRect(x: 576, y: 694, width: 560, height: 288)),
            (.right, CGRect(x: 1_040, y: 694, width: 560, height: 288)),
        ]

        for (anchor, target) in expected {
            let proposed = target.offsetBy(dx: anchor == .center ? 17 : -18, dy: -19)
            XCTAssertRect(
                InterviewLensGeometry.snappedFrame(proposed, in: screen),
                equals: target,
                message: "Expected \(anchor) top snap"
            )
        }

        let outsideThreshold = CGRect(x: 112, y: 669, width: size.width, height: size.height)
        XCTAssertRect(
            InterviewLensGeometry.snappedFrame(outsideThreshold, in: screen),
            equals: outsideThreshold,
            message: "A frame 25 points below the target must not snap"
        )
    }

    func testNormalizedPositionRestoresAcrossDifferentScreenOriginsAndSizes() {
        let externalDisplay = CGRect(x: 1_512, y: -120, width: 1_920, height: 1_080)
        let savedFrame = CGRect(x: 2_150, y: 520, width: 620, height: 320)
        let normalized = InterviewLensGeometry.normalizedOrigin(
            for: savedFrame,
            in: externalDisplay
        )
        let laptopDisplay = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let restored = InterviewLensGeometry.restoredFrame(
            size: savedFrame.size,
            normalizedOrigin: normalized,
            in: laptopDisplay
        )

        XCTAssertEqual(
            (restored.minX - laptopDisplay.minX) / (laptopDisplay.width - restored.width),
            normalized.x,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            (restored.minY - laptopDisplay.minY) / (laptopDisplay.height - restored.height),
            normalized.y,
            accuracy: 0.000_001
        )
    }

    func testRecoveryKeepsConnectedDisplayAndReclaimsDisconnectedDisplay() throws {
        let mainDisplay = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let externalDisplay = CGRect(x: 1_512, y: -120, width: 1_920, height: 1_080)
        let savedFrame = CGRect(x: 2_150, y: 520, width: 620, height: 320)
        let normalized = InterviewLensGeometry.normalizedOrigin(
            for: savedFrame,
            in: externalDisplay
        )

        let stillConnected = try XCTUnwrap(
            InterviewLensGeometry.recoveredFrame(
                savedFrame,
                normalizedOrigin: normalized,
                availableVisibleFrames: [mainDisplay, externalDisplay]
            )
        )
        XCTAssertRect(stillConnected, equals: savedFrame)

        let reclaimed = try XCTUnwrap(
            InterviewLensGeometry.recoveredFrame(
                savedFrame,
                normalizedOrigin: normalized,
                availableVisibleFrames: [mainDisplay]
            )
        )
        XCTAssertTrue(mainDisplay.contains(reclaimed))
        XCTAssertEqual(
            (reclaimed.minX - mainDisplay.minX) / (mainDisplay.width - reclaimed.width),
            normalized.x,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            (reclaimed.minY - mainDisplay.minY) / (mainDisplay.height - reclaimed.height),
            normalized.y,
            accuracy: 0.000_001
        )

        XCTAssertNil(
            InterviewLensGeometry.recoveredFrame(
                savedFrame,
                normalizedOrigin: normalized,
                availableVisibleFrames: []
            )
        )
    }

    func testNormalizedRestoreClampsOutOfRangeValues() {
        let screen = CGRect(x: -1_280, y: 0, width: 1_280, height: 720)

        XCTAssertRect(
            InterviewLensGeometry.restoredFrame(
                size: CGSize(width: 480, height: 240),
                normalizedOrigin: CGPoint(x: -2, y: 3),
                in: screen
            ),
            equals: CGRect(x: -1_280, y: 480, width: 480, height: 240)
        )
    }

    private func XCTAssertSize(
        _ actual: CGSize,
        equals expected: CGSize,
        accuracy: CGFloat = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func XCTAssertRect(
        _ actual: CGRect,
        equals expected: CGRect,
        accuracy: CGFloat = 0.000_001,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message, file: file, line: line)
    }
}
