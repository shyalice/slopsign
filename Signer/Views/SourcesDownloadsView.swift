import SignerCore
import SwiftUI

enum SourceNavigationRoute: Hashable {
  case sources
}

struct AppCatalogView: View {
  @EnvironmentObject var store: AppStore
  @State private var search = ""
  var body: some View {
    List {
      ForEach(store.sources) { source in
        ForEach(
          source.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        ) { app in
          SourceAppRow(app: app, sourceName: source.name)
        }
      }
    }
    .listStyle(.plain)
    .navigationTitle("App Store")
    .toolbar(.visible, for: .tabBar)
    .navigationBarTitleDisplayMode(.inline)
    .navigationSearch(text: $search)
    .toolbar {
      NativeActionToolbar(context: .catalog) { _ in }
    }
    .refreshable {
      for source in store.sources {
        do { try await store.addSource(source.url) } catch {
          store.error = error.localizedDescription
        }
      }
    }
  }
}

struct SourcesView: View {
  @EnvironmentObject var store: AppStore
  @State private var adding = false
  @State private var link = ""
  @State private var loading = false
  @State private var problem: String?
  @State private var editMode: EditMode = .inactive
  @State private var selection = Set<UUID>()
  @State private var openedSource: SourceRecord?
  @State private var deleting = false
  @State private var copied = false
  var body: some View {
    List(selection: editMode.isEditing ? $selection : nil) {
      ForEach(store.sources) { source in
        Group {
          if editMode.isEditing {
            sourceLabel(source)
          } else {
            Button {
              openedSource = source
            } label: {
              sourceLabel(source)
            }
            .buttonStyle(.plain)
          }
        }
        .tag(source.id)
        .swipeActions {
          Button("Delete", role: .destructive) {
            remove([source.id])
          }
        }
        .contextMenu {
          Button("Share", systemImage: "square.and.arrow.up") { share([source.url]) }
          Button("Delete", systemImage: "trash", role: .destructive) { remove([source.id]) }
        }
      }
    }
    .listStyle(.plain)
    .navigationTitle("App Sources")
    .toolbar(.hidden, for: .tabBar)
    .navigationBarTitleDisplayMode(.inline)
    .environment(\.editMode, $editMode)
    .navigationDestination(item: $openedSource) { SourceAppsView(source: $0) }
    .onChange(of: store.sources.map(\.id)) { _, ids in
      selection.formIntersection(ids)
    }
    .toolbar {
      NativeActionToolbar(context: .sources) { _ in
        problem = nil
        adding = true
      }
      ToolbarItemGroup(placement: .bottomBar) {
        if editMode.isEditing {
          Button(
            selection.count == store.sources.count && !selection.isEmpty
              ? "Deselect All" : "Select All"
          ) {
            selection = selection.count == store.sources.count ? [] : Set(store.sources.map(\.id))
          }.disabled(store.sources.isEmpty)
          Spacer()
          Button("Share", systemImage: "square.and.arrow.up") {
            share(store.sources.filter { selection.contains($0.id) }.map(\.url))
          }.disabled(selection.isEmpty)
          Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
            .disabled(selection.isEmpty)
          Spacer()
          Button("Done") {
            editMode = .inactive
            selection = []
          }
        } else {
          Spacer()
          Button("Select") { editMode = .active }
            .disabled(store.sources.isEmpty)
        }
      }
    }
    .confirmationDialog(
      "Delete selected sources?", isPresented: $deleting, titleVisibility: .visible
    ) {
      Button("Delete Sources", role: .destructive) { remove(selection) }
    } message: {
      Text("Downloaded apps and files will stay on your device.")
    }
    .alert("Source Links Copied", isPresented: $copied) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Paste the list into Add Source in ESign.")
    }
    .refreshable {
      for source in store.sources {
        do { try await store.addSource(source.url) } catch {
          store.error = error.localizedDescription
        }
      }
    }
    .sheet(isPresented: $adding) {
      NavigationStack {
        Form {
          Section {
            TextField("https://example.com/apps.json", text: $link, axis: .vertical)
              .lineLimit(1...5).keyboardType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .accessibilityIdentifier("source.urls")
            PasteButton(payloadType: String.self) { strings in
              link = strings.joined(separator: "\n")
            }.accessibilityIdentifier("source.paste")
          } header: {
            Text("Source URL")
          } footer: {
            Text("Enter one URL per line, or paste a shared ESign source list.")
          }
          if let problem { Section { Text(problem).font(.caption).foregroundStyle(.red) } }
          Section {
            Button {
              add()
            } label: {
              HStack {
                if loading { ProgressView() }
                Text(loading ? "Loading…" : "Add Source")
              }
            }.disabled(loading || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .navigationTitle("Add Source").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { adding = false }.disabled(loading)
          }
        }
        .interactiveDismissDisabled(loading)
      }
    }
  }
  func sourceLabel(_ source: SourceRecord) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(source.name).font(.body).foregroundStyle(.primary)
      Text(source.url.absoluteString).font(.subheadline).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle)
    }.padding(.vertical, 3)
  }
  func remove(_ ids: Set<UUID>) {
    do { try store.deleteSources(ids) } catch { store.error = error.localizedDescription }
  }
  func share(_ urls: [URL]) {
    UIPasteboard.general.string = SourceShareCodec.encode(urls)
    copied = true
  }
  func add() {
    let urls: [URL]
    do { urls = try SourceShareCodec.urls(from: link) } catch {
      problem = error.localizedDescription
      return
    }
    loading = true
    problem = nil
    Task {
      var failed: [String] = []
      var errors: [String] = []
      for url in urls {
        do { try await store.addSource(url) } catch {
          failed.append(url.absoluteString)
          errors.append(error.localizedDescription)
        }
      }
      loading = false
      link = failed.joined(separator: "\n")
      if failed.isEmpty { adding = false } else { problem = errors.joined(separator: "\n") }
    }
  }
}

