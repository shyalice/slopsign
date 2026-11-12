import SignerCore
import SwiftUI

struct SigningRequest: Identifiable, Hashable {
  let id = UUID()
  let app: AppRecord
  let options: SigningOptions
  let certificate: CertificateRecord?
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Continuous output and fixed completion controls, matching ESign's workflow.
struct SigningProcessView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let request: SigningRequest
  @ObservedObject var status: OperationStatus
  var onDone: (() -> Void)? = nil
  @State private var started = false
  @State private var finished = false
  @State private var result: AppRecord?
  @State private var runID = UUID()
  @ScaledMetric(relativeTo: .body) private var actionLabelHeight = 22.0
  var body: some View {
    SigningOutput(lines: status.signingLog, runID: runID)
    .background(Color(uiColor: .systemBackground))
    .navigationTitle(request.options.modifyOnly ? "Save Changes" : "Signing")
    .navigationBarTitleDisplayMode(.inline)
    .background(SigningNavigation().frame(width: 0, height: 0))
    .navigationBarBackButtonHidden(!finished)
    .signingActionBar {
      VStack(spacing: 12) {
        if !finished {
          ProgressView(value: min(1, max(0, status.stageFraction)))
          HStack {
            Text(status.cancelling ? "Cancelling…" : status.currentTaskTitle).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { store.cancelOperation() }.disabled(status.cancelling)
          }
        } else {
          HStack(spacing: 12) {
            SigningActionButton(title: "Done") { if let onDone { onDone() } else { dismiss() } }.frame(maxWidth: .infinity)
            SigningActionButton(title: "Sign Again") { store.installer.cancel(); finished = false; result = nil; runID = UUID() }.frame(maxWidth: .infinity)
            if let result, !result.modifiedOnly {
              InstallationButton(app: result, coordinator: store.installer, height: actionLabelHeight)
            }
          }.frame(height: 48)
        }
      }
      .accessibilityIdentifier("signing.actions")
    }
    .task(id: runID) {
      guard !started || !finished else { return }
      started = true
      result = await store.sign(request.app, options: request.options, certificate: request.certificate, onFailure: {
        status.signingLog.append(SigningLogLine(text: $0, isError: true))
      })
      if result == nil, !status.signingLog.contains(where: \.isError) {
        status.signingLog.append(SigningLogLine(text: "Cancelled", isError: false))
      }
      finished = true
      if let result, !request.options.modifyOnly, request.options.installAfterSigning == true { store.install(result) }
    }
  }
}

private struct InstallationButton: View {
  @EnvironmentObject var store: AppStore
  let app: AppRecord
  @ObservedObject var coordinator: InstallationCoordinator
  let height: Double
  var body: some View {
    SigningActionButton(title: coordinator.preparing ? "Preparing…" : coordinator.session.phase == .transferring ? "Installing…" : coordinator.active ? "Waiting…" : "Install",
      prominent: true, enabled: !coordinator.active) { store.install(app) }
      .frame(maxWidth: .infinity).frame(height: 48)
  }
}
