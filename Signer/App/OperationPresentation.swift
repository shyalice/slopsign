import Combine
import SwiftUI
import UIKit

/// System alerts handle presentation, sizing and animation on each iOS version.
struct OperationPresentation: UIViewControllerRepresentable {
  @EnvironmentObject var store: AppStore
  let isBusy: Bool
  let notice: OperationNotice?
  let error: String?
  func makeUIViewController(context: Context) -> Presenter { Presenter(store: store) }
  func updateUIViewController(_ controller: Presenter, context: Context) { controller.synchronize() }

  final class Presenter: UIViewController {
    let store: AppStore
    private var progressAlert: UIAlertController?
    private var feedbackAlert: UIAlertController?
    private var progressIsInstallation = false
    private var feedbackIsInstallation = false
    private var transitioning = false
    private var cancelled = false
    private var presentedOperation: UUID?
    private var delayedPresentation: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var installationObservation: AnyCancellable?
    private var preparingInstallation: Bool {
      store.installer.active && store.installer.showsProgress && !store.showsProgress
    }
    init(store: AppStore) {
      self.store = store
      super.init(nibName: nil, bundle: nil)
      observation = store.operationStatus.objectWillChange.sink { [weak self] in
        Task { @MainActor in self?.updateProgress() }
      }
      installationObservation = store.installer.objectWillChange.sink { [weak self] in
        Task { @MainActor in self?.synchronize(); self?.updateProgress() }
      }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); synchronize() }
    private var topController: UIViewController? {
      let window = viewIfLoaded?.window ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        .flatMap(\.windows).first(where: \.isKeyWindow)
      guard var top = window?.rootViewController else { return nil }
      while let presented = top.presentedViewController { top = presented }
      return top
    }
    func synchronize() {
      guard !transitioning else { return }
      if presentedOperation != store.operationID {
        presentedOperation = store.operationID
        cancelled = false
      }
      if let alert = feedbackAlert, feedbackIsInstallation, !store.installer.presentsFeedback {
        transitioning = true
        alert.dismiss(animated: true) { [weak self] in
          self?.feedbackAlert = nil
          self?.transitioning = false
          self?.synchronize()
        }
        return
      }
      if let alert = progressAlert,
        progressIsInstallation != preparingInstallation && (store.showsProgress || preparingInstallation) {
        transitioning = true
        alert.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          progressAlert = nil
          transitioning = false
          store.progressPresentationEnded()
          synchronize()
        }
        return
      }
      if store.showsProgress || preparingInstallation {
        guard progressAlert == nil, !cancelled, delayedPresentation == nil else { return }
        delayedPresentation = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(180))
          guard !Task.isCancelled, let self else { return }
          delayedPresentation = nil
          if (store.showsProgress || preparingInstallation), !cancelled { presentProgress() }
        }
        return
      }
      cancelled = false
      delayedPresentation?.cancel()
      delayedPresentation = nil
      if let alert = progressAlert {
        transitioning = true
        alert.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          progressAlert = nil
          transitioning = false
          store.progressPresentationEnded()
          synchronize()
        }
        return
      }
      guard !store.busy else { return }
      store.presentOperationErrors()
      presentFeedback()
    }
    private func presentProgress() {
      guard let top = topController, !(top is UIAlertController) else { return }
      if top.isBeingDismissed || top.isBeingPresented {
        top.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.synchronize() }
        return
      }
      top.view.endEditing(true)
      let installation = preparingInstallation
      progressIsInstallation = installation
      let alert = UIAlertController(title: installation ? "Preparing Installation" : store.operation,
        message: installation ? "Please wait…" : "Please wait…\n0%", preferredStyle: .alert)
      if installation { alert.view.accessibilityIdentifier = "installation.progress" }
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
        guard let self, let alert else { return }
        cancelled = true
        if installation { store.installer.cancel() }
        else { store.cancelOperation() }
        transitioning = true
        alert.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          progressAlert = nil
          transitioning = false
          store.progressPresentationEnded()
          synchronize()
        }
      })
      progressAlert = alert
      store.progressPresentationBegan()
      transitioning = true
      top.present(alert, animated: true) { [weak self] in
        self?.transitioning = false
        self?.updateProgress()
        self?.synchronize()
      }
    }
    private func updateProgress() {
      guard let alert = progressAlert else { return }
      if progressIsInstallation {
        guard preparingInstallation else { return }
        let session = store.installer.session
        alert.title = store.installer.preparing ? "Preparing Installation" : "Installing"
        if session.phase == .transferring { alert.message = "Sending IPA to iOS…\n\(Int(session.progress * 100))%" }
        else { alert.message = store.installer.preparing ? "Please wait…" : "Waiting for iOS…" }
        return
      }
      alert.title = store.operation
      alert.message = store.cancelling ? "Cancelling…" : "Please wait…\n\(Int(min(1, max(0, store.progress)) * 100))%"
    }
    private func presentFeedback() {
      guard feedbackAlert == nil, let top = topController, !(top is UIAlertController) else { return }
      if top.isBeingDismissed || top.isBeingPresented {
        top.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.synchronize() }
        return
      }
      let title: String
      let message: String
      feedbackIsInstallation = false
      if let error = store.error {
        title = "Error"; message = error; store.error = nil; store.notice = nil
      } else if let notice = store.notice {
        title = notice.title; message = notice.message; store.notice = nil
      } else if let feedback = store.installer.feedback {
        title = feedback.title; message = feedback.message; store.installer.feedback = nil
        feedbackIsInstallation = true
      } else { return }
      let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
        self?.feedbackAlert = nil
      })
      feedbackAlert = alert
      top.present(alert, animated: true)
    }
  }
}
