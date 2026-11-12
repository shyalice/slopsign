import SignerCore
import SwiftUI
import UniformTypeIdentifiers

struct WebDAVAccountsView: View {
  @EnvironmentObject var store: AppStore
  @State private var adding = false
  var body: some View {
    List {
      ForEach(store.davAccounts) { account in
        NavigationLink {
          WebDAVFilesView(account: account, directory: account.url)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(account.url.host ?? account.url.absoluteString)
            Text(account.username + " · " + account.url.absoluteString).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .swipeActions {
          Button("Delete", role: .destructive) {
            PasswordVault.remove(account.id)
            store.davAccounts.removeAll { $0.id == account.id }
            do { try store.persist() } catch { store.error = error.localizedDescription }
          }
        }
      }
    }
    .navigationTitle("WebDAV")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add", systemImage: "plus") { adding = true }
      }
    }
    .sheet(isPresented: $adding) { NavigationStack { WebDAVAccountEditor() } }
  }
}
struct WebDAVAccountEditor: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var url = ""
  @State private var username = ""
  @State private var password = ""
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    Form {
      Section {
        TextField("Server", text: $url).keyboardType(.URL).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Username", text: $username).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField("Password", text: $password)
      }
      Section {
        Button(busy ? "Connecting…" : "Connect") { connect() }.disabled(busy || url.isEmpty)
      }
      if let error { Section { Text(error).font(.caption).foregroundStyle(.red) } }
    }
    .navigationTitle("WebDAV")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
    }
  }
  private func connect() {
    guard
      var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(components.scheme ?? ""), components.host != nil
    else {
      error = "Invalid URL"
      return
    }
    if !components.path.hasSuffix("/") { components.path += "/" }
    guard let server = components.url else { return }
    let account = DAVAccount(url: server, username: username)
    let client = WebDAVClient(account: account, password: password)
    busy = true
    Task {
      do {
        _ = try await client.list(server)
        try PasswordVault.set(password, for: account.id)
        store.davAccounts.append(account)
        try store.persist()
        password = ""
        dismiss()
      } catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}
struct WebDAVFilesView: View {
  @EnvironmentObject var store: AppStore
  let account: DAVAccount
  let directory: URL
  @State private var entries: [DAVEntry] = []
  @State private var client: WebDAVClient?
  @State private var busy = false
  @State private var status = ""
  @State private var importing = false
  @State private var newFolder = false
  @State private var name = ""
  @State private var rename: DAVEntry?
  var body: some View {
    List {
      if busy {
        HStack {
          ProgressView()
          Text(status).font(.caption)
        }
      }
      ForEach(entries) { entry in
        Group {
          if entry.isDirectory {
            NavigationLink {
              WebDAVFilesView(account: account, directory: entry.url)
            } label: {
              row(entry)
            }
          } else {
            Button {
              download(entry)
            } label: {
              row(entry)
            }.foregroundStyle(.primary)
          }
        }
        .contextMenu {
          if !entry.isDirectory {
            Button("Download", systemImage: "arrow.down") { download(entry) }
          }
          Button("Rename", systemImage: "pencil") {
            name = entry.name
            rename = entry
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            run("Deleting") { try await client?.remove(entry.url) }
          }
        }
      }
    }
    .navigationTitle(directory.path == account.url.path ? "WebDAV" : directory.lastPathComponent)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button("Upload File") { importing = true }
          Button("Create Directory") {
            name = ""
            newFolder = true
          }
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .task {
      do {
        client = WebDAVClient(account: account, password: try PasswordVault.get(account.id))
        try await reload()
      } catch { store.error = error.localizedDescription }
    }
    .refreshable { do { try await reload() } catch { store.error = error.localizedDescription } }
    .alert("Create Directory", isPresented: $newFolder) {
      TextField("Name", text: $name)
      Button("Create") {
        run("Creating folder") { try await client?.createFolder(name, in: directory) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Rename", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } }))
    {
      TextField("Name", text: $name)
      Button("Save") {
        if let entry = rename {
          run("Renaming") { try await client?.rename(entry.url, to: name) }
          rename = nil
        }
      }
      Button("Cancel", role: .cancel) { rename = nil }
    }
    .importDocuments(
      isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true
    ) { result in
      do {
        let files = DocumentImportBatch(urls: try result.get())
        run("Uploading") {
          for file in files.urls {
            try await client?.upload(
              file, to: directory.appendingPathComponent(file.lastPathComponent))
          }
        }
      } catch { store.error = error.localizedDescription }
    }
  }
  private func row(_ entry: DAVEntry) -> some View {
    HStack(spacing: 12) {
      Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(.cyan).font(
        .title2
      ).frame(width: 34)
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.name)
        if !entry.isDirectory {
          Text(fileSize(entry.size)).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func reload() async throws {
    if let client { entries = try await client.list(directory) }
  }
  private func run(_ label: String, action: @escaping () async throws -> Void) {
    guard !busy else { return }
    busy = true
    status = label
    Task {
      do {
        try await action()
        try await reload()
        store.revision += 1
      } catch { store.error = error.localizedDescription }
      busy = false
    }
  }
  private func download(_ entry: DAVEntry) {
    run("Downloading " + entry.name) {
      let target = store.workspace.unique(entry.name, in: store.workspace.files)
      try await client?.download(entry.url, to: target)
    }
  }
}
