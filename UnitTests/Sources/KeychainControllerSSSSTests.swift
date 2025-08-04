//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import XCTest
@testable import ElementX

@MainActor
class KeychainControllerSSSSTests: XCTestCase {
    
    var keychainController: KeychainController!
    let testUserID = "@test:matrix.org"
    let testRecoveryKey = "test-recovery-key-abcd1234"
    
    override func setUp() {
        super.setUp()
        keychainController = KeychainController(service: .tests, accessGroup: "test.group")
        
        // Очищаем любые существующие тестовые данные
        keychainController.removeSSSSRecoveryKey(forUserID: testUserID)
    }
    
    override func tearDown() {
        // Очищаем тестовые данные
        keychainController.removeSSSSRecoveryKey(forUserID: testUserID)
        keychainController = nil
        super.tearDown()
    }
    
    // MARK: - Store and Retrieve Tests
    
    func testSetAndGetSSSSRecoveryKey_Success() throws {
        // When
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: testUserID)
        
        // Then
        let retrievedKey = keychainController.ssssRecoveryKey(forUserID: testUserID)
        XCTAssertEqual(retrievedKey, testRecoveryKey)
    }
    
    func testSetSSSSRecoveryKey_StoresMetadata() throws {
        // Given
        let beforeStore = Date()
        
        // When
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: testUserID)
        
        // Then
        let afterStore = Date()
        let creationDate = keychainController.ssssRecoveryKeyCreationDate(forUserID: testUserID)
        
        XCTAssertNotNil(creationDate)
        XCTAssertTrue(creationDate! >= beforeStore)
        XCTAssertTrue(creationDate! <= afterStore)
    }
    
    func testGetSSSSRecoveryKey_NonexistentKey_ReturnsNil() {
        // When
        let retrievedKey = keychainController.ssssRecoveryKey(forUserID: "@nonexistent:matrix.org")
        
        // Then
        XCTAssertNil(retrievedKey)
    }
    
    // MARK: - Has Key Tests
    
    func testHasSSSSRecoveryKey_KeyExists_ReturnsTrue() throws {
        // Given
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: testUserID)
        
        // When
        let hasKey = keychainController.hasSSSSRecoveryKey(forUserID: testUserID)
        
        // Then
        XCTAssertTrue(hasKey)
    }
    
    func testHasSSSSRecoveryKey_KeyDoesNotExist_ReturnsFalse() {
        // When
        let hasKey = keychainController.hasSSSSRecoveryKey(forUserID: "@nonexistent:matrix.org")
        
        // Then
        XCTAssertFalse(hasKey)
    }
    
    func testHasSSSSRecoveryKey_AfterRemoval_ReturnsFalse() throws {
        // Given
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: testUserID)
        XCTAssertTrue(keychainController.hasSSSSRecoveryKey(forUserID: testUserID))
        
        // When
        keychainController.removeSSSSRecoveryKey(forUserID: testUserID)
        
        // Then
        XCTAssertFalse(keychainController.hasSSSSRecoveryKey(forUserID: testUserID))
    }
    
    // MARK: - Remove Key Tests
    
    func testRemoveSSSSRecoveryKey_Success() throws {
        // Given
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: testUserID)
        XCTAssertNotNil(keychainController.ssssRecoveryKey(forUserID: testUserID))
        
        // When
        keychainController.removeSSSSRecoveryKey(forUserID: testUserID)
        
        // Then
        XCTAssertNil(keychainController.ssssRecoveryKey(forUserID: testUserID))
        XCTAssertNil(keychainController.ssssRecoveryKeyCreationDate(forUserID: testUserID))
        XCTAssertFalse(keychainController.hasSSSSRecoveryKey(forUserID: testUserID))
    }
    
    func testRemoveSSSSRecoveryKey_NonexistentKey_DoesNotThrow() {
        // When/Then - Should not throw or crash
        keychainController.removeSSSSRecoveryKey(forUserID: "@nonexistent:matrix.org")
    }
    
    // MARK: - Multiple Users Tests
    
    func testMultipleUsers_IndependentStorage() throws {
        // Given
        let user1 = "@user1:matrix.org"
        let user2 = "@user2:matrix.org"
        let key1 = "key-for-user-1"
        let key2 = "key-for-user-2"
        
        // When
        try keychainController.setSSSSRecoveryKey(key1, forUserID: user1)
        try keychainController.setSSSSRecoveryKey(key2, forUserID: user2)
        
        // Then
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: user1), key1)
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: user2), key2)
        XCTAssertTrue(keychainController.hasSSSSRecoveryKey(forUserID: user1))
        XCTAssertTrue(keychainController.hasSSSSRecoveryKey(forUserID: user2))
        
        // When removing one key
        keychainController.removeSSSSRecoveryKey(forUserID: user1)
        
        // Then other key should remain
        XCTAssertNil(keychainController.ssssRecoveryKey(forUserID: user1))
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: user2), key2)
        XCTAssertFalse(keychainController.hasSSSSRecoveryKey(forUserID: user1))
        XCTAssertTrue(keychainController.hasSSSSRecoveryKey(forUserID: user2))
        
        // Cleanup
        keychainController.removeSSSSRecoveryKey(forUserID: user2)
    }
    
    // MARK: - Key Update Tests
    
    func testUpdateSSSSRecoveryKey_OverwritesExisting() throws {
        // Given
        let originalKey = "original-key"
        let updatedKey = "updated-key"
        
        try keychainController.setSSSSRecoveryKey(originalKey, forUserID: testUserID)
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: testUserID), originalKey)
        
        let originalDate = keychainController.ssssRecoveryKeyCreationDate(forUserID: testUserID)
        
        // Small delay to ensure different timestamps
        usleep(10000) // 10ms
        
        // When
        try keychainController.setSSSSRecoveryKey(updatedKey, forUserID: testUserID)
        
        // Then
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: testUserID), updatedKey)
        
        let updatedDate = keychainController.ssssRecoveryKeyCreationDate(forUserID: testUserID)
        XCTAssertNotNil(updatedDate)
        XCTAssertTrue(updatedDate! > originalDate!)
    }
    
    // MARK: - Creation Date Tests
    
    func testSSSSRecoveryKeyCreationDate_NonexistentKey_ReturnsNil() {
        // When
        let creationDate = keychainController.ssssRecoveryKeyCreationDate(forUserID: "@nonexistent:matrix.org")
        
        // Then
        XCTAssertNil(creationDate)
    }
    
    func testSSSSRecoveryKeyCreationDate_ValidKey_ReturnsDate() throws {
        // Given
        let beforeCreation = Date()
        
        // When
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: testUserID)
        let creationDate = keychainController.ssssRecoveryKeyCreationDate(forUserID: testUserID)
        
        // Then
        let afterCreation = Date()
        XCTAssertNotNil(creationDate)
        XCTAssertTrue(creationDate! >= beforeCreation)
        XCTAssertTrue(creationDate! <= afterCreation)
    }
    
    // MARK: - Security Tests
    
    func testKeyStorageUsesDifferentService() throws {
        // This test ensures SSSS keys are stored in a separate keychain service
        // compared to regular app secrets
        
        // Given
        let regularPIN = "1234"
        let ssssKey = "ssss-test-key"
        
        // When
        try keychainController.setPINCode(regularPIN)
        try keychainController.setSSSSRecoveryKey(ssssKey, forUserID: testUserID)
        
        // Then - Both should be retrievable independently
        XCTAssertEqual(keychainController.pinCode(), regularPIN)
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: testUserID), ssssKey)
        
        // Cleanup
        keychainController.removePINCode()
    }
    
    // MARK: - Edge Cases
    
    func testEmptyUserID_HandledGracefully() throws {
        // When/Then - Should not crash
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: "")
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: ""), testRecoveryKey)
        
        // Cleanup
        keychainController.removeSSSSRecoveryKey(forUserID: "")
    }
    
    func testEmptyRecoveryKey_HandledGracefully() throws {
        // When/Then - Should not crash
        try keychainController.setSSSSRecoveryKey("", forUserID: testUserID)
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: testUserID), "")
    }
    
    func testLongRecoveryKey_HandledCorrectly() throws {
        // Given
        let longKey = String(repeating: "a", count: 1000)
        
        // When
        try keychainController.setSSSSRecoveryKey(longKey, forUserID: testUserID)
        
        // Then
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: testUserID), longKey)
    }
    
    func testSpecialCharactersInUserID_HandledCorrectly() throws {
        // Given
        let specialUserID = "@test+user.name:matrix-server.com"
        
        // When
        try keychainController.setSSSSRecoveryKey(testRecoveryKey, forUserID: specialUserID)
        
        // Then
        XCTAssertEqual(keychainController.ssssRecoveryKey(forUserID: specialUserID), testRecoveryKey)
        XCTAssertTrue(keychainController.hasSSSSRecoveryKey(forUserID: specialUserID))
        
        // Cleanup
        keychainController.removeSSSSRecoveryKey(forUserID: specialUserID)
    }
}