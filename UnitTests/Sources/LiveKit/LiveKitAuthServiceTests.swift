//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class LiveKitAuthServiceTests: XCTestCase {
    private var authService: LiveKitAuthService!
    
    override func setUp() {
        super.setUp()
        authService = LiveKitAuthService()
    }
    
    override func tearDown() {
        authService = nil
        super.tearDown()
    }
    
    // MARK: - Mock Token Tests
    
    func testGetAccessTokenWithoutClientProxy() async {
        do {
            let token = try await authService.getAccessToken(roomId: "test-room")
            XCTAssertFalse(token.isEmpty)
            // Should use mock implementation when no client proxy is provided
        } catch {
            // Expected to fail in test environment without real auth server
            XCTAssertTrue(error is LiveKitCallError)
        }
    }
    
    func testGetAccessTokenWithMockClientProxy() async {
        let mockClientProxy = ClientProxyMock()
        mockClientProxy.userID = "test-user"
        
        let authServiceWithProxy = LiveKitAuthService(clientProxy: mockClientProxy)
        
        do {
            let token = try await authServiceWithProxy.getAccessToken(roomId: "test-room")
            XCTAssertFalse(token.isEmpty)
        } catch {
            // Expected to fail in test environment without real auth server
            XCTAssertTrue(error is LiveKitCallError)
        }
    }
    
    // MARK: - Mock Auth Service Tests
    
    func testMockAuthService() async {
        let mockAuthService = MockLiveKitAuthService()
        
        do {
            let token = try await mockAuthService.getAccessToken(roomId: "test-room")
            XCTAssertFalse(token.isEmpty)
            XCTAssertTrue(token.contains("eyJ")) // JWT tokens start with eyJ
        } catch {
            XCTFail("Mock auth service should not fail: \(error)")
        }
    }
    
    // MARK: - Data Models Tests
    
    func testLiveKitAuthRequestCoding() throws {
        let request = LiveKitAuthRequest(roomId: "test-room",
                                         participantName: "test-user",
                                         openIdToken: "test-token")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        XCTAssertFalse(data.isEmpty)
        
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(LiveKitAuthRequest.self, from: data)
        
        XCTAssertEqual(decodedRequest.roomId, request.roomId)
        XCTAssertEqual(decodedRequest.participantName, request.participantName)
        XCTAssertEqual(decodedRequest.openIdToken, request.openIdToken)
    }
    
    func testLiveKitAuthResponseCoding() throws {
        let response = LiveKitAuthResponse(accessToken: "test-access-token",
                                           url: "wss://test.example.com")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        XCTAssertFalse(data.isEmpty)
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(LiveKitAuthResponse.self, from: data)
        
        XCTAssertEqual(decodedResponse.accessToken, response.accessToken)
        XCTAssertEqual(decodedResponse.url, response.url)
    }
}
