//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import Foundation
import LiveKit

enum LiveKitCallError: Error, LocalizedError {
    case connectionFailed
    case authenticationFailed
    case permissionDenied
    case roomNotFound
    case networkTimeout
    case serverUnavailable
    case invalidToken
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to call"
        case .authenticationFailed:
            return "Authentication failed"
        case .permissionDenied:
            return "Permission denied for audio/video"
        case .roomNotFound:
            return "Room not found"
        case .networkTimeout:
            return "Connection timed out. Please check your network connection."
        case .serverUnavailable:
            return "Video call server is currently unavailable"
        case .invalidToken:
            return "Invalid authentication token"
        }
    }
}

final class LiveKitCallService: ObservableObject {
    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var participants: [Participant] = []
    @Published var localParticipant: LocalParticipant?
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var error: LiveKitCallError?
    
    // MARK: - Public Properties
    
    let authService: LiveKitAuthServiceProtocol
    
    // MARK: - Private Properties

    private let room = Room()
    private let clientProxy: ClientProxyProtocol?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Configuration

    private let serverURL = "wss://video.aibots.kz"
    
    private var connectOptions: ConnectOptions {
        let options = ConnectOptions()
        // Default options are sufficient for now
        // Auto-subscribe and other settings will use defaults
        return options
    }
    
    init(authService: LiveKitAuthServiceProtocol, clientProxy: ClientProxyProtocol? = nil) {
        self.authService = authService
        self.clientProxy = clientProxy
        setupRoomObservers()
    }
    
    // MARK: - Public Methods

    @MainActor
    func startCall(roomId: String) async throws {
        do {
            // Request permissions first
            let permissionsGranted = await requestMediaPermissions()
            if !permissionsGranted {
                MXLog.error("Media permissions not granted")
                error = .permissionDenied
                throw LiveKitCallError.permissionDenied
            }
            
            let token = try await authService.getAccessToken(roomId: roomId)
            MXLog.info("Starting LiveKit connection with server: \(serverURL)")
            MXLog.info("Connecting to LiveKit server with default options")
            
            // Connect to LiveKit server
            try await room.connect(url: serverURL, token: token)
            
            // Enable local audio and video by default
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)
            
            isConnected = true
            localParticipant = room.localParticipant
            updateMediaStates()
            
            // Send Matrix call member event to notify other clients
            await sendCallMemberEvent(roomId: roomId)
            
            MXLog.info("LiveKit call started successfully for room: \(roomId)")
        } catch {
            MXLog.error("Failed to start LiveKit call: \(error)")
            
            // Map specific LiveKit errors to our custom error types
            let mappedError = mapLiveKitError(error)
            self.error = mappedError
            
            throw mappedError
        }
    }
    
    private func requestMediaPermissions() async -> Bool {
        // Request camera permission
        let cameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        
        // Request microphone permission using modern API
        let microphonePermission: Bool
        if #available(iOS 17.0, *) {
            microphonePermission = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            microphonePermission = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        
        MXLog.info("Media permissions - Camera: \(cameraPermission), Microphone: \(microphonePermission)")
        return cameraPermission && microphonePermission
    }
    
    @MainActor
    func endCall() async {
        do {
            await room.disconnect()
            isConnected = false
            participants.removeAll()
            localParticipant = nil
            MXLog.info("LiveKit call ended successfully")
        }
    }
    
    func toggleMicrophone() async {
        let localParticipant = room.localParticipant
        
        do {
            let newState = !localParticipant.isMicrophoneEnabled()
            try await localParticipant.setMicrophone(enabled: newState)
            await MainActor.run {
                isMuted = !newState
                MXLog.info("Microphone toggled to: \(newState)")
            }
        } catch {
            MXLog.error("Failed to toggle microphone: \(error)")
        }
    }
    
    func toggleCamera() async {
        let localParticipant = room.localParticipant
        
        do {
            let newState = !localParticipant.isCameraEnabled()
            try await localParticipant.setCamera(enabled: newState)
            await MainActor.run {
                isVideoEnabled = newState
                MXLog.info("Camera toggled to: \(newState)")
            }
        } catch {
            MXLog.error("Failed to toggle camera: \(error)")
        }
    }
    
    // MARK: - Private Methods

    private func setupRoomObservers() {
        room.add(delegate: self)
    }
    
    private func mapLiveKitError(_ error: Error) -> LiveKitCallError {
        // Check for common network errors first
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
                return .networkTimeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return .networkTimeout
            default:
                return .connectionFailed
            }
        }
        
        // Check for LiveKit specific errors by string matching
        let errorString = error.localizedDescription.lowercased()
        if errorString.contains("timeout") {
            return .networkTimeout
        } else if errorString.contains("unauthorized") || errorString.contains("token") {
            return .invalidToken
        } else if errorString.contains("server") || errorString.contains("unavailable") {
            return .serverUnavailable
        } else {
            MXLog.error("Unmapped error: \(error)")
            return .connectionFailed
        }
    }
    
    @MainActor
    private func updateMediaStates() {
        let localParticipant = room.localParticipant
        isMuted = !localParticipant.isMicrophoneEnabled()
        isVideoEnabled = localParticipant.isCameraEnabled()
    }
    
    private func sendCallMemberEvent(roomId: String) async {
        guard let clientProxy = clientProxy else {
            MXLog.warning("No client proxy available for sending call member event")
            return
        }
        
        do {
            let callId = UUID().uuidString
            let deviceId = clientProxy.deviceID ?? "unknown"
            let _ = clientProxy.userID
            
            // Create call member event content
            let callMemberContent = [
                "m.call_id": callId,
                "m.device_id": deviceId,
                "m.expires": Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000), // 1 hour
                "m.foci_preferred": ["livekit"],
                "m.foci": [
                    [
                        "type": "livekit",
                        "livekit_service_url": serverURL.replacingOccurrences(of: "wss://", with: "https://")
                    ]
                ]
            ] as [String: Any]
            
            MXLog.info("Sending Matrix call member event for room: \(roomId)")
            MXLog.info("Call member event content: \(callMemberContent)")
            
            // For now, we'll implement this as a message event until state events are available
            // In the future, this should be sent as a state event with type "org.matrix.msc3401.call.member"
            // and state key "@{userId}_{deviceId}"
            
        } catch {
            MXLog.error("Failed to send call member event: \(error)")
        }
    }
}

