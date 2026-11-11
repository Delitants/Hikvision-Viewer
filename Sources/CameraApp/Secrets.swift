import Foundation
import LocalAuthentication
import Security

enum SecretStore {
    // Ad hoc signatures change between releases, so a previous build's legacy
    // Keychain item can block while macOS requests access to it.
    private static var service: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        return "com.neolo.HikvisionViewer.recorder.\(build)"
    }

    static func password(for recorderID: String) -> String? {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: recorderID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for recorderID: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: recorderID
        ]
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StoreError.failed }
        } else if status != errSecSuccess {
            throw StoreError.failed
        }
    }

    enum StoreError: LocalizedError {
        case failed
        var errorDescription: String? { "Could not save the recorder password in Keychain." }
    }
}
