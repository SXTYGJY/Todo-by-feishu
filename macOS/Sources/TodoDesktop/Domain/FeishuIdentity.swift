import CryptoKit
import Foundation

struct FeishuIdentity: Codable, Hashable {
    let userID: String
    let tenantID: String?

    var storageKey: String {
        let identity = "\(userID)|\(tenantID ?? "")"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
