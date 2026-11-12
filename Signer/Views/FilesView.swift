import SignerCore
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
  @EnvironmentObject var store: AppStore
  let directory: URL
  var isRoot = false
  @State private var files: [URL] = []
  @State private var search = ""
  @State private var searchPresented = false
  @State private var importing = false
  @State private var folderPrompt = false
  @State private var name = ""
  @State private var renameURL: URL?
  @State private var share: URLItem?
  @State private var preview: URLItem?
  @State private var appAction: URLItem?
  @State private var certificateImport: URLItem?
  @State private var identityPreview: URLItem?
  @State private var signing: AppRecord?
  @State private var editor: URLItem?
  @State private var hex: URLItem?
  @State private var dependencies: URLItem?
  @State private var selection = Set<URL>()
  @State private var editMode: EditMode = .inactive
  @State private var deletePrompt = false
  @State private var deletionTargets: [URL] = []
  @State private var sortByDate = false
  var filtered: [URL] {
    let matched = files.filter {
      search.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(search)
    }
    return sortByDate
      ? matched.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
          > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast)
      } : matched
  }
  var body: some View {
    ScrollViewReader { reader in
      filePresentations
    .onChange(of: store.importedFiles) { _, imported in
      if let received = imported.first(where: { $0.deletingLastPathComponent() == directory }) {
        search = ""
        searchPresented = false
        DispatchQueue.main.async { reader.scrollTo(received, anchor: .center) }
      }
    }
    }
  }
  private var fileOperations: some View {
    fileList
    .safeAreaInset(edge: .bottom) {
      if let clipboard = store.clipboard {
        HStack {
          Image(systemName: clipboard.move ? "folder" : "doc.on.doc")
          Text(clipboard.url.lastPathComponent).lineLimit(1).font(.caption)
          Spacer()
          Button("Paste") {
            let ws = store.workspace
            store.perform("Moving Files") { progress in
              try ws.copy(clipboard.url, to: directory, move: clipboard.move, progress: progress)
            }
            store.clipboard = nil
          }
          Button {
            store.clipboard = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
        }.padding().glassPanel().padding(12)
      }
    }
    .onAppear { reload() }
    .onChange(of: editMode) { _, mode in store.fileSelectionTab = mode == .active ? store.selectedTab : nil }
    .onDisappear { if editMode == .active { store.fileSelectionTab = nil; editMode = .inactive; selection = [] } }
    .onChange(of: store.revision) { _, _ in reload() }
    .importDocuments(
      isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true
    ) { result in
      do { store.importFiles(try result.get(), to: directory) } catch {
        store.error = error.localizedDescription
      }
    }
    .alert("New Folder", isPresented: $folderPrompt) {
      TextField("Name", text: $name)
      Button("Create") {
        do {
          guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw SignerError("Invalid folder name.")
          }
          try store.workspace.fm.createDirectory(
            at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
          reload()
        } catch { store.error = error.localizedDescription }
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert(
      "Rename",
      isPresented: Binding(get: { renameURL != nil }, set: { if !$0 { renameURL = nil } })
    ) {
      TextField("Name", text: $name)
      Button("Save") {
        if let url = renameURL {
          do {
            try store.workspace.rename(url, to: name)
            renameURL = nil
            reload()
          } catch { store.error = error.localizedDescription }
        }
      }
      Button("Cancel", role: .cancel) { renameURL = nil }
    }
    .alert(deletionTargets.count == 1 ? "Delete \(deletionTargets.first?.lastPathComponent ?? "File")?" : "Delete \(deletionTargets.count) Files?", isPresented: $deletePrompt) {
      Button("Delete", role: .destructive) {
        let targets = deletionTargets
        let ws = store.workspace
        selection = []
        store.perform("Deleting Files", inDialog: false) { progress in
          progress.totalUnitCount = Int64(targets.count)
          for url in targets {
            try FileTransfer.check(progress)
            try ws.remove(url, progress: progress)
            progress.completedUnitCount += 1
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone.")
    }
  }
  private var filePresentations: some View {
    fileOperations
    .background(FileActionSheet(item: $appAction, actions: tapActions, perform: performFileAction).frame(width: 0, height: 0))
    .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    .sheet(item: $preview) { QuickLookSheet(url: $0.url) }
    .sheet(item: $editor) { item in NavigationStack { TextFileEditor(url: item.url) } }
    .sheet(item: $hex) { item in NavigationStack { HexEditor(url: item.url) } }
    .sheet(item: $dependencies) { item in NavigationStack { DependencyEditor(url: item.url) } }
    .sheet(item: $certificateImport) { item in NavigationStack { CertificateImportView(initialFile: item.url) } }
    .sheet(item: $identityPreview) { item in NavigationStack { CertificateFileView(url: item.url) } }
    .navigationDestination(item: $signing) { app in SigningView(app: app, onDone: { signing = nil }) }
    .onChange(of: signing) { _, app in
      if app != nil { store.signingTab = store.selectedTab }
      else { store.signingTab = nil }
    }
  }
  private var fileList: some View {
    List(selection: editMode == .active ? $selection : nil) {
      Section {
        ForEach(filtered, id: \.self) { url in
          row(url).tag(url)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .contextMenu { menu(url) }
            .swipeActions(allowsFullSwipe: false) {
              Button("Delete") {
                requestDeletion([url])
              }.tint(.red)
            }
        }
      }.listSectionSeparator(.hidden, edges: .top)

    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 44)
    .navigationTitle(isRoot ? "Files" : directory.lastPathComponent)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(editMode == .active ? .hidden : .visible, for: .tabBar)
    .navigationSearch(text: $search, isPresented: $searchPresented)
    .environment(\.editMode, $editMode)
    .toolbar {
      NativeActionToolbar(context: .files(directory), perform: handleToolbar)
      if editMode == .active {
        ToolbarItemGroup(placement: .bottomBar) {
          Button(selection.count == filtered.count && !filtered.isEmpty ? "Deselect All" : "Select All") {
            selection = selection.count == filtered.count ? [] : Set(filtered)
          }
          Spacer()
          Button("Share", systemImage: "square.and.arrow.up") {
            if let first = selection.first { share = URLItem(url: first) }
          }.disabled(selection.count != 1)
          Button("Delete", systemImage: "trash", role: .destructive) { requestDeletion(Array(selection)) }
            .disabled(selection.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { editMode = .inactive; selection = [] } }
      }
    }
  }
  private func handleToolbar(_ command: ActionToolbarCommand) {
    switch command {
    case .importFiles: importing = true
    case .newFolder:
      name = ""
      folderPrompt = true
    case .selectFiles:
      editMode = editMode == .active ? .inactive : .active
      selection = []
    case .refreshFiles: reload()
    case .sortFiles: sortByDate.toggle()
    default: break
    }
  }
  @ViewBuilder func row(_ url: URL) -> some View {
    let kind = FileBehavior.kind(of: url)
    if kind == .folder {
      NavigationLink(value: url) {
        fileLabel(url, directory: true)
      }
    } else {
      FileActionButton { bounds in
        open(url, sourceRect: bounds)
      } content: {
        fileLabel(url, directory: false)
      }.foregroundStyle(.primary)
    }
  }
  func fileLabel(_ url: URL, directory: Bool) -> some View {
    HStack(spacing: 12) {
      FileGlyph(url: url)
      Text(url.lastPathComponent).font(.body).lineLimit(1)
      Spacer(minLength: 0)
    }
  }
  func detail(_ url: URL, directory: Bool) -> String {
    if directory { return (url.pathExtension == "app" ? "App File · " : "") + "Folder" }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return fileSize(Int64(values?.fileSize ?? 0)) + " · "
      + (values?.contentModificationDate?.formatted(date: .abbreviated, time: .omitted) ?? "")
  }
  func fileActions(_ url: URL) -> [FileAction] {
    let ext = url.pathExtension.lowercased()
    let kind = FileBehavior.kind(of: url)
    var actions: [FileAction] = []
    if ["p12", "pfx", "mobileprovision", "provisionprofile"].contains(ext) { actions.append(.importCertificate) }
    if kind == .app || kind == .ipa { actions.append(.importApp) }
    if canInstall(url) { actions.append(.install) }
    if kind == .archive || kind == .ipa { actions.append(.unzip) }
    actions += [.view, .share, .copy, .move, .compress]
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { actions += [.text, .hex] }
    return actions + [.rename, .delete]
  }
  func tapActions(_ url: URL) -> [FileAction] {
    FileAction.tapActions(for: FileBehavior.kind(of: url))
  }
  private func canInstall(_ url: URL) -> Bool {
    FileBehavior.kind(of: url) == .ipa
  }
  @ViewBuilder func menu(_ url: URL) -> some View {
    ForEach(fileActions(url)) { action in
      Button(role: action == .delete ? .destructive : nil) { performFileAction(action, url) } label: {
        Label(action.title, systemImage: action.symbol)
      }
    }
  }
  func performFileAction(_ action: FileAction, _ url: URL) {
    switch action {
    case .sign:
      do { signing = try store.workspace.record(for: url) } catch { store.error = error.localizedDescription }
    case .packageIPA: store.packageApp(url)
    case .classDump: store.dumpClasses(url)
    case .dependencies: dependencies = URLItem(url: url)
    case .browse:
      if store.selectedTab == 1 { store.appNavigationPath.append(url) }
      else { store.fileNavigationPath.append(url) }
    case .importCertificate: certificateImport = URLItem(url: url)
    case .importApp: store.importApp(url)
    case .install: store.installArchive(url)
    case .unzip: unpack(url)
    case .view:
      if FileBehavior.kind(of: url) == .profile { editor = URLItem(url: url) }
      else if FileBehavior.kind(of: url) == .identity { identityPreview = URLItem(url: url) }
      else { preview = URLItem(url: url) }
    case .share: share = URLItem(url: url)
    case .copy: store.clipboard = (url, false)
    case .move: store.clipboard = (url, true)
    case .compress:
      let ws = store.workspace
      store.perform("Compressing") { progress in _ = try ws.compress(url, progress: progress) }
    case .text: editor = URLItem(url: url)
    case .hex: hex = URLItem(url: url)
    case .rename: name = url.lastPathComponent; renameURL = url
    case .delete: requestDeletion([url])
    case .details, .extractLibraries: break
    }
  }
  func open(_ url: URL, sourceRect: CGRect? = nil) {
    if FileBehavior.kind(of: url) == .preview { preview = URLItem(url: url) }
    else { appAction = URLItem(url: url, sourceRect: sourceRect) }
  }
  private func requestDeletion(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    deletionTargets = urls
    deletePrompt = true
  }
  func unpack(_ url: URL) {
    let ws = store.workspace
    store.perform("Unzipping") { progress in _ = try ws.unpack(url, progress: progress) }
  }
  func reload() {
    do {
      let updated = try store.workspace.children(directory)
      if files != updated { files = updated }
    } catch {
      store.error = error.localizedDescription
    }
  }
}
