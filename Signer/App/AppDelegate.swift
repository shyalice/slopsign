import UIKit
import SignerCore

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  private var receiver: ((URL) -> Void)?
  private var waiting: [DocumentImportBatch] = []

  func connectFileReceiver(_ receive: @escaping (URL) -> Void) {
    receiver = receive
    let batches = waiting
    waiting.removeAll()
    for batch in batches { batch.urls.forEach(receive) }
  }
  static weak var current: AppDelegate?
  override init() { super.init(); Self.current = self }
  func accept(_ url: URL) {
    if let receiver { receiver(url) }
    else { waiting.append(DocumentImportBatch(urls: [url])) }
  }
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
    if session.role == .windowApplication { configuration.delegateClass = FileSceneDelegate.self }
    return configuration
  }
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = options?[.url] as? URL { accept(url) }
    return true
  }
  func application(
    _ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.isFileURL || url.scheme == "signer" else { return false }
    accept(url)
    return true
  }
  func application(
    _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    UserDefaults.standard.bool(forKey: "lockVertical") ? .portrait : .allButUpsideDown
  }
}

/// Quick Look / Open In can deliver its document only to the scene lifecycle.
/// Handle both a new scene's connection options and a running scene's URLs.
@MainActor
final class FileSceneDelegate: NSObject, UIWindowSceneDelegate {
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    for context in options.urlContexts { AppDelegate.current?.accept(context.url) }
  }
  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    for context in contexts { AppDelegate.current?.accept(context.url) }
  }
}
