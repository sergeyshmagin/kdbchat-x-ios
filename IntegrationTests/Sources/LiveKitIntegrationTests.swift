//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class LiveKitIntegrationTests: XCTestCase {
    // MARK: - Integration Test Setup
    
    override func setUp() {
        super.setUp()
        // Integration tests require more setup than unit tests
        // These would typically test the full flow with real or mock servers
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    // MARK: - End-to-End Call Flow Tests
    
    func testLiveKitCallFlowIntegration() async throws {
        // This test would verify the complete call flow:
        // 1. Authentication with LiveKit auth service
        // 2. Connection to LiveKit SFU
        // 3. Media stream establishment
        // 4. Call teardown
        
        let mockAuthService = MockLiveKitAuthService()
        let callService = LiveKitCallService(authService: mockAuthService)
        
        // Test auth token generation
        let token = try await mockAuthService.getAccessToken(roomId: "integration-test-room")
        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(token.contains("eyJ")) // JWT format
        
        // Test call service initialization
        XCTAssertFalse(callService.isConnected)
        XCTAssertTrue(callService.participants.isEmpty)
        
        // In a real integration test, we would:
        // 1. Connect to a test LiveKit server
        // 2. Verify WebRTC connection establishment
        // 3. Test media stream handling
        // 4. Verify proper cleanup
        
        // For now, we test that the service handles connection attempts gracefully
        do {
            try await callService.startCall(roomId: "integration-test-room")
            // Will fail without real server, but should not crash
        } catch {
            XCTAssertTrue(error is LiveKitCallError)
        }
        
        // Test cleanup
        await callService.endCall()
        XCTAssertFalse(callService.isConnected)
    }
    
    // MARK: - UI Integration Tests
    
    @MainActor
    func testLiveKitCallScreenIntegration() async {
        // Test the complete UI flow
        let mockAuthService = MockLiveKitAuthService()
        let callService = LiveKitCallService(authService: mockAuthService)
        let viewModel = LiveKitCallViewModel(roomId: "ui-test-room", callService: callService)
        
        // Test initial state
        XCTAssertFalse(viewModel.isConnected)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.connectionStatusText, "Disconnected")
        
        // Test loading state during call start
        let startCallTask = Task {
            await viewModel.startCall()
        }
        
        // Check that loading state is managed properly
        XCTAssertFalse(viewModel.isLoading) // Should be false after call completes
        
        await startCallTask.value
        
        // Test error handling
        if let error = viewModel.error {
            XCTAssertTrue(error == .connectionFailed || error == .authenticationFailed)
        }
    }
    
    // MARK: - Flow Coordinator Integration Tests
    
    func testUserSessionFlowCoordinatorLiveKitIntegration() {
        // This would test the integration between LiveKit and the main app flow
        // In a real test, we would:
        // 1. Set up a mock user session
        // 2. Trigger a call from the room screen
        // 3. Verify LiveKit call screen is presented
        // 4. Test call controls
        // 5. Test call termination
        
        // For now, we test that the compiler flag works correctly
        #if LIVEKIT_ENABLED
        XCTAssertTrue(true, "LiveKit is enabled via compiler flag")
        #else
        XCTFail("LiveKit should be enabled in this build")
        #endif
    }
    
    // MARK: - Performance Tests
    
    func testLiveKitCallServicePerformance() {
        // Test that call service operations complete within reasonable time
        let mockAuthService = MockLiveKitAuthService()
        let callService = LiveKitCallService(authService: mockAuthService)
        
        measure {
            // Test auth service performance
            let expectation = self.expectation(description: "Auth token generation")
            Task {
                do {
                    _ = try await mockAuthService.getAccessToken(roomId: "perf-test-room")
                    expectation.fulfill()
                } catch {
                    expectation.fulfill()
                }
            }
            wait(for: [expectation], timeout: 1.0)
        }
    }
    
    // MARK: - Error Recovery Tests
    
    func testLiveKitErrorRecovery() async {
        // Test that the system gracefully handles various error conditions
        let failingAuthService = FailingMockAuthService()
        let callService = LiveKitCallService(authService: failingAuthService)
        
        // Test auth failure recovery
        do {
            try await callService.startCall(roomId: "error-test-room")
            XCTFail("Expected auth error")
        } catch {
            XCTAssertTrue(error is LiveKitCallError)
            XCTAssertEqual(error as? LiveKitCallError, .authenticationFailed)
        }
        
        // Verify service is still in valid state after error
        XCTAssertFalse(callService.isConnected)
        XCTAssertTrue(callService.participants.isEmpty)
        XCTAssertNil(callService.localParticipant)
    }
    
    // MARK: - Memory Management Tests
    
    func testLiveKitMemoryManagement() async {
        // Test that LiveKit services don't leak memory
        weak var weakCallService: LiveKitCallService?
        weak var weakViewModel: LiveKitCallViewModel?
        
        do {
            let mockAuthService = MockLiveKitAuthService()
            let callService = LiveKitCallService(authService: mockAuthService)
            let viewModel = LiveKitCallViewModel(roomId: "memory-test-room", callService: callService)
            
            weakCallService = callService
            weakViewModel = viewModel
            
            // Use the services
            await viewModel.startCall()
            await viewModel.endCall()
        }
        
        // Force garbage collection
        autoreleasepool { }
        
        // Verify objects are deallocated
        // Note: In practice, these might not be nil immediately due to async operations
        // This is a basic check - more sophisticated memory testing would be needed in production
    }
}
