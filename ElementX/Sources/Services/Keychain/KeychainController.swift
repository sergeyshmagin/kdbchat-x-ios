//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import KeychainAccess
import MatrixRustSDK

enum KeychainControllerService: String {
    case sessions
    case tests

    var restorationTokenID: String {
        InfoPlistReader.main.baseBundleIdentifier + "." + rawValue
    }
    
    var mainID: String {
        InfoPlistReader.main.baseBundleIdentifier + ".keychain.\(rawValue)"
    }
}

class KeychainController: KeychainControllerProtocol {
    /// The keychain responsible for storing account restoration tokens (keyed by userID).
    private let restorationTokenKeychain: Keychain
    /// The keychain responsible for storing all other secrets in the app (keyed by `Key`s).
    private let mainKeychain: Keychain
    /// The access group for keychain items
    private let accessGroup: String
    
    private enum Key: String {
        case appLockPINCode
        case appLockBiometricState
        case ssssRecoveryKey = "ssss_recovery_key"
        case ssssRecoveryKeyCreationDate = "ssss_recovery_key_creation_date"
        case ssssRecoveryKeyVersion = "ssss_recovery_key_version"
    }

    init(service: KeychainControllerService, accessGroup: String) {
        self.accessGroup = accessGroup
        restorationTokenKeychain = Keychain(service: service.restorationTokenID, accessGroup: accessGroup)
        mainKeychain = Keychain(service: service.mainID, accessGroup: accessGroup)
    }
    
    // MARK: - Restoration Tokens

    func setRestorationToken(_ restorationToken: RestorationToken, forUsername username: String) {
        do {
            let tokenData = try JSONEncoder().encode(restorationToken)
            try restorationTokenKeychain.set(tokenData, key: username)
        } catch {
            MXLog.error("Failed storing user restore token with error: \(error)")
        }
    }

    func restorationTokenForUsername(_ username: String) -> RestorationToken? {
        do {
            guard let tokenData = try restorationTokenKeychain.getData(username) else {
                return nil
            }

            return try JSONDecoder().decode(RestorationToken.self, from: tokenData)
        } catch {
            MXLog.error("Failed retrieving user restore token")
            return nil
        }
    }

    func restorationTokens() -> [KeychainCredentials] {
        restorationTokenKeychain.allKeys().compactMap { username in
            guard let restorationToken = restorationTokenForUsername(username) else {
                return nil
            }

            return KeychainCredentials(userID: username, restorationToken: restorationToken)
        }
    }

    func removeRestorationTokenForUsername(_ username: String) {
        MXLog.warning("Removing restoration token for user: \(username).")
        
        do {
            try restorationTokenKeychain.remove(username)
        } catch {
            MXLog.error("Failed removing restore token with error: \(error)")
        }
    }

    func removeAllRestorationTokens() {
        MXLog.warning("Removing all user restoration tokens.")
        
        do {
            try restorationTokenKeychain.removeAll()
        } catch {
            MXLog.error("Failed removing all tokens")
        }
    }
    
