import SwiftUI

enum ActionToolbarContext {
  case files(URL)
  case apps, catalog, sources, downloads
}

enum ActionToolbarCommand {
  case importFiles, newFolder, selectFiles, refreshFiles, sortFiles, importApp, addSource,
    addDownload, manageSources
}

/// One native action group lets the navigation bar manage a shared background
/// as items are inserted or removed. No separate toolbar or glass overlay.
struct NativeActionToolbar: ToolbarContent {
  let context: ActionToolbarContext
  let perform: (ActionToolbarCommand) -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      if case .files = context {
        Menu {
          Button("Select", systemImage: "checkmark.circle") { perform(.selectFiles) }
          Button("Sort by Date", systemImage: "arrow.up.arrow.down") { perform(.sortFiles) }
          Button("Refresh", systemImage: "arrow.clockwise") { perform(.refreshFiles) }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("More").accessibilityIdentifier("native.more")
      }
      if case .apps = context {
        Menu {
          Button("Select", systemImage: "checkmark.circle") { perform(.selectFiles) }
          Button("Refresh", systemImage: "arrow.clockwise") { perform(.refreshFiles) }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("More").accessibilityIdentifier("native.more")
      }
      if case .catalog = context {
        NavigationLink(value: SourceNavigationRoute.sources) {
          Label("Sources", systemImage: "list.bullet.rectangle")
        }
          .accessibilityIdentifier("native.sources")
      } else if case .files = context {
        Menu {
          Button("Import Files", systemImage: "square.and.arrow.down") { perform(.importFiles) }
          Button("New Folder", systemImage: "folder.badge.plus") { perform(.newFolder) }
        } label: { Image(systemName: "plus") }
        .accessibilityLabel("Add").accessibilityIdentifier("native.add")
      } else {
        Button("Add", systemImage: "plus") {
          switch context {
          case .apps: perform(.importApp)
          case .sources: perform(.addSource)
          case .downloads: perform(.addDownload)
          default: break
          }
        }.accessibilityIdentifier("native.add")
      }
    }
  }
}
