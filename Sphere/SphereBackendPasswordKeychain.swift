import Foundation
import Security

/// Сохраняет пароль Go-бэкенда для email, чтобы `SphereBackendAuth` мог вызвать `POST /auth/login` без публичной регистрации.
enum SphereBackendPasswordKeychain {
    private static let service = "com.sphere.backend.password"

    static func setBackendPassword(_ password: String, forEmail email: String) {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !e.isEmpty, let data = password.data(using: .utf8) else { return }
        deleteBackendPassword(forEmail: e)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: e,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func getBackendPassword(forEmail email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: e,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func deleteBackendPassword(forEmail email: String) {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: e,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
