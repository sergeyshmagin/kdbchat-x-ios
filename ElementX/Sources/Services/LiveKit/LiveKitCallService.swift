//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import AVFoundation
import Combine
import Foundation
import LiveKit
import MatrixRustSDK
import ReplayKit

enum LiveKitCallError: Error, LocalizedError {
    case connectionFailed
    case authenticationFailed
    case permissionDenied
    case roomNotFound
    case networkTimeout
    case serverUnavailable
    case invalidToken
    case callTimeout
    case noAnswer
    case declined
    
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
        case .callTimeout:
            return "Call timed out"
        case .noAnswer:
            return "Абонент не отвечает"
        case .declined:
            return "Звонок отклонен"
        }
    }
}

enum CallState: String, CaseIterable {
    case idle = "idle"
    case ringing = "ringing"
    case connecting = "connecting"
    case active = "active"
    case ended = "ended"
    case noAnswer = "noAnswer"
    case declined = "declined"
    case timeout = "timeout"
}

final class LiveKitCallService: ObservableObject {
    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var participants: [Participant] = []
    @Published var localParticipant: LocalParticipant?
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var error: LiveKitCallError?
    @Published var callState: CallState = .idle
    @Published var isCallAnswered = false
    
    // MARK: - Public Properties
    
    let authService: LiveKitAuthServiceProtocol
    
    // MARK: - Private Properties

