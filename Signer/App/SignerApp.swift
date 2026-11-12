import SwiftUI

@main
struct SignerApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = AppStore()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      RootView().environmentObject(store)
        .preferredColorScheme(store.appearance == 1 ? .light : store.appearance == 2 ? .dark : nil)
        .tint(.blue)
        .onAppear { appDelegate.connectFileReceiver { [weak store] url in store?.receive(url) } }
        .onOpenURL { appDelegate.accept($0) }
        .onChange(of: scenePhase, initial: true) { _, phase in
          if phase == .active { store.recoverInbox(); store.refreshAppLibrary() }
        }
    }
  }
}
