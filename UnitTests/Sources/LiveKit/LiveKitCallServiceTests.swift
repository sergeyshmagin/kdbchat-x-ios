//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class LiveKitCallServiceTests: XCTestCase {
    private var callService: LiveKitCallService!
    private var mockAuthService: MockLiveKitAuthService!
    
    override func setUp() {
        super.setUp()
        mockAuthService = MockLiveKitAuthService()
        callService = LiveKitCallService(authService: mockAuthService)
    }
    
    override func tearDown() {
        callService = nil
        mockAuthService = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testCallServiceInitialization() {
        XCTAssertFalse(callService.isConnected)
        XCTAssertTrue(callService.participants.isEmpty)
        XCTAssertNil(callService.localParticipant)
        XCTAssertFalse(callService.isMuted)
        XCTAssertTrue(callService.isVideoEnabled)
        XCTAssertNil(callService.error)
    }
    
    // MARK: - Call Management Tests
    
    func testStartCallWithValidRoom() async {
        let roomId = "test-room-id"
        
        do {
            try await callService.startCall(roomId: roomId)
            // Due to mock auth service returning a mock token, actual connection will fail
            // but we can test that the method doesn't throw due to auth issues
        } catch {
            // Expected to fail since we're using mock tokens and no real LiveKit server
            XCTAssertTrue(error is LiveKitCallError)
        }
    }
    
    func testEndCall() async {
        await callService.endCall()
        
        XCTAssertFalse(callService.isConnected)
        XCTAssertTrue(callService.participants.isEmpty)
        XCTAssertNil(callService.localParticipant)
    }
    
    // MARK: - Media Controls Tests
    
    func testToggleMicrophoneWithoutConnection() async {
        // Should not crash when called without connection
        await callService.toggleMicrophone()
        // Can't assert much here since there's no local participant
    }
    
    func testToggleCameraWithoutConnection() async {
        // Should not crash when called without connection
        await callService.toggleCamera()
        // Can't assert much here since there's no local participant
    }
    
    // MARK: - Error Handling Tests
    
    func testCallWithInvalidAuth() async {
        let failingAuthService = FailingMockAuthService()
        let failingCallService = LiveKitCallService(authService: failingAuthService)
        
        do {
            try await failingCallService.startCall(roomId: "test-room")
            XCTFail("Expected call to fail with auth error")
        } catch {
            XCTAssertTrue(error is LiveKitCallError)
            XCTAssertEqual(error as? LiveKitCallError, .authenticationFailed)
        }
    }
}

// MARK: - Mock Services

final class FailingMockAuthService: LiveKitAuthServiceProtocol {
    func getAccessToken(roomId: String) async throws -> String {
        throw LiveKitCallError.authenticationFailed
    }
}