    private let room = LiveKit.Room()
    private let clientProxy: ClientProxyProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var callMemberEventListener: TaskHandle?
    private var callTimeoutTimer: Timer?
    private var currentCallId: String?
    private var isOutgoingCall = false
    
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
        setupCallMemberEventListener()
    }
    
    // MARK: - Public Methods

    @MainActor
    func startCall(roomId: String) async throws {
        do {
            // Set call state and generate call ID
            currentCallId = UUID().uuidString
            isOutgoingCall = true
            await MainActor.run {
                callState = .ringing
                isCallAnswered = false
            }
            
            // Request permissions first
            let permissionsGranted = await requestMediaPermissions()
            if !permissionsGranted {
                MXLog.error("Media permissions not granted")
                error = .permissionDenied
                throw LiveKitCallError.permissionDenied
            }
            
            // TODO: Send Matrix call member event to notify other clients
            MXLog.info("Call notification - would send Matrix call event here")
            
            // Start timeout timer for outgoing calls
            await MainActor.run {
                startCallTimeoutTimer()
            }
            
            let token = try await authService.getAccessToken(roomId: roomId)
            MXLog.info("Starting LiveKit connection with server: \(serverURL)")
            MXLog.info("Connecting to LiveKit server with default options")
            
            await MainActor.run {
                callState = .connecting
            }
            
            // Connect to LiveKit server
            try await room.connect(url: serverURL, token: token)
            
            // Enable local audio and video by default
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)
            
            await MainActor.run {
                isConnected = true
                localParticipant = room.localParticipant
                callState = .active
                isCallAnswered = true
            }
            await updateMediaStates()
            
            // Cancel timeout timer since call is now active
            await MainActor.run {
                cancelCallTimeoutTimer()
            }
            
            MXLog.info("LiveKit call started successfully for room: \(roomId)")
        } catch {
            MXLog.error("Failed to start LiveKit call: \(error)")
            
            await MainActor.run {
                callState = .ended
                cancelCallTimeoutTimer()
            }
            
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
            await MainActor.run {
                // Cancel any active timeout timer
                cancelCallTimeoutTimer()
                
                // Update call state
                if callState != .noAnswer && callState != .declined {
                    callState = .ended
                }
            }
            
            await room.disconnect()
            await MainActor.run {
                isConnected = false
                participants.removeAll()
                localParticipant = nil
                currentCallId = nil
                isOutgoingCall = false
                isCallAnswered = false
            }
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
    
    func startScreenShare() async throws {
        let localParticipant = room.localParticipant
        
        do {
            // Start screen recording using iOS native API
            #if !targetEnvironment(simulator)
            let screenRecorder = RPScreenRecorder.shared()
            
            // Check if screen recording is available
            guard screenRecorder.isAvailable else {
                throw LiveKitCallError.permissionDenied
            }
            
            // Start screen recording
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                screenRecorder.startCapture(handler: { (sampleBuffer, type, error) in
                    if let error = error {
                        continuation.resume(throwing: error)
                    }
                }, completionHandler: { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
            #endif
            
            // Enable screen share in LiveKit
            _ = try await localParticipant.setScreenShare(enabled: true)
            MXLog.info("Screen sharing started successfully")
        } catch {
            MXLog.error("Failed to start screen sharing: \(error)")
            throw error
        }
    }
    
    func stopScreenShare() async {
        let localParticipant = room.localParticipant
        
        do {
            // Stop screen recording
            #if !targetEnvironment(simulator)
            let screenRecorder = RPScreenRecorder.shared()
            if screenRecorder.isRecording {
                try await screenRecorder.stopCapture()
            }
            #endif
            
            // Disable screen share in LiveKit
            try await localParticipant.setScreenShare(enabled: false)
            MXLog.info("Screen sharing stopped")
        } catch {
            MXLog.error("Failed to stop screen sharing: \(error)")
        }
    }
    
    func switchCamera() async {
        do {
            guard let videoTrack = room.localParticipant.videoTracks.first?.track as? LocalVideoTrack,
                  let cameraCapturer = videoTrack.capturer as? CameraCapturer else {
                MXLog.warning("Cannot switch camera: video track or capturer not available")
                return
            }
            
            MXLog.info("Switching camera position...")
            
            // Switch camera position using LiveKit API
            try await cameraCapturer.switchCameraPosition()
            
            MXLog.info("Camera switched successfully")
        } catch {
            MXLog.error("Failed to switch camera: \(error)")
        }
    }
    
    func setSpeakerEnabled(_ enabled: Bool) async {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            
            if enabled {
                try audioSession.overrideOutputAudioPort(.speaker)
            } else {
                try audioSession.overrideOutputAudioPort(.none)
            }
            
            MXLog.info("Speaker mode set to: \(enabled)")
        } catch {
            MXLog.error("Failed to configure speaker mode: \(error)")
        }
    }
    
    // MARK: - Private Methods

    private func setupRoomObservers() {
        room.add(delegate: self)
    }
    
    private func setupCallMemberEventListener() {
        guard clientProxy != nil else {
            MXLog.warning("No client proxy available for call member event listener")
            return
        }
        
        // Listen for call member events across all rooms
        // This will be used to handle incoming calls
        MXLog.info("Setting up call member event listener")
        
        // Note: This is a simplified implementation
        // In a real implementation, you would need to listen to room events
        // and filter for org.matrix.msc3401.call.member events
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
    private func updateMediaStates() async {
        let localParticipant = room.localParticipant
        isMuted = !localParticipant.isMicrophoneEnabled()
        isVideoEnabled = localParticipant.isCameraEnabled()
    }
    
    // TODO: Implement proper Matrix call member event sending
    private func sendCallMemberEvent(roomId: String) async {
        MXLog.info("TODO: Send Matrix call member event for room: \(roomId)")
    }
    
    // MARK: - CallKit Integration Methods
    
    /// Start a call with specific call ID (for CallKit integration)
    @MainActor
    func startCall(roomId: String, callId: String) async throws {
        MXLog.info("Starting LiveKit call with callId: \(callId)")
        try await startCall(roomId: roomId)
    }
    
    /// Answer an incoming call (for CallKit integration)
    @MainActor
    func answerCall(roomId: String, callId: String) async throws {
        MXLog.info("Answering LiveKit call with callId: \(callId)")
        
        // Set up for incoming call
        currentCallId = callId
        isOutgoingCall = false
        callState = .connecting
        isCallAnswered = true
        
        // Start the call connection
        try await connectToCall(roomId: roomId)
    }
    
    /// Connect to an existing call (used for both incoming and outgoing)
    private func connectToCall(roomId: String) async throws {
        do {
            let token = try await authService.getAccessToken(roomId: roomId)
            MXLog.info("Connecting to LiveKit server: \(serverURL)")
            
            // Connect to LiveKit server
            try await room.connect(url: serverURL, token: token)
            
            // Enable local audio and video by default
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)
            
            await MainActor.run {
                isConnected = true
                localParticipant = room.localParticipant
                callState = .active
            }
            await updateMediaStates()
            
            MXLog.info("Successfully connected to LiveKit call")
        } catch {
            MXLog.error("Failed to connect to LiveKit call: \(error)")
            
            await MainActor.run {
                callState = .ended
            }
            
            let mappedError = mapLiveKitError(error)
            self.error = mappedError
            throw mappedError
        }
    }
    
    /// Set mute state (for CallKit integration)
    func setMuted(_ muted: Bool) async {
        let localParticipant = room.localParticipant
        
        do {
            try await localParticipant.setMicrophone(enabled: !muted)
            await MainActor.run {
                isMuted = muted
                MXLog.info("Microphone set to muted: \(muted)")
            }
        } catch {
            MXLog.error("Failed to set microphone muted state: \(error)")
        }
    }
    
    /// Configure audio session (for CallKit integration)
    func configureAudio() async {
        // This method can be called by CallKit when audio session is activated
        MXLog.info("Configuring audio for CallKit integration")
    }
    
    // MARK: - Call Timeout Management
    
    @MainActor
    private func startCallTimeoutTimer() {
        // Cancel any existing timer
        cancelCallTimeoutTimer()
        
        MXLog.info("Starting call timeout timer (30 seconds)")
        callTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.handleCallTimeout()
            }
        }
    }
    
    @MainActor
    private func cancelCallTimeoutTimer() {
        callTimeoutTimer?.invalidate()
        callTimeoutTimer = nil
        MXLog.info("Call timeout timer cancelled")
    }
    
    @MainActor
    private func handleCallTimeout() async {
        guard !isCallAnswered && callState == .ringing else {
            return // Call was already answered or ended
        }
        
        MXLog.warning("Call timeout reached - ending call")
        callState = .noAnswer
        error = .noAnswer
        
        // End the call
        await endCall()
    }
}

