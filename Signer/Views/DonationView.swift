import CoreImage.CIFilterBuiltins
import SwiftUI

struct DonationView: View {
  let network: String
  let address: String
  @State private var copied = false
  private var qr: UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(address.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: image)
  }
  var body: some View {
    List {
      if let qr {
        Section {
          HStack {
            Spacer()
            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
              .frame(width: 190, height: 190).padding(16).background(.white)
              .accessibilityLabel("\(network) donation address QR code")
            Spacer()
          }.padding(.vertical, 12)
        }
      }
      Section("Address") {
        Text(address).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        Button(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
        {
          UIPasteboard.general.string = address
          copied = true
        }
        ShareLink(item: address) { Label("Share Address", systemImage: "square.and.arrow.up") }
      }
    }
    .navigationTitle(network)
    .navigationBarTitleDisplayMode(.inline)
  }
}
