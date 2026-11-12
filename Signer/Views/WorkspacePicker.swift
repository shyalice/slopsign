import SignerCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspacePicker: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let title: String
  let extensions: Set<String>
  var multiple = false
  var initialSelection: Set<URL> = []
  let completion: ([URL]) -> Void
  @State private var selection = Set<URL>()
  @State private var importing = false
  @State private var selected: [URL]?
  var body: some View {
    NavigationStack {
      directory(store.workspace.files)
        .navigationDestination(for: URL.self) { directory($0) }

    }
    .onAppear { selection = initialSelection }
    .importDocuments(isPresented: $importing, allowedContentTypes: [.item, .folder],
      allowsMultipleSelection: multiple) { result in
      do {
        let batch = DocumentImportBatch(urls: try result.get())
        Task {
          guard let files = await store.stageResources(batch) else { return }
          let accepted = files.filter { resourceMatches($0, extensions: extensions) }
          guard !accepted.isEmpty else {
            store.error = "Select " + extensions.sorted().map { "." + $0 }.joined(separator: ", ") + "."
            return
          }
          choose(accepted)
        }
      } catch { store.error = error.localizedDescription }
    }
  }
  private func directory(_ url: URL) -> some View {
    DirectoryPicker(directory: url, extensions: extensions, multiple: multiple,
      selection: $selection, choose: choose)
      .navigationTitle(url == store.workspace.files ? title : url.lastPathComponent)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Browse Files", systemImage: "folder.badge.plus") { importing = true }
            .accessibilityIdentifier("workspace.external")
        }
        if multiple {
          ToolbarItem(placement: .confirmationAction) {
            Button("Add") { choose(selection.sorted { $0.path < $1.path }) }.disabled(selection.isEmpty)
              .accessibilityIdentifier("workspace.confirm")
          }
        }
      }
  }
  private func choose(_ urls: [URL]) {
    completion(urls)
    dismiss()
  }
}

private struct DirectoryPicker: View {
  @EnvironmentObject var store: AppStore
  let directory: URL
  let extensions: Set<String>
  let multiple: Bool
  @Binding var selection: Set<URL>
  let choose: ([URL]) -> Void
  @State private var files: [URL] = []
  var body: some View {
    List {
      ForEach(files, id: \.self) { file in
        let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if resourceMatches(file, extensions: extensions) {
          Button {
            if multiple {
              if selection.contains(file) { selection.remove(file) } else { selection.insert(file) }
            } else { choose([file]) }
          } label: {
            HStack {
              FileGlyph(url: file)
              Text(file.lastPathComponent).foregroundStyle(.primary).lineLimit(1)
              Spacer()
              if multiple { Image(systemName: selection.contains(file) ? "checkmark.circle.fill" : "circle") }
            }
          }
        } else if isDirectory {
          NavigationLink(value: file) { Label(file.lastPathComponent, systemImage: "folder.fill") }
        }
      }
    }
    .listStyle(.plain).navigationBarTitleDisplayMode(.inline)
    .overlay {
      if files.isEmpty { ContentUnavailableView("No Matching Files", systemImage: "folder", description: Text("Use Browse Files to import from another app.")) }
    }
    .task { reload() }.onChange(of: store.revision) { _, _ in reload() }
  }
  private func reload() {
    do {
      files = try store.workspace.children(directory).filter {
        resourceMatches($0, extensions: extensions) || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
    } catch { store.error = error.localizedDescription }
  }
}

private func resourceMatches(_ url: URL, extensions: Set<String>) -> Bool {
  if extensions.contains("dylib") || extensions.contains("framework") {
    let kind = FileBehavior.kind(of: url)
    if kind == .dylib && extensions.contains("dylib") { return true }
    if kind == .framework && extensions.contains("framework") { return true }
    if ["dylib", "framework"].contains(url.pathExtension.lowercased()) { return false }
  }
  return extensions.contains(url.pathExtension.lowercased())
}
