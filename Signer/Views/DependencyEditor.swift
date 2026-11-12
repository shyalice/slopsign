import SwiftUI
import SignerCore

struct DependencyEditor: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let url: URL
  @State private var dependencies: [String] = []
  @State private var selected: String?
  @State private var replacement = ""
  var body: some View {
    List(dependencies, id: \.self) { path in
      Button {
        selected = path
        replacement = path
      } label: { Text(path).font(.footnote.monospaced()).foregroundStyle(.primary) }
    }
    .navigationTitle("Dependencies").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    .alert("Edit Dependency", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
      TextField("Library Path", text: $replacement).autocorrectionDisabled().textInputAutocapitalization(.never)
      Button("Save") {
        guard let old = selected else { return }
        let new = replacement, ws = store.workspace, file = url
        selected = nil
        store.perform("Updating Dependency") { progress in
          try LibraryDependencies.change(file, from: old, to: new, workspace: ws, progress: progress)
        }
      }
      Button("Cancel", role: .cancel) { selected = nil }
    }
    .task { reload() }.onChange(of: store.revision) { _, _ in reload() }
  }
  private func reload() {
    do { dependencies = try LibraryDependencies.list(url) }
    catch { store.error = error.localizedDescription }
  }
}
