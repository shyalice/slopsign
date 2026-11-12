import SwiftUI
import UIKit
import ObjectiveC

extension View {
  func navigationSearch(text: Binding<String>, isPresented: Binding<Bool>) -> some View {
    background(NativeNavigationSearch(text: text, isPresented: isPresented).frame(width: 0, height: 0))
  }
  func navigationSearch(text: Binding<String>) -> some View {
    background(NativeNavigationSearch(text: text, isPresented: nil).frame(width: 0, height: 0))
  }
}

private var navigationSearchSessionKey: UInt8 = 0

/// The navigation item, rather than a transient SwiftUI attachment, owns search.
/// Rebuilding a List must not remove and recreate UIKit's search drawer.
private struct NativeNavigationSearch: UIViewControllerRepresentable {
  let text: Binding<String>
  let isPresented: Binding<Bool>?
  func makeUIViewController(context: Context) -> Attachment {
    Attachment(text: text, isPresented: isPresented)
  }
  func updateUIViewController(_ controller: Attachment, context: Context) {
    controller.query = text
    controller.presentation = isPresented
    controller.attach()
    controller.session?.synchronize()
  }
  static func dismantleUIViewController(_ controller: Attachment, coordinator: ()) { controller.detach() }

  final class Attachment: UIViewController {
    var query: Binding<String>
    var presentation: Binding<Bool>?
    var session: SearchSession?
    private weak var owner: UIViewController?
    init(text: Binding<String>, isPresented: Binding<Bool>?) {
      query = text; presentation = isPresented
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); attach() }
    func attach() {
      var ancestor = parent
      while let controller = ancestor {
        if let navigation = controller.navigationController,
          navigation.viewControllers.contains(where: { $0 === controller }) {
          if owner !== controller {
            detach()
            owner = controller
            let item = controller.navigationItem
            if let retained = objc_getAssociatedObject(item, &navigationSearchSessionKey) as? SearchSession {
              session = retained
            } else {
              let retained = SearchSession(owner: controller)
              objc_setAssociatedObject(item, &navigationSearchSessionKey, retained, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
              session = retained
            }
          }
          session?.client = self
          session?.attachTap()
          session?.synchronize()
          return
        }
        ancestor = controller.parent
      }
    }
    func detach() {
      if session?.client === self { session?.client = nil; session?.detachTap() }
      // UINavigationItem retains the search controller for a later native pop.
      // Removing it here caused an extra drawer layout after List reconstruction.
      owner = nil
      session = nil
    }
  }

  final class SearchSession: NSObject, UISearchResultsUpdating, UISearchControllerDelegate, UIGestureRecognizerDelegate {
    let search = UISearchController(searchResultsController: nil)
    weak var client: Attachment?
    private weak var owner: UIViewController?
    private var synchronizing = false
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
    init(owner: UIViewController) {
      self.owner = owner
      super.init()
      search.searchResultsUpdater = self
      search.delegate = self
      search.obscuresBackgroundDuringPresentation = false
      search.hidesNavigationBarDuringPresentation = true
      search.searchBar.placeholder = "Search"
      search.searchBar.searchBarStyle = .minimal
      search.searchBar.autocorrectionType = .no
      owner.definesPresentationContext = true
      owner.navigationItem.preferredSearchBarPlacement = .stacked
      owner.navigationItem.hidesSearchBarWhenScrolling = false
      if #available(iOS 26.0, *) { owner.navigationItem.searchBarPlacementAllowsToolbarIntegration = false }
      owner.navigationItem.searchController = search
      // Use the native field's opaque system fill instead of a material that
      // changes with scroll-edge state. UIKit still owns its shape and motion.
      search.searchBar.searchTextField.backgroundColor = .secondarySystemBackground
      tap.cancelsTouchesInView = false
      tap.delegate = self
    }
    func attachTap() {
      guard tap.view == nil else { return }
      owner?.view.addGestureRecognizer(tap)
    }
    func detachTap() { tap.view?.removeGestureRecognizer(tap) }
    func synchronize() {
      guard let client else { return }
      synchronizing = true
      defer { synchronizing = false }
      if search.searchBar.text != client.query.wrappedValue { search.searchBar.text = client.query.wrappedValue }
      guard let presentation = client.presentation, let owner,
        owner.navigationController?.topViewController === owner, owner.viewIfLoaded?.window != nil else { return }
      if search.isActive != presentation.wrappedValue { search.isActive = presentation.wrappedValue }
    }
    func updateSearchResults(for searchController: UISearchController) {
      guard !synchronizing, let client else { return }
      let value = searchController.searchBar.text ?? ""
      if client.query.wrappedValue != value { client.query.wrappedValue = value }
    }
    func willPresentSearchController(_ searchController: UISearchController) {
      if client?.presentation?.wrappedValue != true { client?.presentation?.wrappedValue = true }
    }
    func willDismissSearchController(_ searchController: UISearchController) {
      search.searchBar.text = ""
      if let client, !client.query.wrappedValue.isEmpty { client.query.wrappedValue = "" }
      if client?.presentation?.wrappedValue != false { client?.presentation?.wrappedValue = false }
    }
    @objc private func didTap() { search.isActive = false; owner?.view.endEditing(true) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard client != nil, search.isActive, owner?.navigationController?.topViewController === owner else { return false }
      var touched = touch.view
      while let view = touched {
        if view is UIControl || view is UICollectionViewCell || view is UITableViewCell
          || view is UINavigationBar || view is UISearchBar { return false }
        touched = view.superview
      }
      return true
    }
  }
}
