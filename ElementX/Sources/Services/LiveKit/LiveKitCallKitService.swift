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
    
    private let provider: CXProvider
    private let callController: CXCallController
    private let pushRegistry: PKPushRegistry
    private var liveKitCallService: LiveKitCallService?
    private var clientProxy: ClientProxyProtocol?
    
    @Published var activeCall: LiveKitCall?
    @Published var isCallActive = false
    
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
        pushRegistry = PKPushRegistry(queue: nil)
        
        super.init()
        
        provider.setDelegate(self, queue: nil)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        
        MXLog.info("LiveKitCallKitService initialized")
    }
    
    // MARK: - Public Methods
    
    func setLiveKitCallService(_ service: LiveKitCallService) {
        liveKitCallService = service
    }
    
    func configureWithClientProxy(_ clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
        MXLog.info("LiveKitCallKitService configured with client proxy")
        
        // Immediately register VoIP push token if available
        if let existingToken = pushRegistry.pushToken(for: .voIP) {
            MXLog.info("Found existing VoIP push token, registering immediately")
            Task {
                await registerVoIPPushToken(existingToken)
            }
        }
    }
    
    /// Report an incoming call to CallKit
    func reportIncomingCall(roomId: String, callId: String, callerName: String) async throws {
        let callUUID = UUID()
        
        MXLog.info("Reporting incoming call: \(callId) from \(callerName)")
        
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: roomId)
        update.localizedCallerName = callerName
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        
        let call = LiveKitCall(id: callId,
                               roomId: roomId,
                               callUUID: callUUID,
                               isIncoming: true,
                               callerName: callerName)
        
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
    func startOutgoingCall(roomId: String, callId: String, participantName: String) async throws {
        let callUUID = UUID()
        
        MXLog.info("Starting outgoing call: \(callId) to \(participantName)")
        
        let handle = CXHandle(type: .generic, value: roomId)
        let startCallAction = CXStartCallAction(call: callUUID, handle: handle)
        startCallAction.isVideo = true
        startCallAction.contactIdentifier = participantName
        
        let call = LiveKitCall(id: callId,
                               roomId: roomId,
                               callUUID: callUUID,
                               isIncoming: false,
                               callerName: participantName)
        
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
        MXLog.info("CallKit: Starting call \(action.callUUID)")
        
        guard let call = activeCalls[action.callUUID] else {
            MXLog.error("Call not found for UUID: \(action.callUUID)")
            action.fail()
            return
        }
        
        Task {
            do {
                try configureAudioSession()
                
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
                
                // Answer the LiveKit call
                try await liveKitCallService?.answerCall(roomId: call.roomId, callId: call.id)
                
                activeCall = call
                isCallActive = true
                
                action.fulfill()
                MXLog.info("CallKit: Successfully answered call")
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
    
    init(id: String, roomId: String, callUUID: UUID, isIncoming: Bool, callerName: String) {
        self.id = id
        self.roomId = roomId
        self.callUUID = callUUID
        self.isIncoming = isIncoming
        self.callerName = callerName
        startTime = Date()
    }
}

// MARK: - PKPushRegistryDelegate

extension LiveKitCallKitService: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        MXLog.info("LiveKit VoIP push credentials updated")
        
        // Register VoIP push token with Matrix
        Task {
            await registerVoIPPushToken(pushCredentials.token)
        }
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        MXLog.info("LiveKit received incoming VoIP push notification")
        
        guard let roomID = payload.dictionaryPayload[ElementCallServiceNotificationKey.roomID.rawValue] as? String else {
            MXLog.error("Missing room identifier for incoming LiveKit call: \(payload)")
            completion()
            return
        }
        
        guard activeCall?.roomId != roomID else {
            MXLog.warning("LiveKit call already ongoing for room \(roomID), ignoring incoming push")
            completion()
            return
        }
        
        let roomDisplayName = payload.dictionaryPayload[ElementCallServiceNotificationKey.roomDisplayName.rawValue] as? String ?? "Unknown"
        let callId = UUID().uuidString
        
        Task {
            do {
                try await reportIncomingCall(roomId: roomID, callId: callId, callerName: roomDisplayName)
                MXLog.info("Successfully reported incoming LiveKit call for room: \(roomID)")
            } catch {
                MXLog.error("Failed to report incoming LiveKit call: \(error)")
            }
            completion()
        }
    }
    
    /// Handle incoming call from Matrix call member event
    func handleIncomingCallFromMatrix(roomId: String, callId: String, callerName: String) async {
        MXLog.info("Handling incoming call from Matrix event - Room: \(roomId), Caller: \(callerName)")
        
        // Check if we already have an active call for this room
        guard activeCall?.roomId != roomId else {
            MXLog.warning("Call already active for room \(roomId), ignoring")
            return
        }
        
        do {
            try await reportIncomingCall(roomId: roomId, callId: callId, callerName: callerName)
            MXLog.info("Successfully reported incoming call from Matrix event")
        } catch {
            MXLog.error("Failed to report incoming call from Matrix event: \(error)")
        }
    }
    
    // MARK: - VoIP Push Token Registration
    
    private func registerVoIPPushToken(_ token: Data) async {
        guard let clientProxy = clientProxy else {
            MXLog.warning("No client proxy available for VoIP push token registration")
            return
        }
        
        MXLog.info("Registering VoIP push token with Matrix")
        
        do {
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                          alert: APSAlert(locKey: "Incoming Call",
                                                                          locArgs: [])),
                                             pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)
            
            let configuration = try await PusherConfiguration(identifiers: .init(pushkey: token.base64EncodedString(),
                                                                                 appId: ServiceLocator.shared.settings.voipAppId),
                                                              kind: .http(data: .init(url: ServiceLocator.shared.settings.pushGatewayNotifyEndpoint.absoluteString,
                                                                                      format: .eventIdOnly,
                                                                                      defaultPayload: defaultPayload.toJsonString())),
                                                              appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS VoIP)",
                                                              deviceDisplayName: UIDevice.current.name,
                                                              profileTag: "voip_\(UUID().uuidString.prefix(8))",
                                                              lang: Bundle.app.preferredLocalizations.first ?? "en")
            
            try await clientProxy.setPusher(with: configuration)
            MXLog.info("VoIP push token registered successfully with Matrix")
        } catch {
            MXLog.error("Failed to register VoIP push token with Matrix: \(error)")
        }
    }
}
#endif
