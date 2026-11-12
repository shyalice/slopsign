import Foundation
import Zsign

extension SigningEngine {
  public func revocation(profile: URL, p12: URL, id: UUID) async throws -> String {
    let password = try PasswordVault.get(id)
    return await withCheckedContinuation { continuation in
      Zsign.checkRevokage(provisionPath: profile.path, p12Path: p12.path, p12Password: password) {
        status, _, error in
        if let error {
          continuation.resume(returning: "Unknown: " + error)
        } else {
          continuation.resume(
            returning: status == 0
              ? "Good (OCSP)" : status == 1 ? "Revoked" : "Unknown")
        }
      }
    }
  }
}
