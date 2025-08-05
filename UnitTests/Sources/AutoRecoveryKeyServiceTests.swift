//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class AutoRecoveryKeyServiceTests: XCTestCase {
    var service: AutoRecoveryKeyService!
    var mockClientProxy: MockClientProxy!
    var mockKeychainController: MockKeychainController!
    var mockSecureBackupController: MockSecureBackupController!
    
    override func setUp() {
        super.setUp()
        
        mockKeychainController = MockKeychainController()
        mockSecureBackupController = MockSecureBackupController()
        mockClientProxy = MockClientProxy()
        mockClientProxy.underlyingSecureBackupController = mockSecureBackupController
        
        service = AutoRecoveryKeyService(clientProxy: mockClientProxy,
                                         keychainController: mockKeychainController,
                                         userID: "@test:matrix.org")
    }
    
    override func tearDown() {
        service = nil
        mockClientProxy = nil
        mockKeychainController = nil
        mockSecureBackupController = nil
        super.tearDown()
    }
    
    // MARK: - Setup Auto Recovery Key Tests
    
    func testSetupAutoRecoveryKey_NoExistingKey_GeneratesAndStoresNew() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = false
        mockSecureBackupController.generateRecoveryKeyReturnValue = .success("test-recovery-key-123")
        mockSecureBackupController.enableReturnValue = .success(())
        mockSecureBackupController.recoveryState = .init(.enabled)
        mockSecureBackupController.keyBackupState = .init(.enabled)
        
        // When
        let result = await service.setupAutoRecoveryKey()
        
        // Then
        XCTAssertSuccess(result)
        XCTAssertTrue(mockKeychainController.setSSSSRecoveryKeyCalled)
        XCTAssertEqual(mockKeychainController.setSSSSRecoveryKeyReceivedArguments?.key, "test-recovery-key-123")
        XCTAssertEqual(mockKeychainController.setSSSSRecoveryKeyReceivedArguments?.userID, "@test:matrix.org")
        XCTAssertTrue(mockSecureBackupController.generateRecoveryKeyCalled)
        XCTAssertTrue(mockSecureBackupController.enableCalled)
    }
    
    func testSetupAutoRecoveryKey_ExistingValidKey_UsesExisting() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = true
        mockKeychainController.ssssRecoveryKeyReturnValue = "existing-recovery-key"
        mockSecureBackupController.confirmRecoveryKeyReturnValue = .success(())
        mockSecureBackupController.recoveryState = .init(.enabled)
        mockSecureBackupController.keyBackupState = .init(.enabled)
        
        // When
        let result = await service.setupAutoRecoveryKey()
        
        // Then
        XCTAssertSuccess(result)
        XCTAssertTrue(mockSecureBackupController.confirmRecoveryKeyCalled)
        XCTAssertEqual(mockSecureBackupController.confirmRecoveryKeyReceivedKey, "existing-recovery-key")
        XCTAssertFalse(mockSecureBackupController.generateRecoveryKeyCalled)
    }
    
    func testSetupAutoRecoveryKey_ExistingInvalidKey_GeneratesNew() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = true
        mockKeychainController.ssssRecoveryKeyReturnValue = "invalid-recovery-key"
        mockSecureBackupController.confirmRecoveryKeyReturnValue = .failure(.failedConfirmingRecoveryKey)
        mockSecureBackupController.generateRecoveryKeyReturnValue = .success("new-recovery-key")
        mockSecureBackupController.enableReturnValue = .success(())
        mockSecureBackupController.recoveryState = .init(.enabled)
        mockSecureBackupController.keyBackupState = .init(.enabled)
        
        // When
        let result = await service.setupAutoRecoveryKey()
        
        // Then
        XCTAssertSuccess(result)
        XCTAssertTrue(mockKeychainController.removeSSSSRecoveryKeyCalled)
        XCTAssertTrue(mockSecureBackupController.generateRecoveryKeyCalled)
        XCTAssertTrue(mockKeychainController.setSSSSRecoveryKeyCalled)
        XCTAssertEqual(mockKeychainController.setSSSSRecoveryKeyReceivedArguments?.key, "new-recovery-key")
    }
    
    func testSetupAutoRecoveryKey_GenerationFails_ReturnsError() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = false
        mockSecureBackupController.generateRecoveryKeyReturnValue = .failure(.failedGeneratingRecoveryKey)
        
        // When
        let result = await service.setupAutoRecoveryKey()
        
        // Then
        XCTAssertFailure(result) { error in
            XCTAssertEqual(error, .keyGenerationFailed)
        }
    }
    
    func testSetupAutoRecoveryKey_StorageFails_ReturnsError() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = false
        mockSecureBackupController.generateRecoveryKeyReturnValue = .success("test-key")
        mockKeychainController.setSSSSRecoveryKeyThrowableError = KeychainError.storageError
        
        // When
        let result = await service.setupAutoRecoveryKey()
        
        // Then
        XCTAssertFailure(result) { error in
            XCTAssertEqual(error, .keyStorageFailed)
        }
    }
    
    // MARK: - Verify Recovery Key Status Tests
    
    func testVerifyRecoveryKeyStatus_NoKey_ReturnsNotSetup() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = false
        
        // When
        let status = await service.verifyRecoveryKeyStatus()
        
        // Then
        XCTAssertEqual(status, .notSetup)
    }
    
    func testVerifyRecoveryKeyStatus_ValidKey_ReturnsActive() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = true
        mockSecureBackupController.recoveryState = .init(.enabled)
        mockSecureBackupController.keyBackupState = .init(.enabled)
        let testDate = Date()
        mockKeychainController.ssssRecoveryKeyCreationDateReturnValue = testDate
        
        // When
        let status = await service.verifyRecoveryKeyStatus()
        
        // Then
        if case .active(let createdAt) = status {
            XCTAssertEqual(createdAt.timeIntervalSince1970, testDate.timeIntervalSince1970, accuracy: 1.0)
        } else {
            XCTFail("Expected .active status, got \(status)")
        }
    }
    
    func testVerifyRecoveryKeyStatus_InvalidState_ReturnsInvalid() async {
        // Given
        mockKeychainController.hasSSSSRecoveryKeyReturnValue = true
        mockSecureBackupController.recoveryState = .init(.disabled)
        mockSecureBackupController.keyBackupState = .init(.unknown)
        
        // When
        let status = await service.verifyRecoveryKeyStatus()
        
        // Then
        XCTAssertEqual(status, .invalid)
    }
    
    // MARK: - Export Recovery Key Tests
    
    func testExportRecoveryKeyForBackup_Success() {
        // Given
        mockKeychainController.ssssRecoveryKeyReturnValue = "backup-key-123"
        
        // When
        let result = service.exportRecoveryKeyForBackup()
        
        // Then
        XCTAssertSuccess(result) { key in
            XCTAssertEqual(key, "backup-key-123")
        }
    }
    
    func testExportRecoveryKeyForBackup_NoKey_ReturnsError() {
        // Given
        mockKeychainController.ssssRecoveryKeyReturnValue = nil
        
        // When
        let result = service.exportRecoveryKeyForBackup()
        
        // Then
        XCTAssertFailure(result) { error in
            XCTAssertEqual(error, .keyRetrievalFailed)
        }
    }
    
    // MARK: - Enable Automatic Secret Sharing Tests
    
    func testEnableAutomaticSecretSharing_Success() async {
        // Given
        mockSecureBackupController.recoveryState = .init(.enabled)
        mockSecureBackupController.keyBackupState = .init(.enabled)
        
        // When
        let result = await service.enableAutomaticSecretSharing()
        
        // Then
        XCTAssertSuccess(result)
    }
    
    func testEnableAutomaticSecretSharing_EncryptionNotEnabled_ReturnsError() async {
        // Given
        mockSecureBackupController.recoveryState = .init(.disabled)
        mockSecureBackupController.keyBackupState = .init(.unknown)
        
        // When
        let result = await service.enableAutomaticSecretSharing()
        
        // Then
        XCTAssertFailure(result) { error in
            XCTAssertEqual(error, .encryptionNotEnabled)
        }
    }
}

// MARK: - Test Helpers

extension XCTestCase {
    func XCTAssertSuccess<T>(_ result: Result<T, some Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected success, got failure: \(error)", file: file, line: line)
        }
    }
    
    func XCTAssertSuccess<T>(_ result: Result<T, some Error>,
                             validation: (T) -> Void,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        switch result {
        case .success(let value):
            validation(value)
        case .failure(let error):
            XCTFail("Expected success, got failure: \(error)", file: file, line: line)
        }
    }
    
    func XCTAssertFailure<T, E: Error & Equatable>(_ result: Result<T, E>,
                                                   validation: (E) -> Void,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) {
        switch result {
        case .success(let value):
            XCTFail("Expected failure, got success: \(value)", file: file, line: line)
        case .failure(let error):
            validation(error)
        }
    }
}

// MARK: - Mock Error Types

enum KeychainError: Error {
    case storageError
}
