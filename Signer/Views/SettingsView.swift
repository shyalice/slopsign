import SignerCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject var store: AppStore
  @AppStorage("deviceUDID") private var udid = ""
  @AppStorage("lockVertical") private var lockVertical = false
  @AppStorage("keepBackground") private var keepBackground = false
  @State private var importing = false
  @State private var safari: URLItem?
  @State private var obtained = false
  var body: some View {
    List {
      Section {
        Button {
          acquireUDID()
        } label: {
          HStack {
            Text("Get Device UDID")
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
              .tertiary)
          }
        }.foregroundStyle(.primary)
          .contextMenu {
            if !udid.isEmpty {
              Button("Copy UDID", systemImage: "doc.on.doc") { UIPasteboard.general.string = udid }
            }
          }
        NavigationLink("Certificates") { CertificatesView() }
      }
      Section {
        Button("Import Files") { importing = true }.foregroundStyle(.primary)
        NavigationLink("Signing Defaults") { DefaultOptionsView() }
        NavigationLink("Installation") { InstallationSettingsView() }
        NavigationLink("Wi-Fi Transfer") { ServerSettingsView(server: store.server) }
      }
      Section { NavigationLink("WebDAV") { WebDAVAccountsView() } }
      Section {
        NavigationLink("Theme") {
          Form {
            Picker("Theme", selection: $store.appearance) {
              Text("System").tag(0)
              Text("Light").tag(1)
              Text("Dark").tag(2)
            }.pickerStyle(.inline)
          }.navigationTitle("Theme")
        }
        Toggle("Portrait Lock", isOn: $lockVertical)
        Toggle("Keep Running in Background", isOn: $keepBackground)
        NavigationLink("Storage") { StorageView() }
      }
      Section("Support Development") {
        NavigationLink("TON") {
          DonationView(network: "TON", address: "UQA_kTWg-195MWuUg51SOFFC2aK6h2nV1GLv9nvzsQkNd3kY")
        }
        NavigationLink("TRON / TRC20") {
          DonationView(network: "TRON / TRC20", address: "TWj5QcEhkMa1YkdT2ju7fAKLdfWRvJK7Vp")
        }
      }
    }
    .navigationTitle("Settings")
    .toolbar(.visible, for: .navigationBar)
    .onChange(of: keepBackground) { _, enabled in
      do { try BackgroundKeeper.shared.set(enabled, owner: "manual") } catch {
        store.error = error.localizedDescription
        keepBackground = false
      }
    }
    .onChange(of: lockVertical) { _, locked in
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: locked ? .portrait : .all))
      }
    }
    .onReceive(store.udidServer.$deviceUDID) { value in
      guard let value else { return }
      udid = value
      safari = nil
      obtained = true
      try? BackgroundKeeper.shared.set(false, owner: "udid")
    }
    .sheet(item: $safari) { SafariSheet(url: $0.url) }
    .alert("UDID Obtained Successfully", isPresented: $obtained) {
      Button("Copy UDID") { UIPasteboard.general.string = udid }
      Button("OK", role: .cancel) {}
    } message: {
      Text(udid)
    }
    .importDocuments(
      isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true
    ) { result in
      do { store.importFiles(try result.get()) } catch { store.error = error.localizedDescription }
    }
  }
  private func acquireUDID() {
    do {
      store.installer.cancel()
      try store.udidServer.startEnrollment()
      try BackgroundKeeper.shared.set(true, owner: "udid")
      safari = URLItem(url: URL(string: "http://127.0.0.1:14302/signed_en.mobileconfig")!)
    } catch { store.error = error.localizedDescription }
  }
}
struct DefaultOptionsView: View {
  @EnvironmentObject var store: AppStore
  @State private var options = SigningOptions()
  @State private var loaded = false
  var body: some View {
    Form {
      Section("Certificate") {
        NavigationLink {
          SigningCertificatePicker(selection: Binding(
            get: { UUID(uuidString: store.defaultCertificate) },
            set: { store.defaultCertificate = $0?.uuidString ?? "" }))
        } label: {
          HStack(alignment: .top) {
            Text("Certificate")
            Spacer(minLength: 20)
            Text(store.certificates.first { $0.id.uuidString == store.defaultCertificate }?.name ?? "Select")
              .foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
          }
        }
      }
      Section("Options") {
        Toggle("Install After Signing", isOn: Binding(get: { options.installAfterSigning == true }, set: { options.installAfterSigning = $0 }))
        Toggle("Remove App Extensions", isOn: $options.removeExtensions)
        Toggle("Remove Watch Apps", isOn: $options.removeWatch)
        Toggle("Remove Device Restrictions", isOn: $options.removeSupportedDevices)
        Toggle("Remove URL Schemes", isOn: $options.removeURLSchemes)
        Toggle("Enable File Sharing", isOn: $options.fileSharing)
        Toggle("Enable Document Browser", isOn: $options.documentBrowser)
        Toggle("Enable ProMotion", isOn: $options.enableProMotion)
        TextField("Minimum iOS Version", text: $options.minimumOS).keyboardType(
          .decimalPad)
      }
      Section("Libraries") {
        Toggle("Place Libraries in Frameworks", isOn: $options.injectInFrameworks)
        Toggle("Weak Injection", isOn: $options.weakInjection)
        Toggle("Use @rpath", isOn: $options.useRPath)
      }
      Section("Export") {
        Toggle("Compress IPA", isOn: $options.compression)
        Toggle("Remove Provisioning Profile After Signing", isOn: $options.removeProvision)
      }
      Section { Button("Reset", role: .destructive) { options = SigningOptions() } }
    }.navigationTitle("Signing Defaults").navigationBarTitleDisplayMode(.inline)
      .onAppear {
        if !loaded {
          options = store.defaultOptions
          loaded = true
        }
      }
      .onChange(of: options) { _, new in if loaded { store.defaultOptions = new } }
  }
}
struct StorageView: View {
  @EnvironmentObject var store: AppStore
  @State private var sizes: [String: Int64] = [:]
  @State private var capacity: Int64 = 0
  @State private var available: Int64 = 0
  var body: some View {
    List {
      Section("iPhone Storage Space") {
        LabeledContent("Total Disk Space", value: fileSize(capacity))
        LabeledContent("Free Disk Space", value: fileSize(available))
        if capacity > 0 {
          ProgressView(value: Double(capacity - available), total: Double(capacity)).tint(.teal)
        }
      }
      Section("Signer") {
        ForEach(
          [
            "File", "UnSignApps", "SignedApps", "IPA Archives", "Certificates",
            "Temporary Files",
          ], id: \.self
        ) { LabeledContent($0, value: fileSize(sizes[$0] ?? 0)) }
      }
      Section {
        Button("Clear Cache", systemImage: "trash") {
          let ws = store.workspace
          store.perform("Clearing Cache") { progress in
            for url in try ws.fm.contentsOfDirectory(
              at: ws.temporary, includingPropertiesForKeys: nil)
            { try FileTransfer.check(progress); try ws.fm.removeItem(at: url) }
          }
        }.disabled(store.busy)
      } footer: {
        Text("")
      }
    }.navigationTitle("Storage").task { await measure() }.onChange(of: store.revision) {
      _, _ in
      Task { await measure() }
    }
  }
  func measure() async {
    let ws = store.workspace
    let values = await Task.detached {
      [
        "File": ws.size(ws.files), "UnSignApps": ws.size(ws.apps),
        "SignedApps": ws.size(ws.signed), "IPA Archives": ws.size(ws.archives),
        "Certificates": ws.size(ws.certificates),
        "Temporary Files": ws.size(ws.temporary),
      ]
    }.value
    sizes = values
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: ws.root.path) {
      capacity = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
      available = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
  }
}
struct ServerSettingsView: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var server: LocalFileServer
  @AppStorage("serverPort") private var port = "8080"
  @AppStorage("tlsHostname") private var hostname = ""
  @State private var importing = false
  @State private var tlsPassword = ""
  @State private var tlsFile: URL?
  @State private var problem: String?
  var address: String {
    (server.tlsEnabled ? "https://" : "http://")
      + (hostname.isEmpty ? server.wifiAddress : hostname) + ":" + String(server.port)
  }
  var body: some View {
    Form {
      Section {
        HStack {
          Image(systemName: server.running ? "wifi" : "wifi.slash").foregroundStyle(
            server.running ? .teal : .secondary)
          Text(server.status)
        }
        Button(server.running ? "Stop" : "Start") { toggle() }.tint(
          server.running ? .red : .teal)
      }
      if server.running {
        Section("Connection") {
          LabeledContent("URL", value: address).textSelection(.enabled)
          LabeledContent("Username", value: server.username).textSelection(.enabled)
          LabeledContent("Password", value: server.password).textSelection(.enabled)
          ShareLink(item: address) {
            Label("Share URL", systemImage: "square.and.arrow.up")
          }
        }
      }
      Section("Server") {
        TextField("Port", text: $port).keyboardType(.numberPad)
        TextField("HTTPS hostname (optional)", text: $hostname).textInputAutocapitalization(
          .never
        ).autocorrectionDisabled()
        Button {
          importing = true
        } label: {
          LabeledContent("TLS P12", value: tlsFile?.lastPathComponent ?? "HTTP")
        }
        SecureField("TLS Password", text: $tlsPassword)
        if tlsFile != nil {
          Button("Use HTTP") {
            tlsFile = nil
            tlsPassword = ""
          }
        }
      }.disabled(server.running)
      Section {
        Text(
          "Enter the address in a browser on another device on the same WiFi network."
        ).font(.caption).foregroundStyle(.secondary)
        Text(
          "Keep Signer running while transferring files."
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section("Local Installation") {
        Text(
          "HTTPS installation requires a trusted TLS identity matching the server hostname."
        ).font(.caption).foregroundStyle(.secondary)
      }
      if let problem { Section { Text(problem).foregroundStyle(.red).font(.caption) } }
    }.navigationTitle("Wi-Fi Transfer").navigationBarTitleDisplayMode(.inline)
      .importDocuments(isPresented: $importing, allowedContentTypes: [.data]) { r in
        do {
          guard let url = try r.get().first else { return }
          let scope = url.startAccessingSecurityScopedResource()
          defer { if scope { url.stopAccessingSecurityScopedResource() } }
          let dest = store.workspace.privateRoot.appendingPathComponent("tls-identity.p12")
          try Data(contentsOf: url).write(to: dest, options: .atomic)
          tlsFile = dest
        } catch { problem = error.localizedDescription }
      }
      .onAppear {
        let file = store.workspace.privateRoot.appendingPathComponent("tls-identity.p12")
        if FileManager.default.fileExists(atPath: file.path) { tlsFile = file }
      }
  }
  func toggle() {
    if server.running {
      server.stop()
      return
    }
    do {
      guard let p = UInt16(port), p > 0 else {
        throw SignerError("Port must be between 1 and 65535.")
      }
      server.onChange = { store.revision += 1 }
      try server.start(
        root: store.workspace.root, port: p, tlsP12: tlsFile, tlsPassword: tlsPassword)
      problem = nil
    } catch { problem = error.localizedDescription }
  }
}

struct InstallationSettingsView: View {
  @EnvironmentObject var store: AppStore
  @AppStorage("installation.domain") private var domain = "sign.killed.wtf"
  @AppStorage("installation.configurationURL") private var configuration = ""
  @State private var importing = false
  @State private var password = ""
  @State private var result: String?
  var body: some View {
    Form {
      Section {
        TextField("Local Domain", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
      } header: { Text("Local Installation") } footer: { Text("A TLS certificate for sign.killed.wtf is included with ESign. No server configuration is needed for this domain.") }
      Section {
        DisclosureGroup("Advanced") {
          SecureField("TLS P12 Password", text: $password)
          Button("Import TLS Identity") { importing = true }
          TextField("Certificate Update URL (Optional)", text: $configuration)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        }
      } footer: { Text("A custom domain must resolve to 127.0.0.1 and have a matching, publicly trusted TLS certificate. A certificate update URL is optional.") }
      Section {
        Button("Copy Last Installation Report") { UIPasteboard.general.string = store.installer.report }
      }
    }
    .navigationTitle("Installation").navigationBarTitleDisplayMode(.inline)
    .importDocuments(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { response in
      do {
        guard let file = try response.get().first else { return }
        let access = file.startAccessingSecurityScopedResource()
        Task {
          defer { if access { file.stopAccessingSecurityScopedResource() } }
          do { try await store.installer.identities.importIdentity(file, host: domain, password: password); result = "TLS identity imported." }
          catch { result = error.localizedDescription }
        }
      } catch { result = error.localizedDescription }
    }
    .alert("Installation", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) { Button("OK") { result = nil } } message: { Text(result ?? "") }
  }
}
