import XCTest
import UIKit
@testable import LiveContainerSwiftUI

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    private func policy(in parent: UIViewController) -> WorkspaceNavigationPolicy.Controller {
        let controller = WorkspaceNavigationPolicy.Controller()
        parent.addChild(controller)
        controller.didMove(toParent: parent)
        return controller
    }
    private func hidden(_ tabs: UITabBarController) -> Bool {
        if #available(iOS 18.0, *) { return tabs.isTabBarHidden }
        return tabs.tabBar.isHidden
    }

    func testDetailHidesTabBarAndReturningToRootRestoresIt() {
        let root = UIViewController(), detail = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let tabs = UITabBarController()
        tabs.viewControllers = [navigation]
        navigation.setViewControllers([root, detail], animated: false)
        let detailPolicy = policy(in: detail)
        detailPolicy.configureParent()
        XCTAssertTrue(detail.hidesBottomBarWhenPushed)
        XCTAssertTrue(hidden(tabs))
        navigation.setViewControllers([root], animated: false)
        let rootPolicy = policy(in: root)
        rootPolicy.configureParent(restoreRoot: true)
        XCTAssertFalse(hidden(tabs))
    }

    func testInactiveTabCannotShowBarOverSelectedDetail() {
        let root = UIViewController(), detail = UIViewController(), otherRoot = UIViewController()
        let selected = UINavigationController(rootViewController: root)
        let other = UINavigationController(rootViewController: otherRoot)
        let tabs = UITabBarController()
        tabs.viewControllers = [selected, other]
        tabs.selectedViewController = selected
        selected.setViewControllers([root, detail], animated: false)
        let selectedPolicy = policy(in: detail)
        selectedPolicy.configureParent()
        XCTAssertTrue(hidden(tabs))
        let backgroundPolicy = policy(in: otherRoot)
        backgroundPolicy.configureParent(restoreRoot: true)
        XCTAssertTrue(hidden(tabs))
        tabs.selectedViewController = other
        backgroundPolicy.configureParent(restoreRoot: true)
        XCTAssertFalse(hidden(tabs))
    }

    func testRootContentUpdatesPreserveKeyboardDrivenTabBarVisibility() {
        guard #available(iOS 18.0, *) else { return }
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let tabs = UITabBarController()
        tabs.viewControllers = [navigation]
        let rootPolicy = policy(in: root)
        tabs.setTabBarHidden(true, animated: false)
        rootPolicy.configureParent()
        XCTAssertTrue(hidden(tabs))
        rootPolicy.configureParent(restoreRoot: true)
        XCTAssertFalse(hidden(tabs))
    }
}
