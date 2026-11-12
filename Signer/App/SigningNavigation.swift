import SwiftUI
import UIKit

/// Let UINavigationController coordinate its own toolbar with the tab bar when
/// pushing the signing flow. A SwiftUI visibility preference alone can retain
/// the tab bar's empty container over the toolbar on newer iOS releases.
struct SigningNavigation: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> Attachment { Attachment() }
  func updateUIViewController(_ controller: Attachment, context: Context) { controller.configure(animated: false) }
  final class Attachment: UIViewController {
    private weak var owner: UIViewController?
    private weak var navigation: UINavigationController?
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); configure(animated: false) }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); configure(animated: animated) }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); configure(animated: false) }
    override func viewDidDisappear(_ animated: Bool) {
      super.viewDidDisappear(animated)
      guard let navigation else { return }
      let hidden = navigation.topViewController?.hidesBottomBarWhenPushed == true
      if #available(iOS 18.0, *), let tabs = navigation.tabBarController, tabs.isTabBarHidden != hidden {
        tabs.setTabBarHidden(hidden, animated: false)
      }
    }
    func configure(animated: Bool) {
      var ancestor = parent
      while let controller = ancestor {
        if let navigation = controller.navigationController, navigation.viewControllers.contains(where: { $0 === controller }) {
          owner = controller
          self.navigation = navigation
          controller.hidesBottomBarWhenPushed = true
          if navigation.topViewController === controller, #available(iOS 18.0, *), let tabs = navigation.tabBarController, !tabs.isTabBarHidden {
            tabs.setTabBarHidden(true, animated: animated)
          }
          return
        }
        ancestor = controller.parent
      }
    }
  }
}
