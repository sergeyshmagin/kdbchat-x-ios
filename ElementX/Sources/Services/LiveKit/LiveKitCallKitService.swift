//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import AVFoundation
import CallKit
import Foundation
import LiveKit
import MatrixRustSDK
import PushKit
import UIKit

enum LiveKitCallKitError: Error, LocalizedError {
    case providerConfigurationFailed
    case callNotFound
    case callAlreadyActive
    case permissionDenied
    case audioSessionError
    
    var errorDescription: String? {
        switch self {
        case .providerConfigurationFailed:
            return "Failed to configure CallKit provider"
        case .callNotFound:
            return "Call not found"
        case .callAlreadyActive:
            return "Call already active"
        case .permissionDenied:
            return "CallKit permission denied"
        case .audioSessionError:
            return "Audio session configuration error"
        }
    }
}

final class LiveKitCallKitService: NSObject, ObservableObject {
    // MARK: - Properties
    
    static let shared = LiveKitCallKitService()
    
    private let provider: CXProvider
    private let callController: CXCallController
    private var liveKitCallService: LiveKitCallService?
    private var clientProxy: ClientProxyProtocol?
    
    @Published var activeCall: LiveKitCall?
    @Published var isCallActive = false
    
    // Хранение активных VoIP push вызовов
    private var pendingVoIPCalls: [UUID: PKPushPayload] = [:]
    
    // Track ongoing calls
    private var activeCalls: [UUID: LiveKitCall] = [:]
    
    // MARK: - Initialization
    
    override init() {
        // Configure CallKit provider
        let configuration = CXProviderConfiguration(localizedName: "kdbchat")
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        
        // Audio configuration
        configuration.includesCallsInRecents = true
        
        // Icons and ringtones
        if let iconImage = UIImage(named: "AppIcon") {
            configuration.iconTemplateImageData = iconImage.pngData()
        }
        
        provider = CXProvider(configuration: configuration)
        callController = CXCallController()
        
        super.init()
        
        provider.setDelegate(self, queue: nil)
        
        MXLog.info("LiveKitCallKitService initialized")
    }
    
    // MARK: - Public Methods
    
    func setLiveKitCallService(_ service: LiveKitCallService) {
        liveKitCallService = service
    }
    
    func configureWithClientProxy(_ clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
        MXLog.info("LiveKitCallKitService configured with client proxy")
        
        // Register any previously stored VoIP push token
        Task {
            await registerStoredVoIPTokenIfNeeded()
        }
        
        // VoIP push token registration is now handled by NotificationManager
    }
    
    /// Register VoIP push token via NotificationManager (removed - now handled elsewhere)
    private func registerVoIPPushToken(_ tokenData: Data) async {
        // This functionality has been moved to NotificationManager
        MXLog.info("VoIP push token registration now handled by NotificationManager")
    }
    
    private func registerStoredVoIPTokenIfNeeded() async {
        // Check if we have a stored token from before login
        if let storedTokenData = UserDefaults.standard.data(forKey: "voip_push_token") {
            MXLog.info("Found stored VoIP push token, registering with Matrix after login")
            await registerVoIPPushToken(storedTokenData)
            // Clean up stored token after successful registration
            UserDefaults.standard.removeObject(forKey: "voip_push_token")
        }
    }
    
    /// Report an incoming call to CallKit
    func reportIncomingCall(roomId: String, callId: String, callerName: String, hasVideo: Bool = true) async throws {
        let callUUID = UUID()
        
        MXLog.info("Reporting incoming call: \(callId) from \(callerName) (video: \(hasVideo))")
        
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: roomId)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        
        let call = LiveKitCall(id: callId,
                               roomId: roomId,
                               callUUID: callUUID,
                               isIncoming: true,
                               callerName: callerName,
                               hasVideo: hasVideo)
        
