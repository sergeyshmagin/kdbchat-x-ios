//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// MARK: - Protocol Definition

public protocol AutoRecoveryKeyServiceProtocol {
    /// Выполняет полную диагностику и настройку автоматического восстановления
    /// БЕЗОПАСНО: Сначала проверяет существующий backup на сервере, не перезаписывает данные
    func performSafeAutoRecoverySetup() async -> Result<AutoRecoveryResult, AutoRecoveryKeyError>
    
    /// Проверяет существование backup'а на сервере БЕЗ изменения состояния
    func checkExistingBackupOnServer() async -> Result<BackupInfo, AutoRecoveryKeyError>
    
    /// Валидирует локальный ключ БЕЗ изменения состояния backup'а
    func validateLocalKeyReadOnly(_ key: String) async -> Result<Bool, AutoRecoveryKeyError>
    
    /// Восстанавливает backup ТОЛЬКО если он существует на сервере
    func restoreExistingBackup() async -> Result<Void, AutoRecoveryKeyError>
    
    /// Создает НОВЫЙ backup ТОЛЬКО если его нет на сервере
    func createNewBackupSafely() async -> Result<Void, AutoRecoveryKeyError>
    
    /// Сбрасывает существующий backup при конфликте ключей (осторожно!)
    /// Используется только когда локальный ключ не подходит к серверному backup'у
    func resetExistingBackup() async -> Result<Void, AutoRecoveryKeyError>
    
    /// DEPRECATED: Старый небезопасный метод - использовать performSafeAutoRecoverySetup
    @available(*, deprecated, message: "Use performSafeAutoRecoverySetup instead")
    func setupAutoRecoveryKey() async -> Result<Void, AutoRecoveryKeyError>
    
    /// Обеспечивает включение автоматического обмена секретами
    func enableAutomaticSecretSharing() async -> Result<Void, AutoRecoveryKeyError>
    
    /// Проверяет статус ключа восстановления
    func verifyRecoveryKeyStatus() async -> RecoveryKeyStatus
    
    /// Экспортирует ключ восстановления для резервного копирования
    func exportRecoveryKeyForBackup() -> Result<String, AutoRecoveryKeyError>
    
    /// DEPRECATED: Старый метод - использовать performSafeAutoRecoverySetup
    @available(*, deprecated, message: "Use performSafeAutoRecoverySetup instead")
    func restoreBackupAutomatically() async -> Result<Void, AutoRecoveryKeyError>
}

// MARK: - Error Types

public enum AutoRecoveryKeyError: LocalizedError, Equatable {
    case keyGenerationFailed
    case keyStorageFailed
    case keyRetrievalFailed
    case secretSharingFailed
    case keyValidationFailed
    case encryptionNotEnabled
    case backupRestoreFailed
    case backupAlreadyEnabled
    case keychainUnavailable
    case passcodeNotSet
    case networkTimeout
    case serverBackupExists
    case concurrentOperationInProgress
    case operationCancelled
    case invalidBackupState
    case clientProxyUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate recovery key"
        case .keyStorageFailed:
            return "Failed to store recovery key in Keychain"
        case .keyRetrievalFailed:
            return "Failed to retrieve recovery key from Keychain"
        case .secretSharingFailed:
            return "Failed to enable automatic secret sharing"
        case .keyValidationFailed:
            return "Recovery key validation failed"
        case .encryptionNotEnabled:
            return "Encryption is not properly enabled"
        case .backupRestoreFailed:
            return "Failed to restore backup automatically"
        case .backupAlreadyEnabled:
            return "Backup is already enabled"
        case .keychainUnavailable:
            return "Keychain is not available on this device"
        case .passcodeNotSet:
            return "Device passcode is required for secure key storage"
        case .networkTimeout:
            return "Network operation timed out"
        case .serverBackupExists:
            return "A backup already exists on the server"
        case .concurrentOperationInProgress:
            return "Another recovery operation is already in progress"
        case .operationCancelled:
            return "Operation was cancelled"
        case .invalidBackupState:
            return "Backup is in an invalid state"
        case .clientProxyUnavailable:
            return "Client connection is not available"
        }
    }
}

// MARK: - Status Types

public enum RecoveryKeyStatus: Equatable {
    case notSetup
    case setupInProgress
    case validating
    case generating
    case storing
    case enablingBackup
    case active(createdAt: Date)
    case invalid
    case sharingEnabled
    case sharingDisabled
    case failed(AutoRecoveryKeyError)
    
    public static func == (lhs: RecoveryKeyStatus, rhs: RecoveryKeyStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notSetup, .notSetup), (.setupInProgress, .setupInProgress),
             (.validating, .validating), (.generating, .generating),
             (.storing, .storing), (.enablingBackup, .enablingBackup),
             (.invalid, .invalid), (.sharingEnabled, .sharingEnabled),
             (.sharingDisabled, .sharingDisabled):
            return true
        case (.active(let date1), .active(let date2)):
            return date1 == date2
        case (.failed(let error1), .failed(let error2)):
            return error1.localizedDescription == error2.localizedDescription
        default:
            return false
        }
    }
}

// MARK: - Backup Info Types

public struct BackupInfo {
    public let exists: Bool
    public let version: String?
    public let algorithm: String?
    public let keyId: String?
    
    public init(exists: Bool, version: String? = nil, algorithm: String? = nil, keyId: String? = nil) {
        self.exists = exists
        self.version = version
        self.algorithm = algorithm
        self.keyId = keyId
    }
}

// MARK: - Operation Result Types

public enum AutoRecoveryOperation {
    case checkExistingBackup
    case validateLocalKey
    case generateNewKey
    case restoreFromServer
    case setupNewBackup
    case setupInProgress
    case keyAlreadyExists
    case restoreFromLocalKey
    case automaticKeySynchronization
}

public struct AutoRecoveryResult {
    public let operation: AutoRecoveryOperation
    public let success: Bool
    public let error: AutoRecoveryKeyError?
    public let backupInfo: BackupInfo?
    
    public init(operation: AutoRecoveryOperation, success: Bool, error: AutoRecoveryKeyError? = nil, backupInfo: BackupInfo? = nil) {
        self.operation = operation
        self.success = success
        self.error = error
        self.backupInfo = backupInfo
    }
}
