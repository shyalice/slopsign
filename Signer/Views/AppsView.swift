import SignerCore
import SwiftUI

struct AppsView: View {
  @EnvironmentObject var store: AppStore
  @State private var search = ""
  @State private var importing = false
  @State private var signing: AppRecord?
  @State private var selected: URLItem?
  @State private var details: AppRecord?
  @State private var share: URLItem?
  @State private var deleting: [AppRecord] = []
  @State private var selection = Set<UUID>()
  @State private var editMode: EditMode = .inactive
  var results: [AppRecord] {
    store.apps.filter {
      (store.appsSegment == 0 ? $0.archivePath == nil : $0.archivePath != nil)
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search))
    }
  }
  private var libraryList: some View {
    List(selection: editMode == .active ? $selection : nil) {
      Section {
      ForEach(results) { app in
        Group {
        if editMode == .active { AppRow(app: app) }
        else { FileActionButton { bounds in
          if let url = try? store.workspace.resolve(app.relativePath) { selected = URLItem(url: url, sourceRect: bounds) }
        } content: { AppRow(app: app).foregroundStyle(.primary) }
        }
        }.tag(app.id)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 67 }
        .listRowSeparator(.visible, edges: .bottom)
        .contextMenu {
          ForEach(actions(for: app)) { action in
            Button(role: action == .delete ? .destructive : nil) { perform(action, app: app) } label: { Label(action.title, systemImage: action.symbol) }
          }
        }
        .swipeActions(allowsFullSwipe: false) { Button("Delete") { deleting = [app] }.tint(.red) }
      }
      }.listSectionSeparator(.hidden, edges: .top)
    }
  }
  private var libraryContent: some View {
    libraryList
    .listStyle(.plain).navigationTitle("Apps").navigationBarTitleDisplayMode(.inline)
    .toolbar(editMode == .active ? .hidden : .visible, for: .tabBar)
    .environment(\.editMode, $editMode)
    .navigationSearch(text: $search)
    .toolbar {
      if editMode == .inactive {
        NativeActionToolbar(context: .apps) { command in
          switch command {
          case .selectFiles: editMode = .active
          case .refreshFiles: store.refreshAppLibrary()
          case .importApp: importing = true
          default: break
          }
        }
      } else {
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { editMode = .inactive; selection = [] } }
        ToolbarItemGroup(placement: .bottomBar) {
          Button(!results.isEmpty && selection == Set(results.map(\.id)) ? "Deselect All" : "Select All") {
            selection = selection == Set(results.map(\.id)) ? [] : Set(results.map(\.id))
          }.disabled(results.isEmpty)
          Spacer()
          Button("Delete", systemImage: "trash", role: .destructive) {
            deleting = results.filter { selection.contains($0.id) }
          }.disabled(selection.isEmpty)
        }
      }
      ToolbarItem(placement: .principal) {
        Picker("App Status", selection: $store.appsSegment) { Text("Unsigned").tag(0); Text("Signed").tag(1) }
          .pickerStyle(.segmented).frame(width: 220).transaction { $0.animation = nil }
          .accessibilityIdentifier("apps.status")
      }
    }
    .onAppear { store.refreshAppLibrary() }
    .onChange(of: editMode) { _, value in store.fileSelectionTab = value == .active ? 1 : nil }
    .onChange(of: store.appsSegment) { _, _ in selection = [] }
    .onChange(of: store.apps) { _, apps in selection.formIntersection(Set(apps.map(\.id))) }
    .onDisappear { if editMode == .active { editMode = .inactive; selection = []; store.fileSelectionTab = nil } }
  }
  var body: some View {
    libraryContent
    .background(FileActionSheet(item: $selected, actions: { url in
      guard let app = store.apps.first(where: { (try? store.workspace.resolve($0.relativePath)) == url }) else { return [] }
      return actions(for: app)
    }, perform: { action, url in
      if let app = store.apps.first(where: { (try? store.workspace.resolve($0.relativePath)) == url }) { perform(action, app: app) }
    }).frame(width: 0, height: 0))
    .sheet(isPresented: $importing) {
      WorkspacePicker(title: "Import App", extensions: ["ipa", "app"]) { urls in if let url = urls.first { store.importApp(url) } }
    }
    .navigationDestination(item: $signing) { app in
      SigningView(app: app, onDone: { signing = nil; store.appsSegment = 1 })
    }
    .onChange(of: signing) { _, app in
      if app != nil { store.signingTab = 1 }
      else if store.signingTab == 1 { store.signingTab = nil }
    }
    .navigationDestination(item: $details) { AppDetailView(app: $0) }
    .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    .alert(deleting.count == 1 ? "Delete App?" : "Delete \(deleting.count) Apps?",
      isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
      Button("Delete", role: .destructive) { store.deleteApps(Set(deleting.map(\.id))); selection.subtract(deleting.map(\.id)); deleting = [] }
      Button("Cancel", role: .cancel) { deleting = [] }
    } message: { Text(deleting.count == 1 ? deleting[0].name : "The selected apps and their IPA files will be deleted.") }
  }
  private func actions(for app: AppRecord) -> [FileAction] {
    var actions: [FileAction] = [.sign]
    if app.signedAt != nil { actions.append(.install) }
    return actions + [.share, .browse, .extractLibraries, .details, .delete]
  }
  private func perform(_ action: FileAction, app: AppRecord) {
    switch action {
    case .sign: signing = app
    case .install: store.install(app)
    case .details: details = app
    case .browse:
      if let url = try? store.workspace.resolve(app.relativePath) { store.appNavigationPath.append(url) }
    case .share:
      if let path = app.archivePath ?? app.sourcePath, let url = try? store.workspace.resolve(path) { share = URLItem(url: url) }
      else if let url = try? store.workspace.resolve(app.relativePath) { package(url) }
    case .extractLibraries:
      let ws = store.workspace
      store.perform("Extracting Libraries") { progress in
        let source = try ws.resolve(app.relativePath).appendingPathComponent("Frameworks")
        _ = try ws.importFile(source, progress: progress)
      }
    case .delete: deleting = [app]
    default: break
    }
  }
  private func package(_ url: URL) {
    store.packageApp(url)
  }
}
struct AppRow: View {
  @EnvironmentObject var store: AppStore
  let app: AppRecord
  var body: some View {
    HStack(spacing: 13) {
      AppGlyph(url: try? store.workspace.resolve(app.relativePath))
      VStack(alignment: .leading, spacing: 5) {
        Text(app.name).font(.headline)
        Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        HStack(spacing: 6) {
          Text(app.version)
          if app.signedAt != nil {
            Label("Signed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
          } else if app.modifiedOnly {
            Text("Not signed").foregroundStyle(.orange)
          }
        }.font(.caption2)
      }.padding(.vertical, 5)
    }
  }
}
struct AppDetailView: View {
  @EnvironmentObject var store: AppStore
  let app: AppRecord
  @State private var signing = false
  @State private var share: URLItem?
  @State private var libraries: [String] = []
  @State private var extracting = false
  var appURL: URL? { try? store.workspace.resolve(app.relativePath) }
  var body: some View {
    List {
      Section("App") {
        LabeledContent("Name", value: app.name)
        LabeledContent("Bundle ID", value: app.bundleID)
        LabeledContent("Version", value: app.version)
        if let url = appURL {
          LabeledContent("Size", value: fileSize(store.workspace.size(url)))
          NavigationLink("Show in Files") { FilesView(directory: url) }
          NavigationLink("Info.plist") {
            TextFileEditor(url: url.appendingPathComponent("Info.plist"))
          }
        }
        LabeledContent(
          "Imported", value: app.importedAt.formatted(date: .abbreviated, time: .shortened))
      }
      if let date = app.signedAt {
        Section("Sign App") {
          LabeledContent("Signed", value: date.formatted(date: .abbreviated, time: .shortened))
          Text(app.certificateName ?? "").font(.subheadline)
        }
      }
      if let archive = app.archivePath, let url = try? store.workspace.resolve(archive) {
        Section("IPA") {
          Button("Share", systemImage: "square.and.arrow.up") {
            share = URLItem(url: url)
          }
          if app.signedAt != nil {
            Button("Install", systemImage: "arrow.down.app") { store.install(app) }
          }
        }
      }
      Section("Libraries · \(libraries.count)") {
        ForEach(libraries, id: \.self) {
          Text($0).font(.caption.monospaced()).textSelection(.enabled)
        }
        Button("Extract Libraries", systemImage: "shippingbox") { extractLibraries() }
      }
    }
    .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $signing) { NavigationStack { SigningView(app: app) } }
    .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    .task {
      if let url = appURL {
        do { libraries = try await store.engine.libraries(for: url) } catch {
          store.error = error.localizedDescription
        }
      }
    }
  }
  func extractLibraries() {
    guard let appURL else { return }
    let ws = store.workspace
    store.perform("Extracting Libraries") { progress in
      let source = appURL.appendingPathComponent("Frameworks")
      guard ws.fm.fileExists(atPath: source.path) else {
        throw SignerError("No Frameworks directory found in this app.")
      }
      _ = try ws.importFile(source, progress: progress)
    }
  }
}
