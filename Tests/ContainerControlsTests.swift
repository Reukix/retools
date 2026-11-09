import XCTest
import UIKit
import ContainerControls
@testable import LiveContainerSwiftUI

final class ContainerControlsTests: XCTestCase {
    func testDragDirectionStaysLockedWhenFingerChangesDirection() {
        var axis = FloatingDragAxis.undecided
        axis.lock(to: CGSize(width: 2, height: 3)); XCTAssertEqual(axis, .undecided)
        axis.lock(to: CGSize(width: 3, height: 10)); XCTAssertEqual(axis, .vertical)
        axis.lock(to: CGSize(width: 80, height: 12)); XCTAssertEqual(axis, .vertical)
    }
    func testCollapsedOverlayPassesTouchesOutsideTheHandle() {
        let center = CGPoint(x: 360, y: 300), bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(FloatingControlGeometry.hit(center, center: center, expanded: false, bounds: bounds))
        XCTAssertFalse(FloatingControlGeometry.hit(CGPoint(x: 100, y: 300), center: center, expanded: false, bounds: bounds))
        let dock = FloatingControlGeometry.dockFrame(center: center, size: bounds.size, insets: .zero, appCount: 8)
        XCTAssertFalse(FloatingControlGeometry.hit(CGPoint(x: 100, y: 300), center: center, expanded: true, bounds: bounds, dockFrame: dock))
        XCTAssertTrue(FloatingControlGeometry.hit(CGPoint(x: dock.midX, y: dock.midY), center: center, expanded: true, bounds: bounds, dockFrame: dock))
        XCTAssertLessThanOrEqual(dock.maxY, bounds.maxY - 10)
    }
    func testDockStaysInsideLandscapeSafeAreaOnEitherEdge() {
        let size = CGSize(width: 874, height: 402), insets = UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)
        for center in [CGPoint(x: 0, y: 0), CGPoint(x: 874, y: 900)] {
            let frame = FloatingControlGeometry.dockFrame(center: center, size: size, insets: insets, appCount: 20)
            XCTAssertGreaterThanOrEqual(frame.minX, insets.left)
            XCTAssertLessThanOrEqual(frame.maxX, size.width - insets.right)
            XCTAssertGreaterThanOrEqual(frame.minY, insets.top)
            XCTAssertLessThanOrEqual(frame.maxY, size.height - insets.bottom)
        }
    }
    func testDragClampsToSafeAreaAndSnapsAfterRotation() {
        let size = CGSize(width: 402, height: 874), insets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
        let point = FloatingControlGeometry.snap(CGPoint(x: -300, y: 3000), size: size, insets: insets)
        XCTAssertEqual(point.x, 34); XCTAssertEqual(point.y, 792)
        let rotated = FloatingControlGeometry.clamp(point, size: CGSize(width: 874, height: 402), insets: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62))
        XCTAssertGreaterThanOrEqual(rotated.x, 96); XCTAssertLessThanOrEqual(rotated.y, 333)
    }
    func testControlRequestIsConsumedOnceWithExactTargetSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = UUID(), space = UUID()
        let request = ContainerControlRequest(action: .switchApp, appID: app, containerID: space)
        try ContainerControlMailbox.write(request, support: root)
        let restored = try XCTUnwrap(ContainerControlMailbox.consume(support: root))
        XCTAssertEqual(restored.appID, app); XCTAssertEqual(restored.containerID, space)
        XCTAssertNil(try ContainerControlMailbox.consume(support: root))
    }
    func testExpiredAndIncompleteSwitchRequestsAreRejected() {
        XCTAssertThrowsError(try ContainerControlRequest(action: .switchApp).validate())
        XCTAssertThrowsError(try ContainerControlRequest(action: .workbench, createdAt: Date().addingTimeInterval(-301)).validate())
    }
    @MainActor func testReturningToWorkbenchSelectsContainerTabWithoutLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        let store = WorkspaceStore(paths: paths)
        try ContainerControlMailbox.write(ContainerControlRequest(action: .workbench), support: paths.support)
        let handled = await store.handleContainerControl()
        XCTAssertTrue(handled); XCTAssertEqual(store.selectedTab, .containers); XCTAssertFalse(store.isWorking)
    }
}
