import SwiftUI
import UIKit
import SignerCore

enum FileAction: String, Identifiable {
  case importCertificate, importApp, unzip, view, share, copy, move, compress, text, hex, rename, delete
  case sign, packageIPA, classDump, browse, details, extractLibraries, install, dependencies
  static func tapActions(for kind: WorkspaceFileKind) -> [FileAction] {
    switch kind {
    case .app: return [.sign, .packageIPA, .classDump, .browse]
    case .framework: return [.browse, .classDump, .dependencies]
    case .dylib: return [.classDump, .dependencies, .hex]
    case .ipa: return [.install, .importApp, .unzip, .hex]
    case .archive: return [.unzip, .hex]
    case .profile: return [.importCertificate, .view, .hex]
    case .identity: return [.importCertificate, .view, .hex]
    case .plist: return [.text, .hex]
    case .text: return [.view, .text, .hex]
    case .preview: return [.view]
    case .binary: return [.hex]
    case .folder: return [.browse]
    }
  }
  var id: String { rawValue }
  var title: String {
    switch self {
    case .importCertificate: return "Import"
    case .importApp: return "Add to App Library"
    case .unzip: return "Unzip"
    case .view: return "View"
    case .share: return "Share"
    case .copy: return "Copy to"
    case .move: return "Move to"
    case .compress: return "Compress"
    case .text: return "Text / Plist Editor"
    case .hex: return "HEX Editor"
    case .rename: return "Rename"
    case .delete: return "Delete"
    case .sign: return "Sign"
    case .packageIPA: return "Package IPA"
    case .classDump: return "Class Dump"
    case .browse: return "View Files"
    case .details: return "Details"
    case .extractLibraries: return "Extract Libraries"
    case .install: return "Install"
    case .dependencies: return "Edit Dependencies"
    }
  }
  var symbol: String {
    switch self {
    case .importCertificate: return "square.and.arrow.down"
    case .importApp: return "square.stack.3d.up"
    case .unzip: return "archivebox"
    case .view: return "eye"
    case .share: return "square.and.arrow.up"
    case .copy: return "doc.on.doc"
    case .move: return "folder"
    case .compress: return "doc.zipper"
    case .text: return "curlybraces"
    case .hex: return "number"
    case .rename: return "pencil"
    case .delete: return "trash"
    case .sign: return "signature"
    case .packageIPA: return "doc.zipper"
    case .classDump: return "curlybraces"
    case .browse: return "folder"
    case .details: return "info.circle"
    case .extractLibraries: return "shippingbox"
    case .install: return "arrow.down.app"
    case .dependencies: return "link"
    }
  }
}

/// Finish dismissing the action sheet before presenting an editor, import form,
/// confirmation alert or progress dialog. The selected file is captured once.
struct FileActionSheet: UIViewControllerRepresentable {
  @Binding var item: URLItem?
  let actions: (URL) -> [FileAction]
  let perform: (FileAction, URL) -> Void
  func makeUIViewController(context: Context) -> Presenter { Presenter(configuration: self) }
  func updateUIViewController(_ controller: Presenter, context: Context) {
    controller.configuration = self
    controller.synchronize()
  }
  final class Presenter: UIViewController, UIAdaptivePresentationControllerDelegate {
    var configuration: FileActionSheet
    private var sheet: UIAlertController?
    private var finishing = false
    init(configuration: FileActionSheet) { self.configuration = configuration; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView();view.isUserInteractionEnabled = false }
    func synchronize() {
      guard let item = configuration.item, sheet == nil, !finishing, let window = viewIfLoaded?.window else { return }
      guard var top = window.rootViewController else { return }
      while let presented = top.presentedViewController { top = presented }
      let controller = UIAlertController(title: item.url.lastPathComponent, message: nil, preferredStyle: .actionSheet)
      for action in configuration.actions(item.url) {
        controller.addAction(UIAlertAction(title: action.title, style: action == .delete ? .destructive : .default) { [weak self] _ in
          self?.finish(action, url: item.url)
        })
      }
      controller.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(nil, url: item.url) })
      let anchored: Bool
      if #available(iOS 26.0, *) { anchored = true }
      else { anchored = top.traitCollection.userInterfaceIdiom == .pad }
      if anchored, let popover = controller.popoverPresentationController {
        popover.sourceView = top.view
        let rect = item.sourceRect ?? CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - top.view.safeAreaInsets.bottom, width: 1, height: 1)
        popover.sourceRect = top.view.convert(rect, from: nil)
        popover.permittedArrowDirections = [.up, .down]
      }
      sheet = controller
      top.present(controller, animated: true)
      controller.presentationController?.delegate = self
    }
    private func finish(_ action: FileAction?, url: URL) {
      guard let sheet, !finishing else { return }
      finishing = true
      let deliver = { [self] in
        self.sheet = nil
        configuration.item = nil
        finishing = false
        // Let SwiftUI consume the cleared presentation binding before the next
        // action changes it again (e.g. cancel Import, then tap Unzip).
        if let action { DispatchQueue.main.async { self.configuration.perform(action, url) } }
      }
      if sheet.isBeingDismissed, let transition = sheet.transitionCoordinator {
        transition.animate(alongsideTransition: nil) { _ in deliver() }
      } else if sheet.presentingViewController != nil { sheet.dismiss(animated: true, completion: deliver) }
      else { deliver() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      guard !finishing else { return }
      sheet = nil; configuration.item = nil
    }
  }
}
