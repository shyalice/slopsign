import ImageIO
import PhotosUI
import SignerCore
import SwiftUI
import UIKit

/// Decode orientation and bound memory before presenting a zoomable image.
enum IconArtwork {
  static func decode(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
      ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
  }
  static func png(_ image: UIImage, pixels: CGFloat = 180) -> Data {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).pngData { _ in
      UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
      image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }
  }
}

struct SigningIconEditor: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let original: UIImage?
  let apply: (UIImage?) -> Void
  @State private var artwork: UIImage?
  @State private var custom: Bool
  @State private var chooseFiles = false
  @State private var pendingImage: UIImage?
  @State private var crop: CropRequest?
  @State private var photo: PhotosPickerItem?
  @State private var loading = false
  @State private var error: String?

  init(original: UIImage?, current: UIImage?, custom: Bool, apply: @escaping (UIImage?) -> Void) {
    self.original = original; self.apply = apply
    _artwork = State(initialValue: current ?? original)
    _custom = State(initialValue: custom)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button {
            if let artwork { crop = CropRequest(image: artwork) }
          } label: {
            VStack(spacing: 12) {
              if let artwork {
                Image(uiImage: artwork).resizable().scaledToFit()
                  .frame(width: 160, height: 160)
                  .clipShape(RoundedRectangle(cornerRadius: 35, style: .continuous))
              } else {
                Image(systemName: "app.dashed").font(.system(size: 90)).frame(width: 160, height: 160)
              }
              Text("Tap to Crop").font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
          }.buttonStyle(.plain).disabled(artwork == nil || loading)
            .accessibilityIdentifier("signing.icon.preview")
        }
        Section {
          PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo") }
          Button("Choose File", systemImage: "folder") { chooseFiles = true }
          Button("Restore Original", systemImage: "arrow.uturn.backward") {
            artwork = original; custom = false
          }.disabled(!custom)
        }
      }
      .navigationTitle("App Icon").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { apply(custom ? artwork : nil); dismiss() }.disabled(loading || custom && artwork == nil)
            .accessibilityIdentifier("signing.icon.done")
        }
      }
      .overlay { if loading { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
      .navigationDestination(item: $crop) { item in
        IconCropScreen(image: item.image) { image in artwork = image; custom = true }
      }
    }
    .sheet(isPresented: $chooseFiles, onDismiss: {
      if let pendingImage { self.pendingImage = nil; crop = CropRequest(image: pendingImage) }
    }) {
      WorkspacePicker(title: "Choose Icon", extensions: ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]) { urls in
        guard let file = urls.first else { return }
        do {
          guard let image = IconArtwork.decode(try Data(contentsOf: file)) else { throw SignerError("Unable to open this image.") }
          pendingImage = image
        } catch { self.error = error.localizedDescription }
      }
    }
    .onChange(of: photo) { _, selected in
      guard let selected else { return }
      loading = true
      Task {
        defer { loading = false; photo = nil }
        do {
          guard let data = try await selected.loadTransferable(type: Data.self), let image = IconArtwork.decode(data) else {
            throw SignerError("Unable to open this photo.")
          }
          crop = CropRequest(image: image)
        } catch { self.error = error.localizedDescription }
      }
    }
    .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) { error = nil }
    } message: { Text(error ?? "") }
  }
}

private struct CropRequest: Identifiable, Hashable {
  let id = UUID()
  let image: UIImage
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct IconCropScreen: View {
  @Environment(\.dismiss) private var dismiss
  @State private var controller: IconCropController
  let apply: (UIImage) -> Void
  init(image: UIImage, apply: @escaping (UIImage) -> Void) {
    _controller = State(initialValue: IconCropController(image: image)); self.apply = apply
  }
  var body: some View {
    IconCropCanvas(controller: controller)
      .navigationTitle("Crop Icon").navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use") { apply(controller.croppedImage()); dismiss() }.accessibilityIdentifier("signing.icon.use")
        }
        ToolbarItemGroup(placement: .bottomBar) {
          Button("Reset") { controller.resetCrop() }
          Spacer()
          Button("Rotate", systemImage: "rotate.left") { controller.rotateImage() }
        }
      }
  }
}

private struct IconCropCanvas: UIViewControllerRepresentable {
  let controller: IconCropController
  func makeUIViewController(context: Context) -> IconCropController { controller }
  func updateUIViewController(_ controller: IconCropController, context: Context) {}
}

/// UIScrollView supplies native pinch/pan inertia; output uses the visible square.
final class IconCropController: UIViewController, UIScrollViewDelegate {
  let scroll = UIScrollView()
  let imageView = UIImageView()
  private var image: UIImage
  private var cropSize: CGSize = .zero
  init(image: UIImage) { self.image = image; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    scroll.delegate = self; scroll.clipsToBounds = true
    scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.accessibilityIdentifier = "signing.icon.crop"
    scroll.layer.borderColor = UIColor.separator.cgColor; scroll.layer.borderWidth = 1 / UIScreen.main.scale
    imageView.image = image; imageView.frame = CGRect(origin: .zero, size: image.size)
    scroll.addSubview(imageView); view.addSubview(scroll)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom)); doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let area = view.bounds.inset(by: view.safeAreaInsets)
    let side = max(1, min(area.width - 32, area.height - 32, 600))
    let frame = CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
    if cropSize != frame.size { scroll.frame = frame; resetCrop() }
    else { scroll.frame = frame }
  }
  func resetCrop() {
    loadViewIfNeeded()
    guard scroll.bounds.width > 0, image.size.width > 0, image.size.height > 0 else { return }
    scroll.minimumZoomScale = 0.0001; scroll.maximumZoomScale = 64
    scroll.setZoomScale(1, animated: false)
    imageView.transform = .identity; imageView.frame = CGRect(origin: .zero, size: image.size)
    scroll.contentSize = image.size
    let minimum = max(scroll.bounds.width / image.size.width, scroll.bounds.height / image.size.height)
    scroll.minimumZoomScale = minimum; scroll.maximumZoomScale = max(minimum * 8, 1)
    scroll.zoomScale = minimum
    cropSize = scroll.bounds.size
    scroll.contentOffset = CGPoint(x: max(0, (scroll.contentSize.width - scroll.bounds.width) / 2),
      y: max(0, (scroll.contentSize.height - scroll.bounds.height) / 2))
  }
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  @objc private func toggleZoom() {
    scroll.setZoomScale(scroll.zoomScale > scroll.minimumZoomScale * 1.1 ? scroll.minimumZoomScale : min(scroll.maximumZoomScale, scroll.minimumZoomScale * 2), animated: true)
  }
  func rotateImage() {
    let size = CGSize(width: image.size.height, height: image.size.width)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let original = image
    image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
      context.cgContext.rotate(by: -.pi / 2)
      original.draw(in: CGRect(x: -original.size.width / 2, y: -original.size.height / 2, width: original.size.width, height: original.size.height))
    }
    imageView.image = image; resetCrop()
  }
  func croppedImage() -> UIImage {
    loadViewIfNeeded(); view.layoutIfNeeded()
    let visible = imageView.convert(scroll.bounds, from: scroll)
    let pixels: CGFloat = 1024
    let factor = pixels / max(1, visible.width)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { _ in
      UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
      image.draw(in: CGRect(x: -visible.minX * factor, y: -visible.minY * factor,
        width: image.size.width * factor, height: image.size.height * factor))
    }
  }
}
