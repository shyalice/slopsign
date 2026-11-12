import SignerCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

extension View {
  func importDocuments(
    isPresented: Binding<Bool>, allowedContentTypes: [UTType],
    allowsMultipleSelection: Bool = false,
    completion: @escaping (Result<[URL], Error>) -> Void
  ) -> some View {
    background(DocumentPicker(
      isPresented: isPresented, types: allowedContentTypes,
      multiple: allowsMultipleSelection, completion: completion).frame(width: 0, height: 0))
  }
}

/// Present the picker directly. UIDocumentPicker manages its own dismissal;
/// nesting it in a SwiftUI sheet can dismiss the sheet before delivery of URLs.
private struct DocumentPicker: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let types: [UTType]
  let multiple: Bool
  let completion: (Result<[URL], Error>) -> Void
  func makeUIViewController(context: Context) -> PickerPresenter {
    PickerPresenter(configuration: self)
  }
  func updateUIViewController(_ controller: PickerPresenter, context: Context) {
    controller.configuration = self
    controller.presentIfNeeded()
  }

  final class PickerPresenter: UIViewController, UIDocumentPickerDelegate,
    UIAdaptivePresentationControllerDelegate
  {
    var configuration: DocumentPicker
    private var picker: UIDocumentPickerViewController?
    private var finishing = false
    private var presentation: Task<Void, Never>?
    init(configuration: DocumentPicker) {
      self.configuration = configuration
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      presentIfNeeded()
    }
    func presentIfNeeded() {
      guard configuration.isPresented, picker == nil, presentation == nil, viewIfLoaded?.window != nil else { return }
      // A Menu action arrives before UIKit has dismissed the menu. Presenting
      // synchronously can interrupt that dismissal and lose the picker request.
      presentation = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard let self, !Task.isCancelled else { return }
        presentation = nil
        showPicker()
      }
    }
    private func showPicker() {
      guard configuration.isPresented, picker == nil, let window = viewIfLoaded?.window,
        var owner = window.rootViewController else { return }
      while let presented = owner.presentedViewController { owner = presented }
      if owner.isBeingPresented || owner.isBeingDismissed || owner is UIAlertController {
        presentIfNeeded()
        return
      }
      let controller = UIDocumentPickerViewController(
        forOpeningContentTypes: configuration.types, asCopy: true)
      controller.allowsMultipleSelection = configuration.multiple
      controller.delegate = self
      picker = controller
      owner.present(controller, animated: true)
      controller.presentationController?.delegate = self
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      finish(urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      finish(nil)
    }
    private func finish(_ urls: [URL]?) {
      guard picker != nil, !finishing else { return }
      finishing = true
      // Acquire access immediately, before any dismissal or executor hop.
      let batch = urls.map { DocumentImportBatch(urls: $0) }
      let deliver = { [self] in
        picker = nil
        configuration.isPresented = false
        finishing = false
        guard let batch else { return }
        if batch.urls.isEmpty {
          configuration.completion(.failure(SignerError("The file provider did not return any files. Please try again.")))
        } else {
          configuration.completion(.success(batch.urls))
        }
      }
      if let controller = picker, controller.isBeingDismissed,
        let transition = controller.transitionCoordinator {
        transition.animate(alongsideTransition: nil) { _ in deliver() }
      } else if let controller = picker, controller.presentingViewController != nil {
        controller.dismiss(animated: true, completion: deliver)
      } else {
        deliver()
      }
    }
  }
}
