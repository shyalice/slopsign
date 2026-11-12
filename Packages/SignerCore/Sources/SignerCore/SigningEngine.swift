import Foundation
import ZIPFoundation
import Zsign

/// One actor serializes calls to the native signing library and its OpenSSL state.
public actor SigningEngine {
  public let workspace: Workspace
  private let passwordProvider: @Sendable (UUID) throws -> String
  public init(
    workspace: Workspace,
    passwordProvider: @escaping @Sendable (UUID) throws -> String = { try PasswordVault.get($0) }
  ) {
    self.workspace = workspace
    self.passwordProvider = passwordProvider
  }
  public func libraries(for app: URL) throws -> [String] {
    let info = try workspace.appInfo(app)
    return Zsign.listDylibs(
      appExecutable: app.appendingPathComponent(info["CFBundleExecutable"] as! String).path)
  }
  public func sign(
    _ record: AppRecord, options: SigningOptions, certificate: CertificateRecord?,
    control: Progress? = nil,
    log: @escaping @Sendable (String, Bool) -> Void = { _, _ in },
    progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
  ) throws -> AppRecord {
    try FileTransfer.check(control)
    control?.totalUnitCount = 1000
    var observations: [NSKeyValueObservation] = []
    func stage(_ units: Int64, _ label: String) -> Progress {
      let child = Progress(totalUnitCount: 1)
      control?.addChild(child, withPendingUnitCount: units)
      let observation = child.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
        progress(min(1, max(0, value.fractionCompleted)), label)
      }
      observations.append(observation)
      return child
    }
    defer { withExtendedLifetime(observations) {} }
    let fm = workspace.fm
    let source = try workspace.resolve(record.relativePath)
    let id = UUID()
    let work = workspace.temporary.appendingPathComponent(UUID().uuidString)
    let payload = work.appendingPathComponent("Payload")
    try fm.createDirectory(at: payload, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    progress(0, "Preparing App")
    log("Preparing \(record.name)\nBundle ID: \(record.bundleID)\nVersion: \(record.version)", false)
    let app = payload.appendingPathComponent(source.lastPathComponent)
    try FileTransfer.copy(source, to: app, progress: stage(200, "Preparing App"), preferClone: true)
    var info = try workspace.appInfo(app)
    let oldID = info["CFBundleIdentifier"] as! String
    let newID = options.bundleID.isEmpty ? oldID : options.bundleID
    guard newID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    else { throw SignerError("Invalid Bundle Identifier.") }
    let executable = try workspace.confined(
      app.appendingPathComponent(info["CFBundleExecutable"] as! String), to: app)
    if try !options.modifyOnly && MachOInspector.isEncrypted(executable) {
      throw SignerError(
        "The executable is FairPlay encrypted. Import a decrypted IPA to sign it.")
    }
    if options.removeExtensions { try removeIfPresent(app.appendingPathComponent("PlugIns")) }
    if options.removeWatch { try removeIfPresent(app.appendingPathComponent("Watch")) }
    if !options.name.isEmpty {
      info["CFBundleDisplayName"] = options.name
      info["CFBundleName"] = options.name
      for lproj in (try fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)).filter({
        $0.pathExtension == "lproj"
      }) {
        let file = lproj.appendingPathComponent("InfoPlist.strings")
        if let data = try? Data(contentsOf: file),
          var localized = (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? [String: Any]
        {
          localized["CFBundleDisplayName"] = options.name
          localized["CFBundleName"] = options.name
          try writePlist(localized, to: file)
        }
      }
    }
    info["CFBundleIdentifier"] = newID
    if !options.version.isEmpty {
      info["CFBundleShortVersionString"] = options.version
      info["CFBundleVersion"] = options.version
    }
    if options.removeURLSchemes { info.removeValue(forKey: "CFBundleURLTypes") }
    if options.removeSupportedDevices { info.removeValue(forKey: "UISupportedDevices") }
    if options.fileSharing { info["UIFileSharingEnabled"] = true }
    if options.documentBrowser { info["UISupportsDocumentBrowser"] = true }
    if options.enableProMotion { info["CADisableMinimumFrameDurationOnPhone"] = true }
    if !options.minimumOS.isEmpty { info["MinimumOSVersion"] = options.minimumOS }
    var explicitAppGroup = false
    if let overrides = options.plistOverrides {
      guard
        let dict = try PropertyListSerialization.propertyList(from: overrides, format: nil)
          as? [String: Any]
      else { throw SignerError("Info.plist overrides must be a dictionary.") }
      explicitAppGroup = dict["AppGroupIdentifier"] != nil
      for (key, value) in dict {
        guard !["CFBundleExecutable", "CFBundleIdentifier"].contains(key) else {
          throw SignerError(
            "Use the Bundle Identifier field to change the identifier. CFBundleExecutable cannot be overridden.")
        }
        info[key] = value
      }
    }
    if let iconPath = options.iconPath {
      let icon = try Data(contentsOf: workspace.resolve(iconPath))
      try icon.write(to: app.appendingPathComponent("SignerIcon.png"))
      // Use legacy icon files to override the asset-catalog icon.
      info["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["SignerIcon"]]]
      info["CFBundleIcons~ipad"] = info["CFBundleIcons"]
      info["CFBundleIconFiles"] = ["SignerIcon"]
    }
    let signingProfile: [String: Any]?
    if !options.modifyOnly, let certificate {
      signingProfile = try Certificates.profile(at: workspace.certificates
        .appendingPathComponent(certificate.relativePath).appendingPathComponent("profile.mobileprovision"))
    } else { signingProfile = nil }
    if let signingProfile, !explicitAppGroup,
      let group = SigningCompatibility.reconcileAppGroup(info: &info, profile: signingProfile) {
      log("Using App Group: " + group, false)
    }
    try writePlist(info, to: app.appendingPathComponent("Info.plist"))
    progress(0, "Applying Changes")
    log("Applying app settings", false)
    let bundles = try nestedBundles(in: app)
    for bundle in bundles {
      try FileTransfer.check(control)
      var nested = try workspace.appInfo(bundle)
      if let bid = nested["CFBundleIdentifier"] as? String, bid.hasPrefix(oldID + ".") {
        nested["CFBundleIdentifier"] = newID + bid.dropFirst(oldID.count)
      }
      if let companion = nested["WKCompanionAppBundleIdentifier"] as? String, companion == oldID {
        nested["WKCompanionAppBundleIdentifier"] = newID
      }
      if let signingProfile { _ = SigningCompatibility.reconcileAppGroup(info: &nested, profile: signingProfile) }
      try writePlist(nested, to: bundle.appendingPathComponent("Info.plist"))
    }
    if !options.removeLibraries.isEmpty
      && !Zsign.removeDylibs(appExecutable: executable.path, using: options.removeLibraries)
    {
      throw SignerError("Unable to remove library load commands.")
    }
    control?.completedUnitCount += 150
    var injectionFiles: [URL] = []
    for path in options.libraries {
      try FileTransfer.check(control)
      let library = try workspace.resolve(path)
      if library.pathExtension.lowercased() == "deb" {
        injectionFiles += try workspace.libraries(inDeb: library,
          staging: work.appendingPathComponent("DEB-" + UUID().uuidString), progress: control)
      } else {
        guard [.dylib, .framework].contains(FileBehavior.kind(of: library)) else {
          throw SignerError("\(library.lastPathComponent) does not contain a valid dynamic library.")
        }
        injectionFiles.append(library)
      }
    }
    if injectionFiles.isEmpty { control?.completedUnitCount += 100 }
    for library in injectionFiles {
      log("Adding library: " + library.lastPathComponent, false)
      let folder = options.injectInFrameworks ? app.appendingPathComponent("Frameworks") : app
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      let dest = folder.appendingPathComponent(library.lastPathComponent)
      try removeIfPresent(dest)
      try FileTransfer.copy(library, to: dest, progress: stage(Int64(100 / injectionFiles.count), "Applying Changes"))
      let suffix =
        FileBehavior.kind(of: library) == .framework
        ? "/" + (FileBehavior.executable(in: library)?.lastPathComponent ?? library.deletingPathExtension().lastPathComponent) : ""
      let load =
        (options.useRPath
          ? "@rpath/" : "@executable_path/" + (options.injectInFrameworks ? "Frameworks/" : ""))
        + library.lastPathComponent + suffix
      guard
        Zsign.injectDyLib(appExecutable: executable.path, with: load, weak: options.weakInjection)
      else { throw SignerError("Unable to inject library \(library.lastPathComponent).") }
    }
    if !options.modifyOnly {
      guard let cert = certificate else { throw SignerError("Select a certificate to sign.") }
      guard !cert.isExpired else {
        throw SignerError("The certificate or provisioning profile has expired.")
      }
      let directory = workspace.certificates.appendingPathComponent(cert.relativePath)
      for nested in bundles {
        let target = nested.appendingPathComponent("embedded.mobileprovision")
        try removeIfPresent(target)
        if !options.removeProvision {
          try fm.copyItem(at: directory.appendingPathComponent("profile.mobileprovision"), to: target)
        }
      }
      let password = try passwordProvider(cert.id)
      _ = try Certificates.inspect(
        p12: directory.appendingPathComponent("identity.p12"),
        profile: directory.appendingPathComponent("profile.mobileprovision"), password: password,
        id: cert.id)
      var entitlements = ""
      if let path = options.entitlementsPath {
        let file = try workspace.resolve(path)
        let data = try Data(contentsOf: file)
        guard
          try PropertyListSerialization.propertyList(from: data, format: nil)
            is [String: Any]
        else { throw SignerError("Invalid entitlements file.") }
        entitlements = file.path
      }
      progress(1, "Applying Changes")
      let nativeProgress = stage(350, "Signing App")
      nativeProgress.totalUnitCount = 1000
      Zsign.resetCancellation()
      control?.cancellationHandler = { Zsign.cancelOperation() }
      defer { control?.cancellationHandler = nil; Zsign.resetCancellation() }
      try FileTransfer.check(control)
      let success = Zsign.sign(
        appPath: app.path,
        provisionPath: directory.appendingPathComponent("profile.mobileprovision").path,
        p12Path: directory.appendingPathComponent("identity.p12").path, p12Password: password,
        entitlementsPath: entitlements, removeProvision: options.removeProvision,
        log: { message, error in
          // File-system paths and certificate internals in native diagnostics
          // aren't useful in the app's signing transcript.
          let cleaned = message.replacingOccurrences(of: work.path, with: "")
          if !cleaned.contains("P12Pass:") { log(cleaned, error) }
        },
        progress: { fraction in nativeProgress.completedUnitCount = Int64(fraction * 1000) },
        completion: { _ in })
      try FileTransfer.check(control)
      guard success, Zsign.checkSigned(appExecutable: executable.path) else {
        throw SignerError("Zsign failed to sign the app. No signed result was saved.")
      }
      nativeProgress.completedUnitCount = 1000

    } else {
      // Modification invalidates the original signature. Never label this as signed.
      try removeIfPresent(app.appendingPathComponent("_CodeSignature"))
      control?.completedUnitCount += 350
    }
    progress(0, "Creating IPA")
    log("Packaging IPA", false)
    let desired =
      options.outputName.isEmpty
      ? (info["CFBundleDisplayName"] as? String ?? record.name) + "_"
        + (info["CFBundleShortVersionString"] as? String ?? record.version) + ".ipa"
      : options.outputName
    let safe = URL(fileURLWithPath: desired).lastPathComponent
    let output = workspace.unique(
      safe.hasSuffix(".ipa") ? safe : safe + ".ipa", in: workspace.archives)
    let staged = work.appendingPathComponent("Result.ipa")
    try FileTransfer.check(control)
    try IPAArchive.write(payload: payload, to: staged, compressed: options.compression, progress: stage(200, "Creating IPA"))
    try FileTransfer.check(control)
    let targetRoot = workspace.signedBundleCache.appendingPathComponent(id.uuidString)
    try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
    let target = targetRoot.appendingPathComponent(app.lastPathComponent)
    do {
      try fm.moveItem(at: app, to: target)
      try fm.moveItem(at: staged, to: output)
    } catch {
      try? fm.removeItem(at: targetRoot)
      throw error
    }
    progress(1, "Finish")
    log("Saved " + output.lastPathComponent + "\n" + (options.modifyOnly ? "Changes saved." : "Signing complete."), false)
    return AppRecord(
      id: id, name: info["CFBundleDisplayName"] as? String ?? record.name, bundleID: newID,
      version: info["CFBundleShortVersionString"] as? String ?? record.version,
      relativePath: workspace.relative(target), signedAt: options.modifyOnly ? nil : Date(),
      certificateName: options.modifyOnly ? nil : certificate?.name,
      archivePath: workspace.relative(output), modifiedOnly: options.modifyOnly)
  }

  private func removeIfPresent(_ url: URL) throws {
    if workspace.fm.fileExists(atPath: url.path) { try workspace.fm.removeItem(at: url) }
  }
  private func writePlist(_ value: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(
      to: url, options: .atomic)
  }
  private func nestedBundles(in app: URL) throws -> [URL] {
    guard let e = workspace.fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return [] }
    var result: [URL] = []
    for case let file as URL in e {
      let v = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
      if v.isSymbolicLink == true {
        _ = try workspace.confined(file, to: app)
        e.skipDescendants()
        continue
      }
      if ["appex", "app"].contains(file.pathExtension) { result.append(file) }
    }
    return result
  }
  private static func permits(_ allowed: Any, _ requested: Any) -> Bool {
    if let a = allowed as? String, let b = requested as? String {
      return a == b || a == "*" || (a.hasSuffix("*") && b.hasPrefix(String(a.dropLast())))
    }
    if let a = allowed as? [Any], let b = requested as? [Any] {
      return b.allSatisfy { request in a.contains { permits($0, request) } }
    }
    if let a = allowed as? [String: Any], let b = requested as? [String: Any] {
      return b.allSatisfy { k, v in a[k].map { permits($0, v) } ?? false }
    }
    return (allowed as? NSObject)?.isEqual(requested) ?? false
  }
}
