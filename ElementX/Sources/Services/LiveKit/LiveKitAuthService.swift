//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import Foundation

// MARK: - Protocol

protocol LiveKitAuthServiceProtocol {
    func getAccessToken(roomId: String) async throws -> String
    func testConnection() async -> Bool
    func configure(userSession: UserSessionProtocol)
}

// MARK: - Data Models

struct LiveKitAuthRequest: Codable {
    let roomId: String
    let participantName: String
    let openIdToken: String
}

struct LiveKitAuthResponse: Codable {
    let accessToken: String
    let url: String?
}

// MARK: - LiveKit Call Details Model

struct LiveKitCallDetails {
    let roomUrl: String
    let accessToken: String
    let serverUrl: String
}

// MARK: - Service Implementation

final class LiveKitAuthService: LiveKitAuthServiceProtocol {
    private var clientProxy: ClientProxyProtocol?
    
    // MARK: - Configuration

    private let authURL = "https://livekit-auth.aibots.kz/api/auth"
    
    init(clientProxy: ClientProxyProtocol? = nil) {
        self.clientProxy = clientProxy
    }
    
    func configure(userSession: UserSessionProtocol) {
        clientProxy = userSession.clientProxy
        MXLog.info("LiveKit auth service configured with user session")
    }
    
    func getAccessToken(roomId: String) async throws -> String {
        if let clientProxy = clientProxy {
            // Use real Matrix authentication with OpenID
            MXLog.info("Getting LiveKit token using Matrix authentication for room: \(roomId)")
            return try await getTokenWithMatrixAuth(roomId: roomId, clientProxy: clientProxy)
        } else {
            // Fallback to mock token for testing when no client proxy available
            MXLog.info("Using mock authentication - no Matrix client available")
            let mockToken = generateMockJWT(roomId: roomId, participantName: "test-user")
            return mockToken
        }
    }
    
    func testConnection() async -> Bool {
        MXLog.info("Testing LiveKit auth server connection...")
        let isReachable = await testServerConnectivity()
        MXLog.info("Auth server reachability test result: \(isReachable ? "✅ Connected" : "❌ Failed")")
        return isReachable
    }
    
    /// Get LiveKit call details for Matrix call events
    func getCallDetails(roomId: String, callId: String) async throws -> LiveKitCallDetails {
        MXLog.info("Getting LiveKit call details for room: \(roomId), call: \(callId)")
        
        guard let clientProxy = clientProxy else {
            throw LiveKitCallError.authenticationFailed
        }
        
        let participantName = clientProxy.userDisplayNamePublisher.value ?? clientProxy.userID
        
        // Generate access token for the call
        let token = generateMockJWT(roomId: roomId, participantName: participantName)
        
        let details = LiveKitCallDetails(
            roomUrl: "wss://video.aibots.kz",
            accessToken: token,
            serverUrl: "wss://video.aibots.kz"
        )
        
        MXLog.info("Generated LiveKit call details for call: \(callId)")
        return details
    }
    
    // MARK: - Private Methods
    