struct SourceAppsView: View {
  @EnvironmentObject var store: AppStore
  let source: SourceRecord
  @State private var search = ""
  var current: SourceRecord { store.sources.first { $0.id == source.id } ?? source }
  var body: some View {
    List {
      ForEach(
        current.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
      ) { app in
        SourceAppRow(app: app)
      }
    }
    .listStyle(.plain)
    .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
    .navigationSearch(text: $search)
    .refreshable {
      do { try await store.addSource(source.url) } catch {
        store.error = error.localizedDescription
      }
    }
  }
}

private struct SourceAppRow: View {
  @EnvironmentObject var store: AppStore
  let app: SourceApp
  var sourceName: String? = nil
  var body: some View {
    HStack(spacing: 12) {
      AsyncImage(url: app.iconURL) { img in
        img.resizable().scaledToFill()
      } placeholder: {
        Image(systemName: "app").font(.title).foregroundStyle(.secondary)
      }
      .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 3) {
        Text(app.name).font(.body)
        Text([app.version, sourceName].compactMap { $0 }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary)
        if !app.subtitle.isEmpty {
          Text(app.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer()
      Button {
        store.transfers.start(app.downloadURL, name: app.name + ".ipa")
        store.selectedTab = 3
      } label: {
        Image(systemName: "arrow.down.circle").font(.title2)
      }
      .accessibilityLabel("Download " + app.name).buttonStyle(.borderless)
    }.padding(.vertical, 3)
  }
}

struct DownloadsView: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var center: DownloadCenter
  @State private var adding = false
  @State private var link = ""
  var body: some View {
    List {
      ForEach(center.items) { item in
        Section {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
              Image(systemName: item.file == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                .font(.title2).foregroundStyle(.teal)
              VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.medium))
                Text(item.url.host ?? "").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if !item.finished {
                Button {
                  center.cancel(item.id)
                } label: {
                  Image(systemName: "xmark.circle")
                }
              }
            }
            if !item.finished {
              ProgressView(value: item.progress)
              Text(
                fileSize(item.received)
                  + (item.expected > 0 ? " of " + fileSize(item.expected) : "")
              ).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(item.state).font(.caption).foregroundStyle(.secondary)
            if let file = item.file {
              if file.pathExtension.lowercased() == "ipa" {
                Button("Add to App Library") { store.importApp(file) }
              }
              ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
            } else if item.finished {
              Button("Retry") { center.retry(item) }
            }
          }.padding(.vertical, 5)
        }
      }
    }.listStyle(.plain).navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
        .toolbar {
        NativeActionToolbar(context: .downloads) { _ in adding = true }
      }
      .alert("Download URL", isPresented: $adding) {
        TextField("https://…", text: $link).keyboardType(.URL).textInputAutocapitalization(.never)
        Button("Download") {
          guard let url = URL(string: link), ["https", "http"].contains(url.scheme ?? "") else {
            store.error = "Enter a valid HTTP or HTTPS URL."
            return
          }
          center.start(url)
          link = ""
        }
        Button("Cancel", role: .cancel) {}
      }
  }
}
