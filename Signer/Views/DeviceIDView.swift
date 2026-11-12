import SafariServices
import SignerCore
import SwiftUI

struct SafariSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> SFSafariViewController {
    SFSafariViewController(url: url)
  }
  func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
struct DeviceIDView: View {
  @EnvironmentObject var store: AppStore
  @AppStorage("deviceUDID") private var udid = ""
  @State private var safari: URLItem?
  @State private var error: String?
  var body: some View {
    List {
      Section {
        if udid.isEmpty {
          Text("UDID not obtained").foregroundStyle(.secondary)
        } else {
          Text(udid).font(.footnote.monospaced()).textSelection(.enabled)
        }
        Button(udid.isEmpty ? "Get Device UDID" : "Reacquire") { acquire() }
        if !udid.isEmpty {
          Button("Copy UDID", systemImage: "doc.on.doc") { UIPasteboard.general.string = udid }
        }
      }
    }
    .navigationTitle("Get Device UDID")
    .onReceive(store.udidServer.$deviceUDID) { value in
      guard let value else { return }
      udid = value
      safari = nil
      try? BackgroundKeeper.shared.set(false, owner: "udid")
    }
    .sheet(item: $safari) { SafariSheet(url: $0.url) }
    .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) { error = nil }
    } message: {
      Text(error ?? "")
    }
  }
  private func acquire() {
    do {
      try store.udidServer.startEnrollment()
      try BackgroundKeeper.shared.set(true, owner: "udid")
      safari = URLItem(url: URL(string: "http://127.0.0.1:14302/")!)
    } catch { self.error = error.localizedDescription }
  }
}
