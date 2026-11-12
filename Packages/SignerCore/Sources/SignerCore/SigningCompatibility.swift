import Foundation

/// Keep explicit app configuration consistent with the profile that will be
/// embedded in its signature. This never adds an entitlement to the profile.
enum SigningCompatibility {
  static func reconcileAppGroup(info: inout [String: Any], profile: [String: Any]) -> String? {
    guard let current = info["AppGroupIdentifier"] as? String,
      let entitlements = profile["Entitlements"] as? [String: Any],
      let groups = entitlements["com.apple.security.application-groups"] as? [String],
      !groups.isEmpty, !groups.contains(current) else { return nil }
    let ordinal = current.split(separator: ".").last.flatMap { Int($0) }
    let replacement = groups.first { group in
      guard let ordinal else { return false }
      return group.split(separator: ".").last.flatMap { Int($0) } == ordinal
    } ?? groups.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first!
    info["AppGroupIdentifier"] = replacement
    return replacement
  }
}
