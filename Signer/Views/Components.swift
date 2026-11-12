import QuickLook
import SignerCore
import SwiftUI
import UIKit

extension View {
  @ViewBuilder func glassPanel() -> some View {
    if #available(iOS 26.0, *) {
      self.glassEffect(.regular, in: .rect(cornerRadius: 24))
    } else {
      self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
  }
}
struct FileGlyph: View {
  let url: URL
  var large = false
  @State private var appIcon: UIImage?
  private var isApp: Bool { ["app", "ipa", "tipa"].contains(url.pathExtension.lowercased()) || url.lastPathComponent.lowercased().hasSuffix(".ipa.rename") }
  var isDirectory: Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
  }
  var symbol: String {
    switch url.pathExtension.lowercased() {
    case "app", "ipa": return "app.badge.fill"
    case "p12", "pfx", "mobileprovision": return "checkmark.seal.fill"
    case "zip", "deb", "tar", "gz": return "archivebox.fill"
    case "framework", "dylib": return "shippingbox.fill"
    case "plist", "json", "xml": return "curlybraces"
    case "png", "jpg", "jpeg", "heic": return "photo.fill"
    default: return isDirectory ? "folder.fill" : "doc.fill"
    }
  }
  var body: some View {
    Group {
      if let appIcon {
        Image(uiImage: appIcon).resizable().scaledToFill()
          .frame(width: large ? 48 : 36, height: large ? 48 : 36)
          .clipShape(RoundedRectangle(cornerRadius: large ? 11 : 8))
      } else { Image(systemName: symbol)
      .font(.system(size: large ? 36 : 26, weight: .regular))
      .foregroundStyle(isDirectory ? Color.blue : Color.secondary)
      }
    }.frame(width: large ? 48 : 36, height: large ? 48 : 36)
      .task(id: url) {
        guard isApp else { return }
        if let data = await AppIconCache.shared.data(for: url) { appIcon = UIImage(data: data) }
      }
  }
}

struct AppGlyph: View {
  let url: URL?
  var size: CGFloat = 54
  @State private var loadedIcon: UIImage?
  var icon: UIImage? {
    guard let url,
      let data = try? AppBundleMetadata.read(url).icon
    else { return nil }
    return UIImage(data: data)
  }
  var body: some View {
    Group {
      if let icon = loadedIcon {
        Image(uiImage: icon).resizable().scaledToFill()
      } else {
        Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.teal)
          .frame(maxWidth: .infinity, maxHeight: .infinity).background(.teal.opacity(0.1))
      }
    }
    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
    .task(id: url) { if let url, let data = await AppIconCache.shared.data(for: url) { loadedIcon = UIImage(data: data) } }
  }
}
struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct QuickLookSheet: UIViewControllerRepresentable {
  let url: URL
  func makeCoordinator() -> Coordinator { Coordinator(url: url) }
  func makeUIViewController(context: Context) -> UINavigationController {
    let v = QLPreviewController()
    v.dataSource = context.coordinator
    v.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak v] _ in
      v?.dismiss(animated: true)
    })
    return UINavigationController(rootViewController: v)
  }
  func updateUIViewController(_ controller: UINavigationController, context: Context) {}
  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> QLPreviewItem
    { url as NSURL }
  }
}
struct URLItem: Identifiable {
  let id = UUID()
  let url: URL
  var sourceRect: CGRect? = nil
}

struct FileActionButton<Content: View>: View {
  let open: (CGRect) -> Void
  @ViewBuilder let content: () -> Content
  @State private var bounds = CGRect.zero
  var body: some View {
    Button { open(bounds) } label: { content() }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds = $0 }
  }
}
struct EmptyState: View {
  let title: String
  let symbol: String
  let detail: String
  var body: some View {
    ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
  }
}
func fileSize(_ bytes: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
