import SignerCore
import SwiftUI
import UniformTypeIdentifiers

struct SigningView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let app: AppRecord
  var onDone: (() -> Void)? = nil
  @State private var options = SigningOptions()
  @State private var certificateID: UUID?
  @State private var importing = false
  @State private var libraries: [String] = []
  @State private var request: SigningRequest?
  @State private var libraryPicker = false
  @State private var overrides = ""
  @State private var showOverrides = false
  @State private var localError: String?
  @State private var started = false
  @State private var editingIcon = false
  @State private var originalIcon: UIImage?
  @State private var selectedIcon: UIImage?
  @State private var managedIcon: URL?
  var certificate: CertificateRecord? { store.certificates.first { $0.id == certificateID } }
  var body: some View {
    Form {
      Section("App") {
        LabeledContent("Name") { TextField("App Name", text: $options.name).multilineTextAlignment(.trailing) }
        LabeledContent("Bundle ID") {
          TextField("Bundle ID", text: $options.bundleID).textInputAutocapitalization(.never)
            .autocorrectionDisabled().multilineTextAlignment(.trailing)
        }
        LabeledContent("Version") {
          TextField("Version", text: $options.version).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
        }
        Button { editingIcon = true } label: {
          HStack {
            Text("App Icon").foregroundStyle(.primary)
            Spacer()
            if let image = selectedIcon ?? originalIcon {
              Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else { AppGlyph(url: try? store.workspace.resolve(app.relativePath), size: 56) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
          }.padding(.vertical, 4)
        }.accessibilityIdentifier("signing.icon")
      }
      Section {
        Toggle("Install After Signing", isOn: Binding(get: { options.installAfterSigning == true }, set: { options.installAfterSigning = $0 }))
        Toggle("Modify Without Signing", isOn: $options.modifyOnly)
        if !options.modifyOnly {
          NavigationLink {
            SigningCertificatePicker(selection: $certificateID)
          } label: {
            LabeledContent("Certificate", value: certificate?.name ?? "Select")
          }
          if let certificate {
            HStack {
              Image(
                systemName: certificate.isExpired ? "exclamationmark.circle" : "checkmark.shield")
              Text(
                "Expiration: \(min(certificate.expires,certificate.certificateExpires).formatted(date:.abbreviated,time:.omitted))"
              ).font(.caption)
            }.foregroundStyle(certificate.isExpired ? .orange : .secondary)
          }
          if store.certificates.isEmpty {
            NavigationLink("Import Certificate") { CertificatesView() }
          }
        }
      } header: {
        Text("Sign App")
      } footer: {
        Text(
          options.modifyOnly
            ? "Modify Without Signing"
            : "")
      }
      Section("Library Injection") {
        ForEach(options.libraries, id: \.self) { path in
          HStack {
            Text(URL(fileURLWithPath: path).lastPathComponent).font(.subheadline)
            Spacer()
            Button {
              options.libraries.removeAll { $0 == path }
            } label: {
              Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
          }
        }
        Button("Add Library", systemImage: "plus") {
          libraryPicker = true
        }
        Toggle("Place Libraries in Frameworks", isOn: $options.injectInFrameworks)
        Toggle("Use @rpath", isOn: $options.useRPath)
        Toggle("Weak Injection", isOn: $options.weakInjection)
        NavigationLink("Remove Linked Libraries (\(options.removeLibraries.count))") {
          List(libraries, id: \.self) { path in
            Button {
              if options.removeLibraries.contains(path) {
                options.removeLibraries.removeAll { $0 == path }
              } else {
                options.removeLibraries.append(path)
              }
            } label: {
              HStack {
                Text(path).font(.caption.monospaced())
                Spacer()
                if options.removeLibraries.contains(path) {
                  Image(systemName: "checkmark").foregroundStyle(.blue)
                }
              }
            }.foregroundStyle(.primary)
          }.navigationTitle("Remove Libraries")
        }
      }
      Section("Info.plist and Entitlements") {
        Button("Edit Info.plist", systemImage: "curlybraces") {
          showOverrides = true
        }
        if options.plistOverrides != nil {
          Button("Reset Info.plist Values", role: .destructive) {
            options.plistOverrides = nil
            overrides = ""
          }
        }
        Button {
          importing = true
        } label: {
          LabeledContent(
            "Entitlements File",
            value: options.entitlementsPath.map { URL(fileURLWithPath: $0).lastPathComponent }
              ?? "Default")
        }
        if options.entitlementsPath != nil {
          Button("Use Profile Entitlements") { options.entitlementsPath = nil }
        }
      }
      Section("Options") {
        Toggle("Remove App Extensions", isOn: $options.removeExtensions)
        Toggle("Remove Watch Apps", isOn: $options.removeWatch)
        Toggle("Remove Device Restrictions", isOn: $options.removeSupportedDevices)
        Toggle("Remove URL Schemes", isOn: $options.removeURLSchemes)
        Toggle("Enable File Sharing", isOn: $options.fileSharing)
        Toggle("Enable Document Browser", isOn: $options.documentBrowser)
        Toggle("Enable ProMotion", isOn: $options.enableProMotion)
        TextField("Minimum iOS Version", text: $options.minimumOS).keyboardType(
          .decimalPad)
        Toggle("Remove Provisioning Profile After Signing", isOn: $options.removeProvision)
      }
      Section("Export") {
        TextField("IPA File Name", text: $options.outputName).autocorrectionDisabled()
        Toggle("Compress IPA", isOn: $options.compression)
      }
    }
    .disabled(store.busy)
    .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
    .background(SigningNavigation().frame(width: 0, height: 0))
    .signingActionBar {
      SigningActionButton(title: options.modifyOnly ? "Save Changes" : "Sign", prominent: true,
        enabled: !store.busy && (options.modifyOnly || certificate != nil), identifier: "signing.submit") {
        request = SigningRequest(app: app, options: options, certificate: certificate)
      }
      .frame(maxWidth: .infinity).frame(height: 48)
    }
    .navigationDestination(item: $request) { request in
      SigningProcessView(request: request, status: store.operationStatus, onDone: {
        store.signingTab = nil
        if let onDone { onDone() } else { dismiss() }
      })
    }
    .onAppear { store.signingTab = store.selectedTab }
    .onDisappear { if request == nil { store.signingTab = nil } }
    .sheet(isPresented: $editingIcon) {
      SigningIconEditor(original: originalIcon, current: selectedIcon ?? originalIcon, custom: options.iconPath != nil) { image in
        do {
          if let image {
            let folder = store.workspace.files.appendingPathComponent(".SigningIcons")
            try store.workspace.fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = managedIcon ?? folder.appendingPathComponent(UUID().uuidString + ".png")
            try IconArtwork.png(image).write(to: file, options: .atomic)
            managedIcon = file
            options.iconPath = store.workspace.relative(file)
            selectedIcon = image
          } else {
            options.iconPath = nil; selectedIcon = nil
            if let file = managedIcon { try? store.workspace.fm.removeItem(at: file); managedIcon = nil }
          }
        } catch { localError = error.localizedDescription }
      }
    }
    .sheet(isPresented: $libraryPicker) {
      WorkspacePicker(title: "Add Library", extensions: ["dylib", "framework", "deb"], multiple: true,
        initialSelection: Set(options.libraries.compactMap { try? store.workspace.resolve($0) })) { urls in
        options.libraries = urls.map { store.workspace.relative($0) }
      }
    }
    .task {
      guard !started else { return }
      started = true
      options = store.defaultOptions
      options.name = app.name
      options.bundleID = app.bundleID
      options.version = app.version
      certificateID =
        UUID(uuidString: store.defaultCertificate)
        ?? store.certificates.first(where: { !$0.isExpired })?.id
      if let path = options.iconPath, let file = try? store.workspace.resolve(path), let data = try? Data(contentsOf: file) {
        selectedIcon = IconArtwork.decode(data)
      }
      if let url = try? store.workspace.resolve(app.relativePath) {
        if let data = await AppIconCache.shared.data(for: url) { originalIcon = IconArtwork.decode(data) }
        do { libraries = try await store.engine.libraries(for: url) } catch {
          localError = error.localizedDescription
        }
      }
    }
    .sheet(isPresented: $importing) {
      WorkspacePicker(title: "Choose Entitlements", extensions: ["plist", "xml", "entitlements"]) { urls in
        if let file = urls.first { options.entitlementsPath = store.workspace.relative(file) }
      }
    }
    .sheet(isPresented: $showOverrides) {
      NavigationStack {
        VStack {
          Text(
            "Add or replace Info.plist values. XML property-list dictionary."
          ).font(.caption).foregroundStyle(.secondary).padding()
          TextEditor(text: $overrides).font(.system(.footnote, design: .monospaced))
            .autocorrectionDisabled().textInputAutocapitalization(.never)
        }.navigationTitle("Info.plist").toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showOverrides = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("OK") {
              do {
                let data = Data(overrides.utf8)
                guard
                  (try PropertyListSerialization.propertyList(from: data, format: nil))
                    is [String: Any]
                else { throw SignerError("The plist root must be a dictionary.") }
                options.plistOverrides = data
                showOverrides = false
              } catch { localError = error.localizedDescription }
            }
          }
        }.onAppear {
          if overrides.isEmpty {
            overrides =
              "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n  <key>UIFileSharingEnabled</key>\n  <true/>\n</dict>\n</plist>"
          }
        }
      }
    }
    .alert(
      "Error",
      isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })
    ) {
      Button("OK", role: .cancel) { localError = nil }
    } message: {
      Text(localError ?? "")
    }
  }
}

struct SigningCertificatePicker: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: UUID?
  var body: some View {
    List {
      ForEach(store.certificates) { cert in
        Button {
          selection = cert.id
          dismiss()
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(cert.name).foregroundStyle(.primary)
              Text(cert.teamName).font(.caption).foregroundStyle(.secondary)
              Text(cert.isExpired ? "Expired" : "Expires " + min(cert.expires, cert.certificateExpires).formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(cert.isExpired ? .orange : .secondary)
            }
            Spacer()
            if selection == cert.id { Image(systemName: "checkmark") }
          }
        }
      }
      NavigationLink("Import Certificate") { CertificatesView() }
    }
    .navigationTitle("Certificate").navigationBarTitleDisplayMode(.inline)
  }
}
