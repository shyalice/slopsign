import SignerCore
import SwiftUI

struct TextFileEditor: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var store: AppStore
  let url: URL
  @State private var text = ""
  @State private var isPlist = false
  @State private var readOnly = false
  @State private var problem: String?
  @State private var dirty = false
  var body: some View {
    VStack(spacing: 0) {
      if let problem { Text(problem).font(.caption).foregroundStyle(.orange).padding() }
      if readOnly {
        Label("Mobileprovision · XML", systemImage: "lock").font(.caption).foregroundStyle(
          .secondary
        ).padding(8)
      }
      TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).autocorrectionDisabled()
        .textInputAutocapitalization(.never).disabled(readOnly)
        .onChange(of: text) { _, _ in dirty = true }
    }
    .navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }.disabled(readOnly || !dirty)
      }
    }
    .task { load() }
  }
  func load() {
    do {
      var data = try Data(contentsOf: url)
      guard data.count <= 8 * 1024 * 1024 else {
        throw SignerError("File exceeds 8 MB. Use HEX Editor or export it.")
      }
      if url.pathExtension == "mobileprovision" {
        let dict = try Certificates.profile(at: url)
        data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        readOnly = true
        isPlist = true
      } else if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
        data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        isPlist = true
      }
      guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
      else { throw SignerError("Binary file. Use HEX Editor.") }
      text = value
      dirty = false
    } catch {
      problem = error.localizedDescription
      readOnly = true
    }
  }
  func save() {
    do {
      var data = Data(text.utf8)
      if isPlist {
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        data = try PropertyListSerialization.data(
          fromPropertyList: value, format: .binary, options: 0)
      } else if url.pathExtension == "json" {
        _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
      }
      try data.write(to: url, options: .atomic)
      dirty = false
      store.revision += 1
      dismiss()
    } catch { problem = error.localizedDescription }
  }
}
struct HexEditor: View {
  @Environment(\.dismiss) private var dismiss
  let url: URL
  @State private var data = Data()
  @State private var offset = "0"
  @State private var bytes = ""
  @State private var error: String?
  @State private var patching = false
  @State private var baseOffset: UInt64 = 0
  @State private var size: UInt64 = 0
  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: 5) {
        Text("Offset   00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F   ASCII").foregroundStyle(
          .secondary)
        ForEach(0..<((data.count + 15) / 16), id: \.self) { row in
          let part = Array(data[(row * 16)..<min(data.count, row * 16 + 16)])
          HStack(spacing: 14) {
            Text(String(format: "%08llX", baseOffset + UInt64(row * 16))).foregroundStyle(.teal)
            Text(part.map { String(format: "%02X", $0) }.joined(separator: " ")).frame(
              width: 350, alignment: .leading)
            Text(String(part.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "·" }))
              .foregroundStyle(.secondary)
          }
        }
      }.font(.system(size: 12, design: .monospaced)).padding()
    }
    .navigationTitle("HEX · \(url.lastPathComponent)").navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Text("\(fileSize(Int64(size))) · 64 KB page").font(.caption)
        Spacer()
        Button("Back") {
          baseOffset = baseOffset >= 65536 ? baseOffset - 65536 : 0
          load()
        }.disabled(baseOffset == 0)
        Button("Next") {
          baseOffset += 65536
          load()
        }.disabled(baseOffset + 65536 >= size)
      }.padding().background(.bar)
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      ToolbarItem(placement: .primaryAction) {
        Button("Edit", systemImage: "pencil") {
          offset = String(baseOffset, radix: 16)
          patching = true
        }
      }
    }
    .alert("Replace Bytes", isPresented: $patching) {
      TextField("Offset (HEX)", text: $offset)
      TextField("Bytes: DE AD BE EF", text: $bytes)
      Button("OK") { patch() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Bytes are replaced in place without changing the file size.")
    }
    .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) { error = nil }
    } message: {
      Text(error ?? "")
    }
    .task { load() }
  }
  func load() {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      size = try handle.seekToEnd()
      try handle.seek(toOffset: baseOffset)
      data = try handle.read(upToCount: 65536) ?? Data()
    } catch { self.error = error.localizedDescription }
  }
  func patch() {
    do {
      let clean = bytes.replacingOccurrences(of: " ", with: "").replacingOccurrences(
        of: "\n", with: "")
      guard let start = UInt64(offset.replacingOccurrences(of: "0x", with: ""), radix: 16),
        !clean.isEmpty, clean.count % 2 == 0
      else { throw SignerError("Enter an offset and complete HEX byte pairs.") }
      var patch = Data()
      var i = clean.startIndex
      while i < clean.endIndex {
        let end = clean.index(i, offsetBy: 2)
        guard let byte = UInt8(clean[i..<end], radix: 16) else {
          throw SignerError("Invalid HEX digits.")
        }
        patch.append(byte)
        i = end
      }
      guard start <= size, UInt64(patch.count) <= size - start else {
        throw SignerError("The replacement exceeds the file bounds.")
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: start)
      try handle.write(contentsOf: patch)
      try handle.synchronize()
      baseOffset = (start / 65536) * 65536
      bytes = ""
      load()
    } catch { self.error = error.localizedDescription }
  }
}
