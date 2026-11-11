import SwiftUI

/// 让 UIKit 随导航过渡收起和恢复底栏，包含侧滑取消，避免独立的 SwiftUI 底栏显示动画。
struct WorkspaceNavigationPolicy: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.configureParent() }

    final class Controller: UIViewController {
        private weak var coordinatedTransition: AnyObject?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); configureParent() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); configureParent(restoreRoot: true) }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); configureParent(restoreRoot: true) }

        func configureParent(restoreRoot: Bool = false) {
            var owner = parent
            while let candidate = owner {
                if let navigation = candidate.navigationController,
                   let index = navigation.viewControllers.firstIndex(where: { $0 === candidate }) {
                    if index > 0 { candidate.hidesBottomBarWhenPushed = true }
                    guard let tabs = navigation.tabBarController, Self.isSelected(navigation, in: tabs) else { return }
                    if let coordinator = navigation.transitionCoordinator {
                        guard coordinator.viewController(forKey: .to) === candidate,
                              coordinatedTransition !== coordinator as AnyObject else { return }
                        coordinatedTransition = coordinator as AnyObject
                        let registered = coordinator.animate(alongsideTransition: { _ in
                            Self.setHidden(index > 0, tabs: tabs, animated: true)
                        }, completion: { [weak navigation, weak tabs] _ in
                            guard let navigation, let tabs, Self.isSelected(navigation, in: tabs) else { return }
                            Self.setHidden(navigation.viewControllers.count > 1, tabs: tabs, animated: false)
                        })
                        if !registered { Self.setHidden(index > 0, tabs: tabs, animated: false) }
                    // 首页的普通内容刷新不覆盖键盘等功能主动设置的底栏状态。
                    } else if navigation.topViewController === candidate, index > 0 || restoreRoot {
                        Self.setHidden(index > 0, tabs: tabs, animated: false)
                    }
                    return
                }
                owner = candidate.parent
            }
        }
        private static func isSelected(_ navigation: UINavigationController, in tabs: UITabBarController) -> Bool {
            var parent: UIViewController? = navigation
            while let current = parent {
                if current === tabs.selectedViewController { return true }
                parent = current.parent
            }
            return false
        }
        private static func setHidden(_ hidden: Bool, tabs: UITabBarController, animated: Bool) {
            if #available(iOS 18.0, *) {
                if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: animated) }
            } else {
                tabs.tabBar.isHidden = hidden
            }
        }
    }
}