// MARK: - RoomDelegate

extension LiveKitCallService: RoomDelegate {
    func roomDidConnect(_ room: LiveKit.Room) {
        MXLog.info("LiveKit room connected")
        DispatchQueue.main.async {
            self.isConnected = true
            self.localParticipant = room.localParticipant
            Task {
                await self.updateMediaStates()
            }
        }
    }
    
    func room(_ room: LiveKit.Room, didDisconnectWithError error: LiveKitError?) {
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
    
    func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        MXLog.info("Participant \(String(describing: participant.identity)) subscribed to track: \(publication.name)")
        DispatchQueue.main.async {
            if !self.participants.contains(where: { $0.sid == participant.sid }) {
                self.participants.append(participant)
            }
        }
    }
    
    func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        MXLog.info("Participant \(String(describing: participant.identity)) unsubscribed from track: \(publication.name)")
        DispatchQueue.main.async {
            // Update participants if needed
            if publication.kind == .video ||
                (publication.kind == .audio && participant.audioTracks.isEmpty) {
                self.participants.removeAll { $0.sid == participant.sid }
            }
        }
    }
    
    func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
        MXLog.info("Participant connected: \(String(describing: participant.identity))")
        DispatchQueue.main.async {
            if !self.participants.contains(where: { $0.sid == participant.sid }) {
                self.participants.append(participant)
            }
        }
    }
    
    func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
        MXLog.info("Participant disconnected: \(String(describing: participant.identity))")
        DispatchQueue.main.async {
            self.participants.removeAll { $0.sid == participant.sid }
        }
    }
}
#endif