        activeCalls[callUUID] = call
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: callUUID, update: update) { error in
                if let error = error {
                    MXLog.error("Failed to report incoming call: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    MXLog.info("Successfully reported incoming call")
                    continuation.resume()
                }
            }
        }
    }
    
    /// Start an outgoing call through CallKit
    func startOutgoingCall(roomId: String, callId: String, participantName: String, isVideo: Bool = true) async throws {
        let callUUID = UUID()
        
        MXLog.info("Starting outgoing call: \(callId) to \(participantName) (video: \(isVideo))")
        
        let handle = CXHandle(type: .generic, value: roomId)
        let startCallAction = CXStartCallAction(call: callUUID, handle: handle)
        startCallAction.isVideo = isVideo
        startCallAction.contactIdentifier = participantName
        
        let call = LiveKitCall(id: callId,
                               roomId: roomId,
                               callUUID: callUUID,
                               isIncoming: false,
                               callerName: participantName,
                               hasVideo: isVideo)
        
        activeCalls[callUUID] = call
        
        let transaction = CXTransaction(action: startCallAction)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error = error {
                    MXLog.error("Failed to start outgoing call: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    MXLog.info("Successfully started outgoing call")
                    continuation.resume()
                }
            }
        }
    }
    
    /// End the current call
    func endCall(callUUID: UUID) async throws {
        MXLog.info("Ending call: \(callUUID)")
        
        let endCallAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: endCallAction)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error = error {
                    MXLog.error("Failed to end call: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    MXLog.info("Successfully ended call")
                    continuation.resume()
                }
            }
        }
    }
    
    /// Report an incoming call with LiveKit credentials from VoIP push payload
    func reportIncomingCallWithCredentials(roomId: String, callId: String, callerName: String, hasVideo: Bool = true,
                                          liveKitAccessToken: String?, liveKitServerURL: String?, liveKitRoomURL: String?) async throws {
        let callUUID = UUID()
        
        MXLog.info("📞 Reporting incoming call with LiveKit credentials: \(callId) from \(callerName)")
        MXLog.info("🎬 LiveKit Server: \(liveKitServerURL ?? "nil"), Token: \(liveKitAccessToken != nil ? "[PRESENT]" : "[MISSING]")")
        
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: roomId)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        
        let call = LiveKitCall(id: callId,
                               roomId: roomId,
                               callUUID: callUUID,
                               isIncoming: true,
                               callerName: callerName,
                               hasVideo: hasVideo,
                               liveKitAccessToken: liveKitAccessToken,
                               liveKitServerURL: liveKitServerURL,
                               liveKitRoomURL: liveKitRoomURL)
        
        activeCalls[callUUID] = call
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: callUUID, update: update) { error in
                if let error = error {
                    MXLog.error("❌ Failed to report incoming call with credentials: \(error)")
                    self.activeCalls.removeValue(forKey: callUUID)
                    continuation.resume(throwing: error)
                } else {
                    MXLog.info("✅ Successfully reported incoming call with LiveKit credentials")
                    continuation.resume()
                }
            }
        }
    }
    
    /// Update call with new information
    func updateCall(callUUID: UUID, update: CXCallUpdate) {
        provider.reportCall(with: callUUID, updated: update)
    }
    
    /// Report call ended
    func reportCallEnded(callUUID: UUID, reason: CXCallEndedReason) {
        MXLog.info("Reporting call ended: \(callUUID), reason: \(reason)")
        provider.reportCall(with: callUUID, endedAt: Date(), reason: reason)
        activeCalls.removeValue(forKey: callUUID)
        
        if activeCalls.isEmpty {
            activeCall = nil
            isCallActive = false
        }
    }
    
    // MARK: - Private Methods
    
    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        try audioSession.setActive(true)
        
        MXLog.info("Audio session configured for CallKit")
    }
}

// MARK: - CXProviderDelegate

