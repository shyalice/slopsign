import SignerCore
import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
  @EnvironmentObject var store: AppStore
  @State private var adding = false
  var body: some View {
    List {
      ForEach(store.certificates) { cert in
        NavigationLink {
          CertificateDetailView(certificate: cert)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
              Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(
                cert.isExpired ? .orange : .teal)
              Text(cert.name).font(.subheadline.weight(.medium))
              Spacer()
              if store.defaultCertificate == cert.id.uuidString {
                Image(systemName: "star.fill").foregroundStyle(.teal)
              }
            }
            Text(cert.teamName + " · " + cert.teamID).font(.caption).foregroundStyle(.secondary)
            Text(
              cert.isExpired
                ? "Expired"
                : "Expiration: \(min(cert.expires,cert.certificateExpires).formatted(date:.abbreviated,time:.omitted))"
            ).font(.caption).foregroundStyle(cert.isExpired ? .orange : .secondary)
          }.padding(.vertical, 5)
        }
        .swipeActions { Button("Delete", role: .destructive) { store.deleteCertificate(cert) } }
        .contextMenu {
          Button("Use by Default", systemImage: "star") {
            store.defaultCertificate = cert.id.uuidString
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            store.deleteCertificate(cert)
          }
        }
      }
    }.listStyle(.plain).navigationTitle("Certificates").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Add", systemImage: "plus") { adding = true }
        }
      }
      .sheet(isPresented: $adding) { NavigationStack { CertificateImportView() } }
  }
}
struct CertificateImportView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var p12: URL?
  @State private var profile: URL?
  @State private var password = ""
  @State private var pick = "p12"
  @State private var importing = false
  @State private var working = false
  @State private var problem: String?
  @State private var useDefault = true
  @State private var staged: [URL] = []
  let initialFile: URL?
  init(initialFile: URL? = nil) { self.initialFile = initialFile }
  var body: some View {
    Form {
      Section("File") {
        Button {
          pick = "p12"
          importing = true
        } label: {
          LabeledContent("Certificate (.p12)", value: p12?.lastPathComponent ?? "Select")
        }
        Button {
          pick = "profile"
          importing = true
        } label: {
          LabeledContent("Provisioning Profile", value: profile?.lastPathComponent ?? "Select")
        }
        SecureField("Certificate Password", text: $password)
      }
      Section {
        Toggle("Use by Default", isOn: $useDefault)
      }
      if let problem { Section { Text(problem).foregroundStyle(.red).font(.subheadline) } }
      Section {
        Button {
          save()
        } label: {
          HStack {
            if working { ProgressView() }
            Text(working ? "Reading certificate…" : "Import")
          }.frame(maxWidth: .infinity)
        }.disabled(p12 == nil || profile == nil || working)
      }
    }.navigationTitle("Import Certificate").navigationBarTitleDisplayMode(.inline)
      .disabled(working)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(working)
        }
      }
      .importDocuments(
        isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false
      ) { r in
        do {
          guard let url = try r.get().first else { return }
          let scope = url.startAccessingSecurityScopedResource()
          defer { if scope { url.stopAccessingSecurityScopedResource() } }
          let ext = url.pathExtension.lowercased()
          guard
            pick == "p12"
              ? ["p12", "pfx"].contains(ext)
              : ["mobileprovision", "provisionprofile"].contains(ext)
          else {
            throw SignerError(
              pick == "p12" ? "Select a .p12 or .pfx file." : "Select a .mobileprovision file.")
          }
          let dir = store.workspace.temporary.appendingPathComponent(UUID().uuidString)
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          let dest = dir.appendingPathComponent(url.lastPathComponent)
          try FileManager.default.copyItem(at: url, to: dest)
          staged.append(dir)
          if pick == "p12" { p12 = dest } else { profile = dest }
        } catch { problem = error.localizedDescription }
      }
      .onDisappear { for dir in staged { try? FileManager.default.removeItem(at: dir) } }
      .task {
        guard let initialFile, p12 == nil, profile == nil else { return }
        let ext = initialFile.pathExtension.lowercased()
        if ["p12", "pfx"].contains(ext) { p12 = initialFile } else { profile = initialFile }
        let siblings = (try? store.workspace.children(initialFile.deletingLastPathComponent())) ?? []
        let matching = siblings.filter {
          (p12 == nil ? ["p12", "pfx"] : ["mobileprovision", "provisionprofile"]).contains($0.pathExtension.lowercased())
        }
        let paired = matching.first(where: { $0.deletingPathExtension().lastPathComponent == initialFile.deletingPathExtension().lastPathComponent })
          ?? (matching.count == 1 ? matching.first : nil)
        if p12 == nil { p12 = paired } else { profile = paired }
      }
  }
  func save() {
    guard let p12, let profile else { return }
    working = true
    problem = nil
    let ws = store.workspace
    let pass = password
    Task {
      do {
        let cert = try await Task.detached {
          try Certificates.importPair(p12: p12, profile: profile, password: pass, workspace: ws)
        }.value
        store.certificates.append(cert)
        try store.persist()
        if useDefault { store.defaultCertificate = cert.id.uuidString }
        password = ""
        dismiss()
      } catch { problem = error.localizedDescription }
      working = false
    }
  }
}
struct CertificateDetailView: View {
  @EnvironmentObject var store: AppStore
  let certificate: CertificateRecord
  @State private var profileText = ""
  @State private var ocsp = "Unknown"
  @State private var checking = false
  @State private var deleting = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(
            certificate.isExpired ? .orange : .teal)
          Text(certificate.name).font(.headline)
          Text(certificate.isExpired ? "Expired" : "Provisioning Profile Imported").font(
            .subheadline
          ).foregroundStyle(certificate.isExpired ? .orange : .teal)
        }.padding(.vertical, 12)
      }
      Section("Certificate") {
        LabeledContent("Team ID", value: certificate.teamID)
        LabeledContent("Team Name", value: certificate.teamName)
        LabeledContent(
          "Expiration Date",
          value: certificate.certificateExpires.formatted(date: .abbreviated, time: .shortened))
        Button(
          store.defaultCertificate == certificate.id.uuidString
            ? "Use by Default" : "Use by Default",
          systemImage: store.defaultCertificate == certificate.id.uuidString ? "star.fill" : "star"
        ) { store.defaultCertificate = certificate.id.uuidString }
        LabeledContent("Revocation", value: ocsp)
        Button(checking ? "Checking…" : "Check Revocation") { checkRevocation() }.disabled(
          checking)
      }
      Section("Provisioning Profile") {
        LabeledContent("App Name", value: certificate.profileName)
        LabeledContent("UUID", value: certificate.profileUUID).textSelection(.enabled)
        LabeledContent("Application ID", value: certificate.appIdentifier).textSelection(.enabled)
        LabeledContent(
          "Creation Date", value: certificate.created.formatted(date: .abbreviated, time: .omitted))
        LabeledContent(
          "Expiration Date",
          value: certificate.expires.formatted(date: .abbreviated, time: .shortened))
        NavigationLink("Entitlements") {
          ScrollView {
            Text(profileText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              .padding()
          }.navigationTitle("Provisioning Profile")
        }
      }
      Section("Provisioned devices · \(certificate.devices.count)") {
        if certificate.allDevices {
          Text("All devices (Enterprise)").foregroundStyle(.secondary)
        } else if certificate.devices.isEmpty {
          Text(
            "No provisioned devices"
          ).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(certificate.devices, id: \.self) {
          Text($0).font(.caption.monospaced()).textSelection(.enabled)
        }
      }
      Section {
        Button("Delete Certificate", systemImage: "trash", role: .destructive) { deleting = true }
      }
    }.navigationTitle("Certificate").navigationBarTitleDisplayMode(.inline)
      .task {
        do {
          let file = store.workspace.certificates.appendingPathComponent(certificate.relativePath)
            .appendingPathComponent("profile.mobileprovision")
          let dict = try Certificates.profile(at: file)
          profileText =
            String(
              data: try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0), encoding: .utf8) ?? ""
        } catch { store.error = error.localizedDescription }
      }
      .confirmationDialog(
        "Delete this certificate and its password?", isPresented: $deleting,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          store.deleteCertificate(certificate)
          dismiss()
        }
      }
  }
  func checkRevocation() {
    checking = true
    ocsp = "Checking…"
    let dir = store.workspace.certificates.appendingPathComponent(certificate.relativePath)
    Task {
      do {
        let result = try await store.engine.revocation(
          profile: dir.appendingPathComponent("profile.mobileprovision"),
          p12: dir.appendingPathComponent("identity.p12"), id: certificate.id)
        ocsp = result
      } catch { ocsp = "Unavailable: " + error.localizedDescription }
      checking = false
    }
  }
}

struct CertificateFileView: View {
  @Environment(\.dismiss) private var dismiss
  let url: URL
  @State private var password = ""
  @State private var info: (name: String, created: Date, expires: Date)?
  @State private var error: String?
  var body: some View {
    Form {
      if let info {
        Section {
          LabeledContent("Name", value: info.name)
          LabeledContent("Valid From", value: info.created.formatted(date: .abbreviated, time: .omitted))
          LabeledContent("Expires", value: info.expires.formatted(date: .abbreviated, time: .omitted))
        }
      } else {
        Section {
          SecureField("Certificate Password", text: $password)
          Button("Open") {
            do { info = try Certificates.identityInfo(p12: url, password: password); password = ""; error = nil }
            catch { self.error = error.localizedDescription }
          }
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
    }
    .navigationTitle("Certificate").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
  }
}