    // MARK: - ClientSessionDelegate
    
    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        MXLog.info("Retrieving an updated Session from the keychain.")
        guard let session = restorationTokenForUsername(userId)?.session else {
            throw ClientError.Generic(msg: "Failed to find RestorationToken in the Keychain.", details: nil)
        }
        return session
    }
    
    func saveSessionInKeychain(session: Session) {
        MXLog.info("Saving session changes in the keychain.")
        
        guard let oldToken = restorationTokenForUsername(session.userId) else {
            MXLog.error("Failed retrieving the restoration token for \(session.userId)")
            fatalError("Something has gone mega wrong, all bets are off.")
        }
        let restorationToken = RestorationToken(session: session,
                                                sessionDirectories: oldToken.sessionDirectories,
                                                passphrase: oldToken.passphrase,
                                                pusherNotificationClientIdentifier: oldToken.pusherNotificationClientIdentifier,
                                                slidingSyncProxyURLString: oldToken.slidingSyncProxyURLString)
        setRestorationToken(restorationToken, forUsername: session.userId)
    }
    
    // MARK: - App Secrets
    
    func resetSecrets() {
        MXLog.warning("Resetting main keychain.")
        
        do {
            try mainKeychain.removeAll()
        } catch {
            MXLog.error("Failed resetting the main keychain.")
        }
    }
    
    func containsPINCode() throws -> Bool {
        try mainKeychain.contains(Key.appLockPINCode.rawValue)
    }
    
    func setPINCode(_ pinCode: String) throws {
        try mainKeychain.set(pinCode, key: Key.appLockPINCode.rawValue)
    }
    
    func pinCode() -> String? {
        do {
            return try mainKeychain.getString(Key.appLockPINCode.rawValue)
        } catch {
            MXLog.error("Failed retrieving the PIN code.")
            return nil
        }
    }
    
    func removePINCode() {
        do {
            try mainKeychain.remove(Key.appLockPINCode.rawValue)
        } catch {
            MXLog.error("Failed removing the PIN code.")
        }
    }
    
    func containsPINCodeBiometricState() -> Bool {
        do {
            return try mainKeychain.contains(Key.appLockBiometricState.rawValue)
        } catch {
            MXLog.error("Failed checking for biometric state.")
            return false // No need to re-throw the error, we can fall back to the PIN code.
        }
    }
    
    func setPINCodeBiometricState(_ state: Data) throws {
        try mainKeychain.set(state, key: Key.appLockBiometricState.rawValue)
    }
    
    func pinCodeBiometricState() -> Data? {
        do {
            return try mainKeychain.getData(Key.appLockBiometricState.rawValue)
        } catch {
            MXLog.error("Failed setting the PIN code biometric state.")
            return nil
        }
    }
    
    func removePINCodeBiometricState() {
        do {
            try mainKeychain.remove(Key.appLockBiometricState.rawValue)
        } catch {
            MXLog.error("Failed removing the PIN code biometric state.")
        }
    }
    
    // MARK: - SSSS Recovery Key Management
    
    /// Создает безопасный keychain для SSSS ключей с настройками сохранения после переустановки
    private func createSSSSKeychain() -> Keychain {
        return Keychain(service: mainKeychain.service, accessGroup: accessGroup)
            .accessibility(.whenUnlocked) // Доступно после разблокировки, остается после переустановки приложения
            .synchronizable(false) // Никогда не синхронизировать через iCloud
    }
    
    /// Сохраняет SSSS ключ восстановления в Keychain с максимальной защитой
    func setSSSSRecoveryKey(_ key: String, forUserID userID: String) throws {
        let keyIdentifier = "\(Key.ssssRecoveryKey.rawValue)_\(userID)"
        let dateIdentifier = "\(Key.ssssRecoveryKeyCreationDate.rawValue)_\(userID)"
        let versionIdentifier = "\(Key.ssssRecoveryKeyVersion.rawValue)_\(userID)"
        
        let secureKeychain = createSSSSKeychain()
        
        do {
            // Сохраняем ключ
            try secureKeychain.set(key, key: keyIdentifier)
            
            // Сохраняем метаданные
            let currentTime = Date().timeIntervalSince1970
            try secureKeychain.set(String(currentTime), key: dateIdentifier)
            try secureKeychain.set("1.0", key: versionIdentifier)
            
            MXLog.info("SSSS recovery key stored securely for user: \(userID)")
        } catch {
            MXLog.error("Failed to store SSSS recovery key: \(error)")
            throw error
        }
    }
    
    /// Получает SSSS ключ восстановления из Keychain
    func ssssRecoveryKey(forUserID userID: String) -> String? {
        let keyIdentifier = "\(Key.ssssRecoveryKey.rawValue)_\(userID)"
        let secureKeychain = createSSSSKeychain()
        
        do {
            let key = try secureKeychain.getString(keyIdentifier)
            if key != nil {
                MXLog.info("SSSS recovery key retrieved for user: \(userID)")
            }
            return key
        } catch {
            MXLog.error("Failed to retrieve SSSS recovery key: \(error)")
            return nil
        }
    }
    
    /// Проверяет существование SSSS ключа
    func hasSSSSRecoveryKey(forUserID userID: String) -> Bool {
        let keyIdentifier = "\(Key.ssssRecoveryKey.rawValue)_\(userID)"
        let secureKeychain = createSSSSKeychain()
        
        do {
            return try secureKeychain.contains(keyIdentifier)
        } catch {
            MXLog.error("Failed to check SSSS key existence: \(error)")
            return false
        }
    }
    
    /// Удаляет SSSS ключ и метаданные
    func removeSSSSRecoveryKey(forUserID userID: String) {
        let keyIdentifier = "\(Key.ssssRecoveryKey.rawValue)_\(userID)"
        let dateIdentifier = "\(Key.ssssRecoveryKeyCreationDate.rawValue)_\(userID)"
        let versionIdentifier = "\(Key.ssssRecoveryKeyVersion.rawValue)_\(userID)"
        
        let secureKeychain = createSSSSKeychain()
        
        do {
            try secureKeychain.remove(keyIdentifier)
            try secureKeychain.remove(dateIdentifier)
            try secureKeychain.remove(versionIdentifier)
            MXLog.info("SSSS recovery key removed for user: \(userID)")
        } catch {
            MXLog.error("Failed to remove SSSS recovery key: \(error)")
        }
    }
    
    /// Получает дату создания ключа
    func ssssRecoveryKeyCreationDate(forUserID userID: String) -> Date? {
        let dateIdentifier = "\(Key.ssssRecoveryKeyCreationDate.rawValue)_\(userID)"
        let secureKeychain = createSSSSKeychain()
        
        do {
            guard let timeString = try secureKeychain.getString(dateIdentifier),
                  let timeInterval = Double(timeString) else {
                return nil
            }
            return Date(timeIntervalSince1970: timeInterval)
        } catch {
            MXLog.error("Failed to retrieve key creation date: \(error)")
            return nil
        }
    }
}