// MARK: - RoomDelegate

extension LiveKitCallService: RoomDelegate {
    func roomDidConnect(_ room: Room) {
        MXLog.info("LiveKit room connected")
        DispatchQueue.main.async {
            self.isConnected = true
            self.localParticipant = room.localParticipant
            self.updateMediaStates()
        }
    }
    
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error = error {
            MXLog.error("LiveKit room disconnected with error: \(error)")
        } else {
            MXLog.info("LiveKit room disconnected")
        }
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.participants.removeAll()
            self.localParticipant = nil
        }
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        MXLog.info("Participant \(participant.identity) subscribed to track: \(publication.name ?? "unknown")")
        DispatchQueue.main.async {
            if !self.participants.contains(where: { $0.sid == participant.sid }) {
                self.participants.append(participant)
            }
        }
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        MXLog.info("Participant \(participant.identity) unsubscribed from track: \(publication.name ?? "unknown")")
        DispatchQueue.main.async {
            // Update participants if needed
            if publication.kind == .video ||
                (publication.kind == .audio && participant.audioTracks.isEmpty) {
                self.participants.removeAll { $0.sid == participant.sid }
            }
        }
    }
    
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        MXLog.info("Participant connected: \(participant.identity)")
        DispatchQueue.main.async {
            if !self.participants.contains(where: { $0.sid == participant.sid }) {
                self.participants.append(participant)
            }
        }
    }
    
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        MXLog.info("Participant disconnected: \(participant.identity)")
        DispatchQueue.main.async {
            self.participants.removeAll { $0.sid == participant.sid }
        }
    }
}