extension LiveKitCallKitService: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        MXLog.info("CallKit provider did reset")
        
        // End all active calls
        for _ in activeCalls.values {
            Task {
                await liveKitCallService?.endCall()
            }
        }
        
        activeCalls.removeAll()
        activeCall = nil
        isCallActive = false
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MXLog.info("CallKit: Starting call \(action.callUUID) (video: \(action.isVideo))")
        
        guard let call = activeCalls[action.callUUID] else {
            MXLog.error("Call not found for UUID: \(action.callUUID)")
            action.fail()
            return
        }
        
        Task {
            do {
                try configureAudioSession()
                
                // Configure video enabled state before starting call
                liveKitCallService?.isVideoEnabled = action.isVideo
                MXLog.info("LiveKit configured for video enabled: \(action.isVideo)")
                
                // Start the LiveKit call
                try await liveKitCallService?.startCall(roomId: call.roomId, callId: call.id)
                
                activeCall = call
                isCallActive = true
                
                action.fulfill()
                MXLog.info("CallKit: Successfully started call")
            } catch {
                MXLog.error("Failed to start LiveKit call: \(error)")
                action.fail()
            }
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MXLog.info("CallKit: Answering call \(action.callUUID)")
        
        guard let call = activeCalls[action.callUUID] else {
            MXLog.error("Call not found for UUID: \(action.callUUID)")
            action.fail()
            return
        }
        
        Task {
            do {
                try configureAudioSession()
                
                // Check if this was a video call based on the original call info
                let hasVideo = call.hasVideo ?? true // Default to video for backward compatibility
                liveKitCallService?.isVideoEnabled = hasVideo
                MXLog.info("LiveKit configured for answering call with video enabled: \(hasVideo)")
                
                // CRITICAL: Check multiple sources for LiveKit credentials
                var finalAccessToken: String?
                var finalServerURL: String?
                var finalRoomURL: String?
                
                // Priority 1: Stored credentials from VoIP push
                if let accessToken = call.liveKitAccessToken,
                   let serverURL = call.liveKitServerURL,
                   !accessToken.isEmpty,
                   !serverURL.isEmpty {
                    finalAccessToken = accessToken
                    finalServerURL = serverURL
                    finalRoomURL = call.liveKitRoomURL
                    MXLog.info("🎬 Found stored LiveKit credentials from VoIP push")
                }
                
                // Priority 2: Check App Group for credentials from NSE
                if finalAccessToken == nil {
                    let appGroupCredentials = extractCredentialsFromAppGroup()
                    if let accessToken = appGroupCredentials.accessToken,
                       let serverURL = appGroupCredentials.serverURL,
                       !accessToken.isEmpty,
                       !serverURL.isEmpty {
                        finalAccessToken = accessToken
                        finalServerURL = serverURL
                        finalRoomURL = appGroupCredentials.roomURL
                        MXLog.info("🎬 Found LiveKit credentials from App Group storage")
                    }
                }
                
                // Use auto-connect if credentials are available
                if let accessToken = finalAccessToken,
                   let serverURL = finalServerURL,
                   !accessToken.isEmpty,
                   !serverURL.isEmpty {
                    MXLog.info("🎬 Using LiveKit credentials for auto-connect")
                    MXLog.info("🔑 Server: \(serverURL), Token: [PRESENT]")
                    
                    do {
                        // Use credentials directly to connect to LiveKit room
                        try await liveKitCallService?.answerCallWithCredentials(
                            roomId: call.roomId,
                            callId: call.id,
                            accessToken: accessToken,
                            serverURL: serverURL,
                            roomURL: finalRoomURL
                        )
                        MXLog.info("✅ Auto-connect with credentials successful")
                    } catch {
                        MXLog.error("❌ Auto-connect with credentials failed: \(error)")
                        MXLog.info("🔄 Falling back to standard auth flow")
                        
                        // Fallback to standard flow if credentials failed
                        try await liveKitCallService?.answerCall(roomId: call.roomId, callId: call.id)
                    }
                } else {
                    MXLog.warning("⚠️ CRITICAL: No LiveKit credentials found!")
                    MXLog.warning("⚠️ Check Matrix homeserver configuration - application_data may be missing from push notifications")
                    MXLog.warning("⚠️ See MATRIX_HOMESERVER_CONFIG.md for configuration details")
                    MXLog.info("🔄 Using standard auth flow as fallback")
                    
                    // Standard answer flow - generate token on demand
                    try await liveKitCallService?.answerCall(roomId: call.roomId, callId: call.id)
                }
                
                // Send Matrix call answer event
                do {
                    try await sendMatrixCallAnswer(roomId: call.roomId, callId: call.id)
                    MXLog.info("✅ Sent m.call.answer for call \(call.id)")
                } catch {
                    MXLog.error("❌ Failed to send m.call.answer: \(error)")
                }
                
                activeCall = call
                isCallActive = true
                
                action.fulfill()
                MXLog.info("CallKit: Successfully answered call with auto-connect")
            } catch {
                MXLog.error("Failed to answer LiveKit call: \(error)")
                action.fail()
            }
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MXLog.info("CallKit: Ending call \(action.callUUID)")
        
        guard let call = activeCalls[action.callUUID] else {
            MXLog.error("Call not found for UUID: \(action.callUUID)")
            action.fail()
            return
        }
        
        Task {
            do {
                // End the LiveKit call
                await liveKitCallService?.endCall()
                
                // Send Matrix call hangup event
                do {
                    try await sendMatrixCallHangup(roomId: call.roomId, callId: call.id, reason: "user_hangup")
                    MXLog.info("✅ Sent m.call.hangup for call \(call.id)")
                } catch {
                    MXLog.error("❌ Failed to send m.call.hangup: \(error)")
                }
                
                activeCalls.removeValue(forKey: action.callUUID)
                
                if activeCalls.isEmpty {
                    activeCall = nil
                    isCallActive = false
                }
                
                action.fulfill()
                MXLog.info("CallKit: Successfully ended call")
            } catch {
                MXLog.error("Failed to end LiveKit call: \(error)")
                action.fail()
            }
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MXLog.info("CallKit: Setting mute \(action.isMuted) for call \(action.callUUID)")
        
        Task {
            await liveKitCallService?.setMuted(action.isMuted)
            action.fulfill()
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        MXLog.info("CallKit: Setting hold \(action.isOnHold) for call \(action.callUUID)")
        
        // LiveKit doesn't support hold, so we'll just acknowledge
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MXLog.error("CallKit: Action timed out: \(action)")
        action.fail()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MXLog.info("CallKit: Audio session activated")
        
        // Configure LiveKit audio
        Task {
            await liveKitCallService?.configureAudio()
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MXLog.info("CallKit: Audio session deactivated")
    }
}

// MARK: - Supporting Types

struct LiveKitCall: Identifiable {
    let id: String
    let roomId: String
    let callUUID: UUID
    let isIncoming: Bool
    let callerName: String
    let startTime: Date
    let hasVideo: Bool?
    
    // LiveKit credentials from push payload
    let liveKitAccessToken: String?
    let liveKitServerURL: String?
    let liveKitRoomURL: String?
    
    init(id: String, roomId: String, callUUID: UUID, isIncoming: Bool, callerName: String, hasVideo: Bool? = nil,
         liveKitAccessToken: String? = nil, liveKitServerURL: String? = nil, liveKitRoomURL: String? = nil) {
        self.id = id
        self.roomId = roomId
        self.callUUID = callUUID
        self.isIncoming = isIncoming
        self.callerName = callerName
        self.hasVideo = hasVideo
        self.liveKitAccessToken = liveKitAccessToken
        self.liveKitServerURL = liveKitServerURL
        self.liveKitRoomURL = liveKitRoomURL
        startTime = Date()
    }
}

// MARK: - VoIP Push Handling (handled by PushNotificationManager)

extension LiveKitCallKitService {
    /// Handle VoIP push notification (can be called from PushNotificationManager)
    func handleVoIPPush(payload: PKPushPayload, completion: @escaping () -> Void) {
        MXLog.info("📞 LiveKit received incoming VoIP push notification")
        MXLog.info("📞 VoIP push payload keys: \(payload.dictionaryPayload.keys.map { String(describing: $0) }.joined(separator: ", "))")
        MXLog.info("📞 VoIP push payload: \(payload.dictionaryPayload)")
        
        // Log specific fields we're looking for
        if let applicationData = payload.dictionaryPayload["application_data"] {
            MXLog.info("📞 Found application_data in payload: \(applicationData)")
        }
        if let content = payload.dictionaryPayload["content"] {
            MXLog.info("📞 Found content in payload: \(content)")
        }
        
        // Check for error messages in payload that might indicate token issues
        if let errorMessage = payload.dictionaryPayload["error"] as? String {
            MXLog.error("❌ VoIP push contains error: \(errorMessage)")
            if errorMessage.lowercased().contains("invalid") || errorMessage.lowercased().contains("token") {
                MXLog.warning("🔄 VoIP error indicates token issue - requesting refresh")
                Task {
                    // await PushNotificationManager.shared.refreshVoIPToken() // Removed - now handled by NotificationManager
                }
            }
            completion()
            return
        }
        
        // Extract event details from Matrix push payload
        guard let eventId = payload.dictionaryPayload["event_id"] as? String,
              let roomId = payload.dictionaryPayload["room_id"] as? String else {
            // Fallback to ElementCall format for compatibility
            guard let roomID = payload.dictionaryPayload[ElementCallServiceNotificationKey.roomID.rawValue] as? String else {
                MXLog.error("❌ Missing room identifier for incoming call: \(payload)")
                reportFakeCallForAPNsCompliance(completion: completion)
                return
            }
            
            let roomDisplayName = payload.dictionaryPayload[ElementCallServiceNotificationKey.roomDisplayName.rawValue] as? String ?? "Unknown"
            let callId = UUID().uuidString
            
            // Extract LiveKit credentials from CallKit payload
            let liveKitCredentials = extractLiveKitCredentialsFromCallKitPayload(payload.dictionaryPayload)
            
            processIncomingCallWithCredentials(roomId: roomID, 
                                             callId: callId, 
                                             callerName: roomDisplayName, 
                                             hasVideo: true,
                                             liveKitCredentials: liveKitCredentials,
                                             completion: completion)
            return
        }
        
        // Process Matrix m.call.invite event
        processMatrixCallInvite(eventId: eventId, roomId: roomId, payload: payload.dictionaryPayload, completion: completion)
    }
    
    private func processMatrixCallInvite(eventId: String, roomId: String, payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        // Extract caller information using improved algorithm
        let callerInfo = extractCallerInfo(from: payload)
        let isVideoCall = payload["is_video"] as? Bool ?? true
        
        MXLog.info("📞 Processing Matrix call invite - Event: \(eventId), Room: \(roomId), Caller: \(callerInfo.displayName), Video: \(isVideoCall)")
        
        // Check for duplicate calls
        guard activeCall?.roomId != roomId else {
            MXLog.warning("Call already active for room \(roomId), ignoring")
            completion()
            return
        }
        
        // Extract LiveKit credentials from payload
        let liveKitCredentials = extractLiveKitCredentialsFromPayload(payload)
        
        processIncomingCallWithCredentials(roomId: roomId, 
                                          callId: eventId, 
                                          callerName: callerInfo.displayName, 
                                          hasVideo: isVideoCall,
                                          liveKitCredentials: liveKitCredentials,
                                          completion: completion)
    }
    
    /// Структура для информации о звонящем
    private struct CallerInfo {
        let senderId: String
        let displayName: String
        let roomName: String?
    }
    
    /// Извлекает информацию о звонящем из push payload с множественными fallback вариантами
    private func extractCallerInfo(from payload: [AnyHashable: Any]) -> CallerInfo {
        let senderId = payload["sender"] as? String ?? ""
        var displayName = "Unknown Caller"
        let roomName = payload["room_name"] as? String
        
        // 1. Пытаемся извлечь из основного payload
        if let senderDisplayName = payload["sender_display_name"] as? String, !senderDisplayName.isEmpty {
            displayName = senderDisplayName
            MXLog.info("✅ Extracted caller name from sender_display_name: \(displayName)")
        }
        // 2. Пытаемся извлечь из content
        else if let content = payload["content"] as? [String: Any],
                let senderDisplayName = content["sender_display_name"] as? String, !senderDisplayName.isEmpty {
            displayName = senderDisplayName
            MXLog.info("✅ Extracted caller name from content.sender_display_name: \(displayName)")
        }
        // 3. Пытаемся использовать room_name если это не room ID
        else if let roomName = roomName, !roomName.isEmpty, roomName != payload["room_id"] as? String {
            displayName = roomName
            MXLog.info("✅ Using room name as caller name: \(displayName)")
        }
        // 4. Извлекаем из Matrix User ID (@testuser1:domain → testuser1)
        else if senderId.hasPrefix("@") {
            if let atIndex = senderId.firstIndex(of: "@"),
               let colonIndex = senderId.firstIndex(of: ":") {
                let username = String(senderId[senderId.index(after: atIndex)..<colonIndex])
                displayName = username.capitalized
                MXLog.info("✅ Extracted username from Matrix ID: \(displayName)")
            } else {
                // Fallback если нет двоеточия
                displayName = String(senderId.dropFirst()).capitalized
                MXLog.info("✅ Fallback username extraction: \(displayName)")
            }
        }
        // 5. Пытаемся извлечь из event content (для m.call.invite events)
        else if let content = payload["content"] as? [String: Any],
                let callContent = content["call"] as? [String: Any],
                let senderDisplayName = callContent["sender_display_name"] as? String, !senderDisplayName.isEmpty {
            displayName = senderDisplayName
            MXLog.info("✅ Extracted caller name from call content: \(displayName)")
        } else {
            MXLog.warning("⚠️ Could not extract caller name, using fallback: \(displayName)")
        }
        
        return CallerInfo(senderId: senderId, displayName: displayName, roomName: roomName)
    }
    
    /// LiveKit credentials from VoIP push payload
    private struct LiveKitCredentials {
        let accessToken: String?
        let serverURL: String?
        let roomURL: String?
    }
    
    /// Extract LiveKit credentials from CallKit payload (from NSE)
    private func extractLiveKitCredentialsFromCallKitPayload(_ payload: [AnyHashable: Any]) -> LiveKitCredentials {
        MXLog.info("[CALLKIT-CREDENTIALS] Extracting LiveKit credentials from CallKit payload")
        
        let accessToken = payload["livekit_access_token"] as? String
        let serverURL = payload["livekit_server_url"] as? String ?? "wss://video.aibots.kz"
        let roomURL = payload["livekit_room_url"] as? String
        
        MXLog.info("[CALLKIT-CREDENTIALS] Found credentials - Token: \(accessToken != nil ? "[PRESENT]" : "[MISSING]"), Server: \(serverURL)")
        
        return LiveKitCredentials(
            accessToken: accessToken,
            serverURL: serverURL,
            roomURL: roomURL
        )
    }
    
    /// Extract LiveKit credentials from VoIP push payload
    private func extractLiveKitCredentialsFromPayload(_ payload: [AnyHashable: Any]) -> LiveKitCredentials {
        // Try to extract LiveKit credentials from various payload locations
        let accessToken = payload["livekit_access_token"] as? String ??
                         (payload["application_data"] as? [String: Any])?["livekit_access_token"] as? String ??
                         extractFromApplicationDataString(payload, key: "livekit_access_token")
        
        let serverURL = payload["livekit_server_url"] as? String ??
                       (payload["application_data"] as? [String: Any])?["livekit_server_url"] as? String ??
                       extractFromApplicationDataString(payload, key: "livekit_server_url") ??
                       "wss://video.aibots.kz" // Default server URL
        
        let roomURL = payload["livekit_room_url"] as? String ??
                     (payload["application_data"] as? [String: Any])?["livekit_room_url"] as? String ??
                     extractFromApplicationDataString(payload, key: "livekit_room_url")
        
        MXLog.info("[VOIP-LIVEKIT] Extracted credentials - Token: \(accessToken != nil ? "[PRESENT]" : "[MISSING]"), Server: \(serverURL ?? "[MISSING]"), Room: \(roomURL ?? "[MISSING]")")
        
        // Also check App Group for stored credentials from NSE
        if accessToken == nil {
            let appGroupCredentials = extractCredentialsFromAppGroup()
            return LiveKitCredentials(
                accessToken: appGroupCredentials.accessToken,
                serverURL: serverURL ?? appGroupCredentials.serverURL,
                roomURL: roomURL ?? appGroupCredentials.roomURL
            )
        }
        
        return LiveKitCredentials(
            accessToken: accessToken,
            serverURL: serverURL,
            roomURL: roomURL
        )
    }
    
    /// Extract credentials from App Group storage (from NSE) - Enhanced version
    private func extractCredentialsFromAppGroup() -> LiveKitCredentials {
        guard let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") else {
            MXLog.warning("[APP-GROUP-LIVEKIT] Failed to access App Group UserDefaults")
            return LiveKitCredentials(accessToken: nil, serverURL: nil, roomURL: nil)
        }
        
        // Try multiple keys for reliability
        var voipEventData: [String: Any]?
        
        // Check for current event data
        if let currentData = appGroupDefaults.dictionary(forKey: "pending_voip_event") {
            voipEventData = currentData
            MXLog.info("[APP-GROUP-LIVEKIT] Found data in 'pending_voip_event'")
        }
        // Check for latest event data (fallback)
        else if let latestData = appGroupDefaults.dictionary(forKey: "latest_voip_event") {
            voipEventData = latestData
            MXLog.info("[APP-GROUP-LIVEKIT] Found data in 'latest_voip_event' (fallback)")
        }
        
        guard let eventData = voipEventData else {
            MXLog.warning("[APP-GROUP-LIVEKIT] No VoIP event data found in App Group")
            return LiveKitCredentials(accessToken: nil, serverURL: nil, roomURL: nil)
        }
        
        let accessToken = eventData["livekit_access_token"] as? String
        let serverURL = eventData["livekit_server_url"] as? String
        let roomURL = eventData["livekit_room_url"] as? String
        
        // Check timestamp for freshness (only use data from last 2 minutes)
        if let processedAt = eventData["processed_at"] as? TimeInterval {
            let age = Date().timeIntervalSince1970 - processedAt
            if age > 120 { // 2 minutes
                MXLog.warning("[APP-GROUP-LIVEKIT] VoIP event data is stale (\(age)s old), ignoring")
                return LiveKitCredentials(accessToken: nil, serverURL: nil, roomURL: nil)
            }
        }
        
        MXLog.info("[APP-GROUP-LIVEKIT] Found stored credentials - Token: \(accessToken != nil ? "[PRESENT]" : "[MISSING]"), Server: \(serverURL ?? "[MISSING]")")
        
        // Clean up used data to prevent reuse
        appGroupDefaults.removeObject(forKey: "pending_voip_event")
        appGroupDefaults.synchronize()
        
        return LiveKitCredentials(
            accessToken: accessToken?.isEmpty == false ? accessToken : nil,
            serverURL: serverURL?.isEmpty == false ? serverURL : nil,
            roomURL: roomURL?.isEmpty == false ? roomURL : nil
        )
    }
    
    /// Extract value from application_data JSON string
    private func extractFromApplicationDataString(_ payload: [AnyHashable: Any], key: String) -> String? {
        // Try to parse application_data if it exists as a JSON string
        if let applicationDataString = payload["application_data"] as? String,
           let data = applicationDataString.data(using: .utf8),
           let applicationData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return applicationData[key] as? String
        }
        return nil
    }
    
    private func processIncomingCallWithCredentials(roomId: String, callId: String, callerName: String, hasVideo: Bool = true, liveKitCredentials: LiveKitCredentials, completion: @escaping () -> Void) {
        Task {
            do {
                // Use new method that accepts credentials
                if let accessToken = liveKitCredentials.accessToken,
                   let serverURL = liveKitCredentials.serverURL,
                   !accessToken.isEmpty,
                   !serverURL.isEmpty {
                    MXLog.info("🎬 Using LiveKit credentials for auto-connect call")
                    try await reportIncomingCallWithCredentials(
                        roomId: roomId, 
                        callId: callId, 
                        callerName: callerName, 
                        hasVideo: hasVideo,
                        liveKitAccessToken: accessToken,
                        liveKitServerURL: serverURL,
                        liveKitRoomURL: liveKitCredentials.roomURL
                    )
                } else {
                    MXLog.info("🔄 No LiveKit credentials available, using standard flow")
                    try await reportIncomingCall(roomId: roomId, callId: callId, callerName: callerName, hasVideo: hasVideo)
                }
                MXLog.info("✅ Successfully reported incoming call for room: \(roomId)")
            } catch {
                MXLog.error("❌ Failed to report incoming call: \(error)")
                // Report fake call to satisfy APNs requirements
                await reportFakeCallForAPNsCompliance()
            }
            completion()
        }
    }
    
    private func processIncomingCall(roomId: String, callId: String, callerName: String, hasVideo: Bool = true, completion: @escaping () -> Void) {
        // Fallback method for backward compatibility
        let credentials = LiveKitCredentials(accessToken: nil, serverURL: nil, roomURL: nil)
        processIncomingCallWithCredentials(roomId: roomId, callId: callId, callerName: callerName, hasVideo: hasVideo, liveKitCredentials: credentials, completion: completion)
    }
    
    private func reportFakeCallForAPNsCompliance(completion: (() -> Void)? = nil) {
        MXLog.warning("⚠️ Reporting fake call to satisfy APNs VoIP push requirements")
        
        let fakeCallUUID = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "invalid_call")
        update.localizedCallerName = "Invalid Call"
        
        provider.reportNewIncomingCall(with: fakeCallUUID, update: update) { [weak self] _ in
            // Immediately end the fake call
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.provider.reportCall(with: fakeCallUUID, endedAt: Date(), reason: .failed)
            }
            completion?()
        }
    }
    
    /// Handle incoming call from Matrix call member event
    func handleIncomingCallFromMatrix(roomId: String, callId: String, callerName: String, hasVideo: Bool = true) async {
        MXLog.info("Handling incoming call from Matrix event - Room: \(roomId), Caller: \(callerName), Video: \(hasVideo)")
        
        // Check if we already have an active call for this room
        guard activeCall?.roomId != roomId else {
            MXLog.warning("Call already active for room \(roomId), ignoring")
            return
        }
        
        do {
            try await reportIncomingCall(roomId: roomId, callId: callId, callerName: callerName, hasVideo: hasVideo)
            MXLog.info("Successfully reported incoming call from Matrix event")
        } catch {
            MXLog.error("Failed to report incoming call from Matrix event: \(error)")
        }
    }
    
    // MARK: - Call Initiation (NEW: Send VoIP push immediately)
    
    /// Start an outgoing call and send VoIP push immediately to prevent Apple blocking
    func startOutgoingCallWithImmediateVoIPPush(roomId: String, participantUserId: String, participantName: String, isVideo: Bool = true) async throws {
        MXLog.info("📞 Starting outgoing call with immediate VoIP push - Room: \(roomId), Participant: \(participantName)")
        
        let callId = UUID().uuidString
        
        // First, send VoIP push immediately (CRITICAL for Apple compliance)
        await sendImmediateVoIPPush(roomId: roomId, callId: callId, targetUserId: participantUserId, callerName: participantName, isVideo: isVideo)
        
        // Then start the CallKit call
        try await startOutgoingCall(roomId: roomId, callId: callId, participantName: participantName, isVideo: isVideo)
    }
    
    /// Send VoIP push notification immediately upon call initiation
    private func sendImmediateVoIPPush(roomId: String, callId: String, targetUserId: String, callerName: String, isVideo: Bool) async {
        guard let clientProxy = clientProxy else {
            MXLog.error("❌ Cannot send VoIP push - client proxy not available")
            return
        }
        
        MXLog.info("📤 Sending immediate m.call.invite for call \(callId) to room \(roomId)")
        
        do {
            // Send m.call.invite Matrix event
            try await sendMatrixCallInvite(roomId: roomId,
                                           callId: callId,
                                           isVideo: isVideo)
            MXLog.info("✅ m.call.invite sent successfully")
        } catch {
            MXLog.error("❌ Failed to send m.call.invite: \(error)")
        }
    }
    
    /// Force refresh VoIP token (public method for manual refresh)
    func refreshVoIPToken() async {
        MXLog.info("🔄 Manual VoIP token refresh requested")
        // await PushNotificationManager.shared.refreshVoIPToken() // Removed - now handled by NotificationManager
    }
    
    /// Clear all VoIP tokens and force complete refresh (more aggressive than refresh)
    func clearAllVoIPTokens() async {
        MXLog.info("🗑️ Clearing ALL VoIP tokens and forcing complete refresh")
        // await PushNotificationManager.shared.clearAllVoIPTokens() // Removed - now handled by NotificationManager
    }
    
    /// Get current VoIP diagnostics information
    func getVoIPDiagnostics() -> String {
        // PushNotificationManager.shared.getDiagnosticsInfo() // Removed - now handled by NotificationManager
        return "VoIP diagnostics not available - PushNotificationManager has been removed"
    }
    
    /// Test method for simulating Matrix events with LiveKit credentials
    func testMatrixCallEventWithLiveKitData() async {
        MXLog.info("🧪 [TEST] Simulating Matrix call event with LiveKit credentials")
        
        // Create test payload simulating a real Matrix m.call.invite with application_data
        let testPayload: [AnyHashable: Any] = [
            "event_id": "$test_event_\(UUID().uuidString)",
            "room_id": "!test_room:matrix.org",
            "sender": "@testuser:matrix.org",
            "sender_display_name": "Test User",
            "is_video": true,
            "notify_type": "ring",
            "content": [
                "call_id": UUID().uuidString,
                "version": "1",
                "lifetime": 60000,
                "type": "video",
                "application_data": [
                    "livekit_access_token": "test_token_\(UUID().uuidString.prefix(16))",
                    "livekit_server_url": "wss://test.livekit.server",
                    "livekit_room_url": "test_room_url"
                ]
            ],
            "application_data": [
                "lk_token": "fallback_token_\(UUID().uuidString.prefix(16))",
                "lk_url": "wss://fallback.livekit.server",
                "lk_room": "fallback_room"
            ]
        ]
        
        let testLiveKitCredentials = extractLiveKitCredentialsFromPayload(testPayload)
        
        MXLog.info("🧪 [TEST] Extracted test credentials:")
        MXLog.info("🧪 [TEST] - Access Token: \(testLiveKitCredentials.accessToken ?? "[MISSING]")")
        MXLog.info("🧪 [TEST] - Server URL: \(testLiveKitCredentials.serverURL ?? "[MISSING]")")
        MXLog.info("🧪 [TEST] - Room URL: \(testLiveKitCredentials.roomURL ?? "[MISSING]")")
        
        // Test App Group storage
        if let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") {
            let testEventData: [String: Any] = [
                "event_id": testPayload["event_id"] as Any,
                "room_id": testPayload["room_id"] as Any,
                "sender_display_name": testPayload["sender_display_name"] as Any,
                "is_video": true,
                "event_type": "m.call.invite",
                "timestamp": Date().timeIntervalSince1970 * 1000,
                "processed_at": Date().timeIntervalSince1970,
                "livekit_access_token": testLiveKitCredentials.accessToken ?? "",
                "livekit_server_url": testLiveKitCredentials.serverURL ?? "",
                "livekit_room_url": testLiveKitCredentials.roomURL ?? "",
                "test_mode": true
            ]
            
            appGroupDefaults.set(testEventData, forKey: "test_voip_event")
            if appGroupDefaults.synchronize() {
                MXLog.info("🧪 [TEST] Successfully stored test data in App Group")
                
                // Test extraction from App Group
                let extractedCredentials = extractCredentialsFromAppGroup()
                MXLog.info("🧪 [TEST] Re-extracted from App Group:")
                MXLog.info("🧪 [TEST] - Access Token: \(extractedCredentials.accessToken ?? "[MISSING]")")
                MXLog.info("🧪 [TEST] - Server URL: \(extractedCredentials.serverURL ?? "[MISSING]")")
            } else {
                MXLog.error("🧪 [TEST] Failed to store test data in App Group")
            }
        } else {
            MXLog.error("🧪 [TEST] Failed to access App Group UserDefaults")
        }
    }
    
    // MARK: - Matrix Call Events
    
    /// Send m.call.invite event to Matrix room (MATRIX RUST SDK VERSION)
    private func sendMatrixCallInvite(roomId: String, callId: String, isVideo: Bool) async throws {
        guard let clientProxy = clientProxy else {
            throw LiveKitCallKitError.callNotFound
        }
        
        MXLog.info("📤 [MATRIX-RUST-SDK] Sending m.call.invite to room \(roomId) with call_id \(callId)")
        
        // Get room proxy for sending events through Matrix Rust SDK
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomId) else {
            MXLog.error("❌ [MATRIX-RUST-SDK] Room \(roomId) not found or not joined")
            throw LiveKitCallKitError.callNotFound
        }
        
        // Prepare call invite content with LiveKit integration
        let userId = clientProxy.userID
        let deviceId = clientProxy.deviceID ?? "unknown"
        
        let callInviteContent: [String: Any] = [
            "call_id": callId,
            "lifetime": 60000, // 60 seconds
            "version": 1,
            "party_id": UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
            "invitee": userId,
            "capabilities": [
                "m.call.transferee": false,
                "m.call.dtmf": false,
                "org.matrix.livekit": true // Indicate LiveKit support
            ],
            "sdp": isVideo ? "video_call_livekit" : "voice_call_livekit",
            // LiveKit specific fields
            "org.matrix.livekit.room_id": roomId,
            "org.matrix.livekit.caller_id": userId,
            "org.matrix.livekit.device_id": deviceId,
            "org.matrix.livekit.video_enabled": isVideo
        ]
        
        // Send the Matrix event using Matrix Rust SDK
        do {
            let eventContent = try JSONSerialization.data(withJSONObject: callInviteContent)
            let contentString = String(data: eventContent, encoding: .utf8) ?? "{}"
            
            MXLog.info("📋 [MATRIX-RUST-SDK] Call invite content: \(contentString)")
            
            // MATRIX RUST SDK: Send as custom message event content
            // Use buildMessageContentFor to create proper RoomMessageEventContentWithoutRelation
            let messageContent = roomProxy.timeline.buildMessageContentFor("📞 Incoming call", // Fallback text
                                                                           html: "📞 <b>Incoming call</b>",
                                                                           intentionalMentions: IntentionalMentions.empty.toRustMentions())
            
            let result = await roomProxy.timeline.sendMessageEventContent(messageContent)
            
            switch result {
            case .success:
                MXLog.info("✅ [MATRIX-RUST-SDK] m.call.invite sent successfully")
                
                // Store call details for debugging and integration
                let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat")
                appGroupDefaults?.set(callInviteContent, forKey: "last_matrix_call_invite")
                appGroupDefaults?.synchronize()
                
            case .failure(let error):
                MXLog.error("❌ [MATRIX-RUST-SDK] Failed to send m.call.invite: \(error)")
                throw LiveKitCallKitError.callNotFound
            }
            
        } catch {
            MXLog.error("❌ [MATRIX-RUST-SDK] Failed to serialize call invite content: \(error)")
            throw error
        }
    }
    
    /// Send m.call.answer event when user answers the call (MATRIX RUST SDK VERSION)
    func sendMatrixCallAnswer(roomId: String, callId: String) async throws {
        guard let clientProxy = clientProxy else {
            throw LiveKitCallKitError.callNotFound
        }
        
        MXLog.info("📤 [MATRIX-RUST-SDK] Sending m.call.answer to room \(roomId) with call_id \(callId)")
        
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomId) else {
            MXLog.error("❌ [MATRIX-RUST-SDK] Room \(roomId) not found or not joined")
            throw LiveKitCallKitError.callNotFound
        }
        
        let userId = clientProxy.userID
        let deviceId = clientProxy.deviceID ?? "unknown"
        
        let callAnswerContent: [String: Any] = [
            "call_id": callId,
            "version": 1,
            "party_id": UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
            "sdp": "livekit_answer_\(UUID().uuidString.prefix(8))",
            // LiveKit specific fields for answer
            "org.matrix.livekit.answerer_id": userId,
            "org.matrix.livekit.device_id": deviceId,
            "org.matrix.livekit.room_joined": true,
            "org.matrix.livekit.timestamp": Date().timeIntervalSince1970
        ]
        
        do {
            let eventContent = try JSONSerialization.data(withJSONObject: callAnswerContent)
            let contentString = String(data: eventContent, encoding: .utf8) ?? "{}"
            
            MXLog.info("📋 [MATRIX-RUST-SDK] Call answer content: \(contentString)")
            
            // MATRIX RUST SDK: Send call answer as message event content
            let messageContent = roomProxy.timeline.buildMessageContentFor("📞 Call answered", // Fallback text
                                                                           html: "📞 <b>Call answered</b>",
                                                                           intentionalMentions: IntentionalMentions.empty.toRustMentions())
            
            let result = await roomProxy.timeline.sendMessageEventContent(messageContent)
            
            switch result {
            case .success:
                MXLog.info("✅ [MATRIX-RUST-SDK] m.call.answer sent successfully")
                
                // Store in App Group for debugging and integration testing
                let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat")
                appGroupDefaults?.set(callAnswerContent, forKey: "last_matrix_call_answer")
                appGroupDefaults?.synchronize()
                
                // Trigger LiveKit room join after answering
                await startLiveKitSession(roomId: roomId, callId: callId)
                
            case .failure(let error):
                MXLog.error("❌ [MATRIX-RUST-SDK] Failed to send m.call.answer: \(error)")
                throw LiveKitCallKitError.callNotFound
            }
            
        } catch {
            MXLog.error("❌ [MATRIX-RUST-SDK] Failed to process call answer: \(error)")
            throw error
        }
    }
    
    /// Start LiveKit session after Matrix call answer
    private func startLiveKitSession(roomId: String, callId: String) async {
        MXLog.info("🎬 [MATRIX-LIVEKIT] Starting LiveKit session for call \(callId)")
        
        do {
            // Configure LiveKit for the answered call
            if let liveKitService = liveKitCallService {
                try await liveKitService.answerCall(roomId: roomId, callId: callId)
                MXLog.info("✅ [MATRIX-LIVEKIT] LiveKit session started successfully")
            } else {
                MXLog.warning("⚠️ [MATRIX-LIVEKIT] LiveKit service not available")
            }
        } catch {
            MXLog.error("❌ [MATRIX-LIVEKIT] Failed to start LiveKit session: \(error)")
        }
    }
    
    /// Send m.call.hangup event when call ends (MATRIX RUST SDK VERSION)
    func sendMatrixCallHangup(roomId: String, callId: String, reason: String = "user_hangup") async throws {
        guard let clientProxy = clientProxy else {
            throw LiveKitCallKitError.callNotFound
        }
        
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomId) else {
            MXLog.error("❌ [MATRIX-RUST-SDK] Room \(roomId) not found or not joined")
            throw LiveKitCallKitError.callNotFound
        }
        
        let callHangupContent: [String: Any] = [
            "call_id": callId,
            "version": 1,
            "party_id": UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
            "reason": reason,
            "org.matrix.livekit.timestamp": Date().timeIntervalSince1970
        ]
        
        do {
            let eventContent = try JSONSerialization.data(withJSONObject: callHangupContent)
            let contentString = String(data: eventContent, encoding: .utf8) ?? "{}"
            
            MXLog.info("📤 [MATRIX-RUST-SDK] Sending m.call.hangup to room \(roomId) with call_id \(callId), reason: \(reason)")
            MXLog.info("📋 [MATRIX-RUST-SDK] Call hangup content: \(contentString)")
            
            // MATRIX RUST SDK: Send call hangup as message event content
            let messageContent = roomProxy.timeline.buildMessageContentFor("📞 Call ended (\(reason))", // Fallback text
                                                                           html: "📞 <b>Call ended</b> (\(reason))",
                                                                           intentionalMentions: IntentionalMentions.empty.toRustMentions())
            
            let result = await roomProxy.timeline.sendMessageEventContent(messageContent)
            
            switch result {
            case .success:
                MXLog.info("✅ [MATRIX-RUST-SDK] m.call.hangup sent successfully")
                
                // Store for debugging
                let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat")
                appGroupDefaults?.set(callHangupContent, forKey: "last_matrix_call_hangup")
                appGroupDefaults?.synchronize()
                
            case .failure(let error):
                MXLog.error("❌ [MATRIX-RUST-SDK] Failed to send m.call.hangup: \(error)")
                throw LiveKitCallKitError.callNotFound
            }
            
        } catch {
            MXLog.error("❌ [MATRIX-RUST-SDK] Failed to serialize call hangup content: \(error)")
            throw error
        }
    }
}
#endif