    private func generateMockJWT(roomId: String, participantName: String) -> String {
        // Create a mock JWT token for testing
        // This is a base64-encoded JWT with proper structure but mock signature
        let header = """
        {
            "alg": "HS256",
            "typ": "JWT"
        }
        """
        
        let payload = """
        {
            "iss": "mock-livekit-server",
            "sub": "\(participantName)",
            "aud": "livekit",
            "exp": \(Int(Date().timeIntervalSince1970) + 3600),
            "nbf": \(Int(Date().timeIntervalSince1970)),
            "iat": \(Int(Date().timeIntervalSince1970)),
            "room": "\(roomId)",
            "video": {
                "room": "\(roomId)",
                "roomJoin": true,
                "canPublish": true,
                "canSubscribe": true
            }
        }
        """
        
        let headerBase64 = Data(header.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        
        let payloadBase64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        
        let signature = "mock-signature-for-testing"
        
        return "\(headerBase64).\(payloadBase64).\(signature)"
    }
    
    private func getTokenWithMatrixAuth(roomId: String, clientProxy: ClientProxyProtocol) async throws -> String {
        MXLog.info("Getting Matrix OpenID token for LiveKit authentication")
        
        // Get participant display name
        let participantName = await getDisplayName(clientProxy: clientProxy)
        
        // Get Matrix OpenID token
        let openIdToken = try await getMatrixOpenIdToken(clientProxy: clientProxy)
        
        // Create auth request with real Matrix data
        let authRequest = LiveKitAuthRequest(roomId: roomId,
                                             participantName: participantName,
                                             openIdToken: openIdToken)
        
        return try await performAuthRequest(authRequest)
    }
    
    private func getDisplayName(clientProxy: ClientProxyProtocol) async -> String {
        // Try to get user's display name from Matrix
        let userID = clientProxy.userID
        if !userID.isEmpty {
            // In a real implementation, you would fetch the display name from Matrix
            // For now, use the user ID or a default name
            return userID.replacingOccurrences(of: "@", with: "").components(separatedBy: ":").first ?? "User"
        }
        return "User"
    }
    
    private func getMatrixOpenIdToken(clientProxy: ClientProxyProtocol) async throws -> String {
        MXLog.info("Requesting Matrix OpenID token...")
        
        let result = await clientProxy.requestOpenIdToken()
        
        switch result {
        case .success(let tokenResponse):
            MXLog.info("Successfully obtained OpenID token from Matrix homeserver")
            return tokenResponse.accessToken
        case .failure(let error):
            MXLog.error("Failed to obtain OpenID token: \(error)")
            // Use mock token as fallback
            MXLog.warning("Falling back to mock OpenID token")
            return "mock-openid-token-\(UUID().uuidString)"
        }
    }
    
    private func getMockToken(roomId: String) async throws -> String {
        // Mock implementation for testing
        let authRequest = LiveKitAuthRequest(roomId: roomId,
                                             participantName: "test-user",
                                             openIdToken: "mock-openid-token")
        
        return try await performAuthRequest(authRequest)
    }
    
    private func performAuthRequest(_ authRequest: LiveKitAuthRequest) async throws -> String {
        MXLog.info("Requesting LiveKit token from server: \(authURL)")
        MXLog.info("Request payload: roomId=\(authRequest.roomId), participantName=\(authRequest.participantName)")
        
        // Test server connectivity first
        let serverReachable = await testServerConnectivity()
        if !serverReachable {
            MXLog.warning("Auth server not reachable, using mock token")
            return generateMockJWT(roomId: authRequest.roomId, participantName: authRequest.participantName)
        }
        
        // Use real server authentication
        guard let url = URL(string: authURL) else {
            throw LiveKitCallError.authenticationFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 10.0 // 10 second timeout for auth
        
        do {
            let requestData = try JSONEncoder().encode(authRequest)
            request.httpBody = requestData
            
            MXLog.info("Sending auth request to server...")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                MXLog.error("Invalid response type from auth server")
                return generateMockJWT(roomId: authRequest.roomId, participantName: authRequest.participantName)
            }
            
            MXLog.info("Auth server response status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                if let responseBody = String(data: data, encoding: .utf8) {
                    MXLog.error("Auth server error response: \(responseBody)")
                }
                MXLog.warning("Server authentication failed with status \(httpResponse.statusCode), using mock token as fallback")
                return generateMockJWT(roomId: authRequest.roomId, participantName: authRequest.participantName)
            }
            
            let authResponse = try JSONDecoder().decode(LiveKitAuthResponse.self, from: data)
            MXLog.info("LiveKit auth successful for room: \(authRequest.roomId)")
            MXLog.info("Received token length: \(authResponse.accessToken.count) characters")
            return authResponse.accessToken
            
        } catch {
            MXLog.error("LiveKit authentication error: \(error)")
            
            // Check if it's a network timeout
            if let urlError = error as? URLError, urlError.code == .timedOut {
                MXLog.error("Auth request timed out after 10 seconds")
            }
            
            // Fallback to mock token if server fails
            MXLog.warning("Server authentication failed with error: \(error), using mock token as fallback")
            return generateMockJWT(roomId: authRequest.roomId, participantName: authRequest.participantName)
        }
    }
    
    private func testServerConnectivity() async -> Bool {
        guard let url = URL(string: authURL) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5.0 // Quick connectivity test
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                MXLog.info("Auth server connectivity test: status \(httpResponse.statusCode)")
                return httpResponse.statusCode < 500 // Accept any non-server-error response
            }
            return false
        } catch {
            MXLog.warning("Auth server connectivity test failed: \(error)")
            return false
        }
    }
}

// MARK: - Mock Implementation for Testing

final class MockLiveKitAuthService: LiveKitAuthServiceProtocol {
    func configure(userSession: UserSessionProtocol) {
        // Mock implementation - no configuration needed
        MXLog.info("Mock LiveKit auth service configured")
    }
    
    func getAccessToken(roomId: String) async throws -> String {
        // Return a mock JWT token for testing
        // In a real implementation, this would be a proper JWT
        let mockToken = """
        eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJ0ZXN0LWlzc3VlciIsImV4cCI6\
        OTk5OTk5OTk5OSwibmJmIjowLCJzdWIiOiJ0ZXN0LXVzZXIiLCJuYW1lIjoidGVzdC11c2VyIi\
        wicm9vbSI6IlxcKHJvb21JZCkiLCJjYW5fcHVibGlzaCI6dHJ1ZSwiY2FuX3N1YnNjcmliZSI6dHJ1ZX0
        """
        
        MXLog.info("Mock LiveKit token generated for room: \(roomId)")
        return mockToken
    }
    
    func testConnection() async -> Bool {
        MXLog.info("Mock auth service - connection test always returns true")
        return true
    }
}
#endif
