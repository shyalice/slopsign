import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  private var tabBarVisibility: Visibility {
    if store.fileSelectionTab == store.selectedTab { return .hidden }
    return store.selectedTab == 2 && !store.sourceNavigationPath.isEmpty ? .hidden : .visible
  }
  var body: some View {
    TabView(selection: $store.selectedTab) {
      NavigationStack(path: $store.fileNavigationPath) {
        FilesView(directory: store.workspace.files, isRoot: true)
          .navigationDestination(for: URL.self) { FilesView(directory: $0) }
      }
      .toolbar(tabBarVisibility, for: .tabBar)
      .tabItem { Label("Files", systemImage: "tray") }.tag(0)
      NavigationStack(path: $store.appNavigationPath) {
        AppsView().navigationDestination(for: URL.self) { FilesView(directory: $0) }
      }
      .toolbar(tabBarVisibility, for: .tabBar)
      .tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(1)
      NavigationStack(path: $store.sourceNavigationPath) {
        AppCatalogView()
          .navigationDestination(for: SourceNavigationRoute.self) { _ in SourcesView() }
      }
      .toolbar(tabBarVisibility, for: .tabBar)
      .tabItem { Label("App Store", systemImage: "a.circle") }.tag(2)
      NavigationStack { DownloadsView(center: store.transfers) }
          .toolbar(tabBarVisibility, for: .tabBar)
          .tabItem { Label("Downloads", systemImage: "arrow.down.to.line") }.tag(3)
      NavigationStack { SettingsView() }
          .toolbar(tabBarVisibility, for: .tabBar)
          .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
    }
    .background(OperationPresentation(isBusy: store.showsProgress, notice: store.notice, error: store.error).frame(width: 0, height: 0))
    .onChange(of: store.selectedTab) { _, tab in if tab == 1 { store.refreshAppLibrary() } }
  }
}
