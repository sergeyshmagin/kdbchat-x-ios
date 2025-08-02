//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

/// CRITICAL FIX: Matrix Call Event Processor for LiveKit Integration
/// Handles Matrix m.call.invite events and extracts application_data for LiveKit auto-connect
final class MatrixCallEventProcessor: ObservableObject {
    private let clientProxy: ClientProxyProtocol
    
    init(clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
    }
    
    /// Process incoming Matrix call events and extract LiveKit credentials
    /// This runs in the main app context where we have full access to Matrix events
    func processIncomingCallEvent(roomId: String, eventId: String) async -> LiveKitCredentials? {
        MXLog.info("[MATRIX-CALL-PROCESSOR] Processing call event: \(eventId) in room: \(roomId)")
        
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomId) else {
            MXLog.error("[MATRIX-CALL-PROCESSOR] Room not found or not joined: \(roomId)")
            return nil
        }
        
        // CRITICAL: We need to access the timeline to find the event
        // This is the ONLY way to get application_data from Matrix events in ElementX
        return await extractCredentialsFromTimeline(roomProxy: roomProxy, eventId: eventId)
    }
    
    /// Extract LiveKit credentials from room timeline
    private func extractCredentialsFromTimeline(roomProxy: RoomProxyProtocol, eventId: String) async -> LiveKitCredentials? {
        MXLog.info("[MATRIX-CALL-PROCESSOR] Searching timeline for event: \(eventId)")
        
        // CRITICAL LIMITATION: ElementX doesn't expose raw event content directly
        // We need to use a different approach - extract from the original push notification
        // that triggered this call
        
        MXLog.warning("[MATRIX-CALL-PROCESSOR] ElementX limitation: Cannot access raw Matrix event JSON")
        MXLog.warning("[MATRIX-CALL-PROCESSOR] Falling back to push notification payload extraction")
        
        // Check if we have stored credentials from the push notification
        return await extractCredentialsFromStoredPushData(eventId: eventId)
    }
    
    /// Extract credentials from stored push notification data
    private func extractCredentialsFromStoredPushData(eventId: String) async -> LiveKitCredentials? {
        // Check App Group storage for push notification data
        guard let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") else {
            MXLog.error("[MATRIX-CALL-PROCESSOR] Cannot access App Group UserDefaults")
            return nil
        }
        
        // Look for stored push data that matches this event
        if let storedPushData = appGroupDefaults.dictionary(forKey: "last_call_push_\(eventId)") {
            MXLog.info("[MATRIX-CALL-PROCESSOR] Found stored push data for event: \(eventId)")
            
            let accessToken = storedPushData["livekit_access_token"] as? String
            let serverURL = storedPushData["livekit_server_url"] as? String
            let roomURL = storedPushData["livekit_room_url"] as? String
            
            if let token = accessToken, let server = serverURL, !token.isEmpty, !server.isEmpty {
                return LiveKitCredentials(accessToken: token,
                                          serverURL: server,
                                          roomURL: roomURL)
            }
        }
        
        MXLog.warning("[MATRIX-CALL-PROCESSOR] No stored push data found for event: \(eventId)")
        return nil
    }
    
    /// Store push notification data for later retrieval
    /// This should be called when a VoIP push is received
    func storePushNotificationData(eventId: String, payload: [AnyHashable: Any]) {
        guard let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") else {
            MXLog.error("[MATRIX-CALL-PROCESSOR] Cannot access App Group UserDefaults for storing")
            return
        }
        
        MXLog.info("[MATRIX-CALL-PROCESSOR] Storing push data for event: \(eventId)")
        
        // Extract and store LiveKit credentials from push payload
        let credentials = extractCredentialsFromPushPayload(payload)
        
        let pushData: [String: Any] = [
            "event_id": eventId,
            "timestamp": Date().timeIntervalSince1970,
            "livekit_access_token": credentials.accessToken ?? "",
            "livekit_server_url": credentials.serverURL ?? "",
            "livekit_room_url": credentials.roomURL ?? ""
        ]
        
        // Store with event-specific key
        appGroupDefaults.set(pushData, forKey: "last_call_push_\(eventId)")
        appGroupDefaults.synchronize()
        
        MXLog.info("[MATRIX-CALL-PROCESSOR] Successfully stored push data for event: \(eventId)")
    }
    
    /// Extract LiveKit credentials from push notification payload
    private func extractCredentialsFromPushPayload(_ payload: [AnyHashable: Any]) -> LiveKitCredentials {
        MXLog.info("[MATRIX-CALL-PROCESSOR] Extracting credentials from push payload")
        
        // Look for application_data in various formats
        var accessToken: String?
        var serverURL: String?
        var roomURL: String?
        
        // Method 1: Direct keys
        accessToken = payload["livekit_access_token"] as? String ??
            payload["lk_token"] as? String
        
        serverURL = payload["livekit_server_url"] as? String ??
            payload["lk_url"] as? String ??
            "wss://video.aibots.kz"
        
        roomURL = payload["livekit_room_url"] as? String ??
            payload["lk_room"] as? String
        
        // Method 2: application_data object
        if let applicationData = payload["application_data"] as? [String: Any] {
            accessToken = accessToken ?? applicationData["livekit_access_token"] as? String ??
                applicationData["lk_token"] as? String
            
            serverURL = serverURL ?? applicationData["livekit_server_url"] as? String ??
                applicationData["lk_url"] as? String
            
            roomURL = roomURL ?? applicationData["livekit_room_url"] as? String ??
                applicationData["lk_room"] as? String
        }
        
        // Method 3: Nested in content
        if let content = payload["content"] as? [String: Any],
           let applicationData = content["application_data"] as? [String: Any] {
            accessToken = accessToken ?? applicationData["livekit_access_token"] as? String
            serverURL = serverURL ?? applicationData["livekit_server_url"] as? String
            roomURL = roomURL ?? applicationData["livekit_room_url"] as? String
        }
        
        MXLog.info("[MATRIX-CALL-PROCESSOR] Extracted - Token: \(accessToken != nil ? "[PRESENT]" : "[MISSING]"), Server: \(serverURL ?? "[MISSING]")")
        
        return LiveKitCredentials(accessToken: accessToken,
                                  serverURL: serverURL,
                                  roomURL: roomURL)
    }
}

/// LiveKit credentials structure
struct LiveKitCredentials {
    let accessToken: String?
    let serverURL: String?
    let roomURL: String?
}
