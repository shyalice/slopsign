import Foundation

public enum DeviceEnrollment {
  public static func profile(callback: URL, challenge: String) throws -> Data {
    let payload: [String: Any] = [
      "PayloadContent": [
        "DeviceAttributes": ["UDID"], "URL": callback.absoluteString, "Challenge": challenge,
      ],
      "PayloadDescription": "Get device UDID only",
      "PayloadDisplayName": "Query device UDID",
      "PayloadIdentifier": "io.alicehatesyou.signer.profile-service",
      "PayloadOrganization": "ESign",
      "PayloadType": "Profile Service",
      "PayloadUUID": UUID().uuidString,
      "PayloadVersion": 1,
    ]
    return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
  }
  public static func response(_ data: Data, challenge: String) throws -> String {
    let result = try Certificates.signedPropertyList(data)
    guard let udid = result["UDID"] as? String,
      udid.range(
        of: "^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})$", options: .regularExpression)
        != nil,
      result["CHALLENGE"] as? String == challenge
    else { throw SignerError("Invalid device response or enrollment challenge.") }
    return udid
  }
}
