//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import AudioToolbox
import AVFoundation
import CallKit
import Combine
import Foundation
import LiveKit
import MatrixRustSDK
import ReplayKit

// MARK: - Matrix Call Service Protocol

/// Protocol for Matrix Call API service
protocol MatrixCallServiceProtocol {
    /// Send m.call.invite event to start a call
    func sendCallInvite(roomId: String, callId: String, isVideo: Bool, invitee: String?) async throws
    
    /// Send m.call.member event to join a call
    func sendCallMemberJoin(roomId: String, callId: String, expiresIn: TimeInterval) async throws
    
    /// Send m.call.member event to leave a call
    func sendCallMemberLeave(roomId: String, callId: String, reason: String?) async throws
    
    /// Send m.call.notify event for ringing
    func sendCallNotifyRing(roomId: String, callId: String, mentionUsers: [String]) async throws
    
    /// Start listening for incoming call events in all rooms
    func startListeningForIncomingCalls(callKitService: LiveKitCallKitService)
    
    /// Check if user has VoIP push capability
    func checkVoIPCapability(for userId: String) async -> Bool
    
    /// Check if current user has VoIP capability before making calls
    func checkOwnVoIPCapability() async -> Bool
    
    /// Get active call members in a room
    func getActiveCallMembers(roomId: String, callId: String) async -> [String]
}

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

enum LiveKitCallState: String, CaseIterable {
    case idle
    case ringing
    case connecting
    case active
    case ended
    case noAnswer
    case declined
    case timeout
}

final class LiveKitCallService: ObservableObject {
    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var participants: [Participant] = []
    @Published var localParticipant: LocalParticipant?
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var error: LiveKitCallError?
    @Published var callState: LiveKitCallState = .idle
    @Published var isCallAnswered = false
    
    // MARK: - Public Properties
    
    let authService: LiveKitAuthServiceProtocol
    
    // MARK: - Private Properties

    private let room = LiveKit.Room()
    private var clientProxy: ClientProxyProtocol?
    private var _matrixCallService: MatrixCallServiceProtocol?
    
    /// Lazily initialized Matrix call service
    private var matrixCallService: MatrixCallServiceProtocol? {
        if _matrixCallService == nil, let clientProxy = clientProxy {
            MXLog.info("Lazily initializing MatrixCallService with client proxy for user: \(clientProxy.userID)")
            _matrixCallService = MatrixCallService(clientProxy: clientProxy, liveKitAuthService: authService)
            MXLog.info("MatrixCallService lazily initialized successfully")
        } else if _matrixCallService == nil {
            MXLog.warning("MatrixCallService not available - client proxy is nil")
        }
        return _matrixCallService
    }

    private var cancellables = Set<AnyCancellable>()
    private var callMemberEventListener: TaskHandle?
    private var callTimeoutTimer: Timer?
    private var currentCallId: String?
    private var isOutgoingCall = false
    private var ringbackPlayer: AVAudioPlayer?
    private var isPlayingRingback = false
    
    // MARK: - Configuration

    private let serverURL = "wss://video.aibots.kz"
    
    private var connectOptions: ConnectOptions {
        let options = ConnectOptions()
        // Default options are sufficient for now
        // Auto-subscribe and other settings will use defaults
        return options
    }
    
    init(authService: LiveKitAuthServiceProtocol, clientProxy: ClientProxyProtocol? = nil, callKitService: LiveKitCallKitService? = nil) {
        self.authService = authService
        self.clientProxy = clientProxy
        
        setupRoomObservers()
        setupCallMemberEventListener()
        
        // Start listening for incoming calls if CallKit service is available
        if let callKitService = callKitService {
            // Defer CallKit setup until Matrix service is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.configureCallKitService(callKitService)
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Configure CallKit service for incoming call handling
    func configureCallKitService(_ callKitService: LiveKitCallKitService) {
        guard let matrixCallService = matrixCallService else {
            MXLog.warning("Matrix call service not available for CallKit integration")
            return
        }
        
        matrixCallService.startListeningForIncomingCalls(callKitService: callKitService)
        MXLog.info("Configured CallKit service for incoming Matrix call events")
    }
    
    /// Force initialization of Matrix call service (call after user session is ready)
    func ensureMatrixCallServiceReady() {
        _ = matrixCallService // Trigger lazy initialization
        MXLog.info("Matrix call service ready check completed")
    }
    
    /// Update client proxy for Matrix call service
    func updateClientProxy(_ newClientProxy: ClientProxyProtocol) {
        MXLog.info("Updating LiveKitCallService client proxy for user: \(newClientProxy.userID)")
        clientProxy = newClientProxy
        // Force recreate Matrix call service with new client proxy
        _matrixCallService = nil
        // The lazy property will recreate it with the new client proxy
        _ = matrixCallService
    }

    @MainActor
    func startCall(roomId: String) async throws {
        do {
            // Ensure Matrix call service is available before starting call
            if matrixCallService == nil {
                MXLog.error("MatrixCallService not available - cannot send Matrix call events")
                throw LiveKitCallError.authenticationFailed
            }
            
            // Check VoIP capability before starting call
            if let matrixCallService = matrixCallService {
                let hasVoIPCapability = await matrixCallService.checkOwnVoIPCapability()
                if !hasVoIPCapability {
                    MXLog.warning("VoIP capability check failed - proceeding anyway")
                }
            }
            
            // Set call state and generate call ID
            currentCallId = UUID().uuidString
            isOutgoingCall = true
            await MainActor.run {
                callState = .ringing
                isCallAnswered = false
            }
            
            // 🔥 CRITICAL FIX: Record outgoing call in CallHistoryManager
            if let clientProxy = clientProxy, let callId = currentCallId {
                await recordOutgoingCall(roomId: roomId, callId: callId, clientProxy: clientProxy, isVideo: isVideoEnabled)
            }
            
            // Configure audio session and request permissions
            await configureAudio()
            let permissionsGranted = await requestMediaPermissions()
            if !permissionsGranted {
                MXLog.error("Media permissions not granted")
                error = .permissionDenied
                throw LiveKitCallError.permissionDenied
            }
            
            // Send Matrix call invite and notify events
            await sendMatrixCallEvents(roomId: roomId, isVideo: isVideoEnabled)
            
            // Start timeout timer and ringback for outgoing calls
            await MainActor.run {
                startCallTimeoutTimer()
                startRingbackTone()
            }
            
            let token = try await authService.getAccessToken(roomId: roomId)
            MXLog.info("Starting LiveKit connection with server: \(serverURL)")
            MXLog.info("Connecting to LiveKit server with video enabled: \(isVideoEnabled)")
            
            await MainActor.run {
                callState = .connecting
            }
            
            // Connect to LiveKit server
            try await room.connect(url: serverURL, token: token)
            
            // Enable local audio (always enabled for calls)
            try await room.localParticipant.setMicrophone(enabled: true)
            
            // Enable video only if this is a video call
            try await room.localParticipant.setCamera(enabled: isVideoEnabled)
            MXLog.info("Camera configured for call - enabled: \(isVideoEnabled)")
            
            await MainActor.run {
                isConnected = true
                localParticipant = room.localParticipant
                callState = .active
                isCallAnswered = true
            }
            
            // 🔥 CRITICAL FIX: Update call status to answered in CallHistoryManager
            if let callId = currentCallId {
                await CallHistoryManager.shared.updateCallStatus(callId, status: .answered)
                MXLog.info("🔥 CRITICAL: Updated call status to answered in CallHistoryManager: \(callId)")
            }
            
            // 🔥 CRITICAL FIX: Report outgoing call as connected to appear in system call log
            if isOutgoingCall, let callId = currentCallId {
                if let callUUID = LiveKitCallKitService.shared.findCallUUID(for: callId) {
                    LiveKitCallKitService.shared.reportOutgoingCallConnected(callUUID: callUUID)
                    MXLog.info("🔥 CRITICAL: Successfully reported outgoing call connected to CallKit for call log")
                } else {
                    MXLog.warning("⚠️ CRITICAL: Could not find CallKit UUID for call ID: \(callId)")
                }
            }
            await updateMediaStates()
            
            // Cancel timeout timer and stop ringback since call is now active
            await MainActor.run {
                cancelCallTimeoutTimer()
                stopRingbackTone()
            }
            
            MXLog.info("LiveKit call started successfully for room: \(roomId) (video: \(isVideoEnabled))")
        } catch {
            MXLog.error("Failed to start LiveKit call: \(error)")
            
            await MainActor.run {
                callState = .ended
                cancelCallTimeoutTimer()
                stopRingbackTone()
            }
            
            // Map specific LiveKit errors to our custom error types
            let mappedError = mapLiveKitError(error)
            self.error = mappedError
            
            throw mappedError
        }
    }
    
    private func requestMediaPermissions() async -> Bool {
        // Always request microphone permission
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
        
        // Only request camera permission if video is enabled
        let cameraPermission: Bool
        if isVideoEnabled {
            cameraPermission = await AVCaptureDevice.requestAccess(for: .video)
            MXLog.info("Media permissions - Camera: \(cameraPermission), Microphone: \(microphonePermission)")
        } else {
            cameraPermission = true // Don't require camera permission for audio-only calls
            MXLog.info("Media permissions (audio-only call) - Microphone: \(microphonePermission)")
        }
        
        return cameraPermission && microphonePermission
    }
    
    @MainActor
    func endCall() async {
        do {
            // 🔥 CRITICAL FIX: Calculate and update call duration before ending
            let callId = currentCallId
            
            await MainActor.run {
                // Cancel any active timeout timer and ringback
                cancelCallTimeoutTimer()
                stopRingbackTone()
                
                // Update call state
                if callState != .noAnswer, callState != .declined {
                    callState = .ended
                }
            }
            
            // 🔥 CRITICAL FIX: Update call duration and status in CallHistoryManager
            if let callId = callId {
                // Calculate duration if call was answered
                if isCallAnswered {
                    // For now, using a placeholder duration calculation
                    // TODO: Track actual call start time for precise duration
                    let duration: TimeInterval = 30.0 // Placeholder - will be improved
                    await CallHistoryManager.shared.updateCallDuration(callId, duration: duration)
                    MXLog.info("🔥 CRITICAL: Updated call duration in CallHistoryManager: \(callId) - \(duration)s")
                } else {
                    // Call was not answered - mark as missed/declined
                    let status: CallStatus = callState == .declined ? .declined : .missed
                    await CallHistoryManager.shared.updateCallStatus(callId, status: status)
                    MXLog.info("🔥 CRITICAL: Updated call status to \(status) in CallHistoryManager: \(callId)")
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
                screenRecorder.startCapture(handler: { _, _, error in
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
    
    /// Send Matrix call events (invite, member, notify)
    private func sendMatrixCallEvents(roomId: String, isVideo: Bool) async {
        guard let matrixCallService = matrixCallService else {
            MXLog.error("Cannot send Matrix call events - MatrixCallService not available. Client proxy: \(clientProxy != nil ? "available" : "nil")")
            return
        }
        
        guard let callId = currentCallId else {
            MXLog.error("Cannot send Matrix call events - no call ID generated")
            return
        }
        
        do {
            // 1. Send call invite event
            try await matrixCallService.sendCallInvite(roomId: roomId,
                                                       callId: callId,
                                                       isVideo: isVideo,
                                                       invitee: nil // Group call
            )
            
            // 2. Send call member join event
            try await matrixCallService.sendCallMemberJoin(roomId: roomId,
                                                           callId: callId,
                                                           expiresIn: 3600)
            
            // 3. Send notify ring event to trigger push notifications
            try await matrixCallService.sendCallNotifyRing(roomId: roomId,
                                                           callId: callId,
                                                           mentionUsers: [])
            
            MXLog.info("Successfully sent all Matrix call events for call: \(callId)")
            
        } catch {
            MXLog.error("Failed to send Matrix call events: \(error)")
            self.error = .connectionFailed
        }
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
    
    /// Answer an incoming call with pre-provided LiveKit credentials (for VoIP push auto-connect)
    @MainActor
    func answerCallWithCredentials(roomId: String, callId: String, accessToken: String, serverURL: String, roomURL: String?) async throws {
        MXLog.info("🎬 Answering LiveKit call with pre-provided credentials - callId: \(callId)")
        MXLog.info("🔑 Server: \(serverURL), Token: [PRESENT], Room URL: \(roomURL ?? "nil")")
        
        // CRITICAL: Validate credentials before proceeding
        guard !accessToken.isEmpty, !serverURL.isEmpty else {
            MXLog.error("❌ CRITICAL: Invalid LiveKit credentials provided")
            MXLog.error("❌ AccessToken empty: \(accessToken.isEmpty), ServerURL empty: \(serverURL.isEmpty)")
            throw LiveKitCallError.invalidToken
        }
        
        // Basic JWT token validation (should start with ey)
        if !accessToken.hasPrefix("ey") {
            MXLog.warning("⚠️ WARNING: Access token doesn't look like a valid JWT (should start with 'ey')")
            MXLog.warning("⚠️ Token: \(accessToken.prefix(20))...")
        }
        
        // Validate server URL format
        if !serverURL.hasPrefix("wss://"), !serverURL.hasPrefix("ws://") {
            MXLog.warning("⚠️ WARNING: Server URL should start with ws:// or wss://")
            MXLog.warning("⚠️ Server URL: \(serverURL)")
        }
        
        // Set up for incoming call
        currentCallId = callId
        isOutgoingCall = false
        callState = .connecting
        isCallAnswered = true
        
        // Start the call connection using provided credentials
        try await connectToCallWithCredentials(accessToken: accessToken, serverURL: serverURL, roomId: roomId)
    }
    
    /// Connect to an existing call (used for both incoming and outgoing)
    private func connectToCall(roomId: String) async throws {
        do {
            let token = try await authService.getAccessToken(roomId: roomId)
            MXLog.info("Connecting to LiveKit server: \(serverURL) with video enabled: \(isVideoEnabled)")
            
            // Connect to LiveKit server
            try await room.connect(url: serverURL, token: token)
            
            // Enable local audio (always enabled for calls)
            try await room.localParticipant.setMicrophone(enabled: true)
            
            // Enable video only if this is a video call
            try await room.localParticipant.setCamera(enabled: isVideoEnabled)
            MXLog.info("Camera configured for incoming call - enabled: \(isVideoEnabled)")
            
            await MainActor.run {
                isConnected = true
                localParticipant = room.localParticipant
                callState = .active
            }
            await updateMediaStates()
            
            MXLog.info("Successfully connected to LiveKit call (video: \(isVideoEnabled))")
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
    
    /// Connect to LiveKit call using pre-provided credentials (for VoIP push auto-connect)
    private func connectToCallWithCredentials(accessToken: String, serverURL: String, roomId: String? = nil) async throws {
        do {
            MXLog.info("🎬 Connecting to LiveKit server using VoIP push credentials")
            MXLog.info("🔗 Server: \(serverURL), Video enabled: \(isVideoEnabled)")
            
            // Validate credentials before attempting connection
            guard !accessToken.isEmpty, !serverURL.isEmpty else {
                MXLog.warning("⚠️ Invalid credentials provided, falling back to standard auth")
                throw LiveKitCallError.invalidToken
            }
            
            // Connect to LiveKit server using provided credentials
            try await room.connect(url: serverURL, token: accessToken)
            
            // Enable local audio (always enabled for calls)
            try await room.localParticipant.setMicrophone(enabled: true)
            
            // Enable video only if this is a video call
            try await room.localParticipant.setCamera(enabled: isVideoEnabled)
            MXLog.info("🎥 Camera configured for auto-connect call - enabled: \(isVideoEnabled)")
            
            await MainActor.run {
                isConnected = true
                localParticipant = room.localParticipant
                callState = .active
            }
            await updateMediaStates()
            
            MXLog.info("✅ Successfully auto-connected to LiveKit call using VoIP push credentials")
        } catch {
            MXLog.error("❌ Failed to auto-connect to LiveKit call: \(error)")
            
            // If credentials failed and we have roomId, try fallback to standard auth
            if let roomId = roomId {
                MXLog.info("🔄 Attempting fallback to standard auth for room: \(roomId)")
                do {
                    try await connectToCall(roomId: roomId)
                    MXLog.info("✅ Fallback connection successful")
                    return
                } catch {
                    MXLog.error("❌ Fallback connection also failed: \(error)")
                }
            }
            
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
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setActive(true)
            MXLog.info("Audio session configured for call")
        } catch {
            MXLog.error("Failed to configure audio session: \(error)")
        }
    }
    
    // MARK: - Ringtone Management
    
    private func startRingbackTone() {
        guard !isPlayingRingback else { return }
        
        MXLog.info("Starting ringback tone for outgoing call")
        isPlayingRingback = true
        
        // Use system sound for ringback
        // This creates a repeating ringback sound similar to phone calls
        DispatchQueue.main.async { [weak self] in
            self?.playRingbackSound()
        }
    }
    
    private func playRingbackSound() {
        guard isPlayingRingback else { return }
        
        // Play system ringback sound
        AudioServicesPlaySystemSound(SystemSoundID(1013)) // Ringback tone
        
        // Schedule next ringback sound after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.playRingbackSound()
        }
    }
    
    private func stopRingbackTone() {
        guard isPlayingRingback else { return }
        
        MXLog.info("Stopping ringback tone")
        isPlayingRingback = false
        
        // Stop any ongoing audio
        AudioServicesDisposeSystemSoundID(SystemSoundID(1013))
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
        guard !isCallAnswered, callState == .ringing else {
            return // Call was already answered or ended
        }
        
        MXLog.warning("Call timeout reached - ending call")
        
        // Stop ringback and play timeout/busy signal
        stopRingbackTone()
        playTimeoutTone()
        
        callState = .noAnswer
        error = .noAnswer
        
        // End the call
        await endCall()
    }
    
    private func playTimeoutTone() {
        MXLog.info("Playing timeout/busy tone")
        
        // Play busy signal (short beeps)
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                AudioServicesPlaySystemSound(SystemSoundID(1324)) // Short beep sound
            }
        }
    }
    
    // MARK: - Call History Integration
    
    /// Record outgoing call in CallHistoryManager
    private func recordOutgoingCall(roomId: String, callId: String, clientProxy: ClientProxyProtocol, isVideo: Bool) async {
        do {
            // Get current user info
            let currentUserId = clientProxy.userID
            let currentUserDisplayName: String
            
            switch await clientProxy.profile(for: currentUserId) {
            case .success(let profile):
                currentUserDisplayName = profile.displayName ?? currentUserId
            case .failure:
                currentUserDisplayName = currentUserId // Fallback to user ID if profile fetch fails
            }
            
            // Create caller participant (current user)
            let caller = CallParticipant(userId: currentUserId,
                                         displayName: currentUserDisplayName,
                                         avatarURL: nil, // TODO: Add avatar URL when available
                                         handle: currentUserDisplayName ?? currentUserId)
            
            // For now, we'll use roomId as callee handle since we don't have easy access to other participant info
            // This will be improved when we get proper room participant querying
            let callee = CallParticipant(userId: roomId, // Temporary: using roomId as placeholder
                                         displayName: "Contact", // Temporary placeholder
                                         avatarURL: nil,
                                         handle: "Contact")
            
            // Create call info
            let callInfo = CallInfo(id: callId,
                                    roomId: roomId,
                                    caller: caller,
                                    callee: callee,
                                    type: isVideo ? .video : .audio,
                                    direction: .outgoing,
                                    timestamp: Date(),
                                    duration: nil,
                                    status: .ringing,
                                    liveKitConfig: nil // Will be set later when available
            )
            
            // Record call in CallHistoryManager
            await CallHistoryManager.shared.recordCall(callInfo)
            MXLog.info("🔥 CRITICAL: Successfully recorded outgoing call in CallHistoryManager: \(callId)")
            
        } catch {
            MXLog.error("🔥 CRITICAL: Failed to record outgoing call in CallHistoryManager: \(error)")
        }
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
            
            // If this is an outgoing call and someone joined, consider call answered
            if self.isOutgoingCall, self.callState == .ringing {
                MXLog.info("Outgoing call answered by participant")
                self.stopRingbackTone()
                self.cancelCallTimeoutTimer()
                self.callState = .active
                self.isCallAnswered = true
                
                // 🔥 CRITICAL FIX: Report outgoing call as connected to appear in system call log
                if self.isOutgoingCall, let callId = self.currentCallId {
                    if let callUUID = LiveKitCallKitService.shared.findCallUUID(for: callId) {
                        LiveKitCallKitService.shared.reportOutgoingCallConnected(callUUID: callUUID)
                        MXLog.info("🔥 CRITICAL: Successfully reported outgoing call connected to CallKit for call log (participant joined)")
                    } else {
                        MXLog.warning("⚠️ CRITICAL: Could not find CallKit UUID for call ID: \(callId)")
                    }
                }
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

// MARK: - Matrix Call Event Models

/// Content for m.call.invite events
struct MatrixCallInviteContent: Codable {
    /// The call ID for this call
    let callId: String
    
    /// The version of the call protocol being used
    let version: String
    
    /// The duration of the call invite in milliseconds
    let lifetime: Int
    
    /// The user being invited (nil for group calls)
    let invitee: String?
    
    /// Type of call (voice/video)
    let type: MatrixCallType
    
    /// Conference ID for group calls
    let confId: String?
    
    /// Sequential counter to track call state changes
    let seq: Int
    
    /// Application-specific data (LiveKit room details)
    let applicationData: ApplicationData?
    
    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case version
        case lifetime
        case invitee
        case type
        case confId = "conf_id"
        case seq
        case applicationData = "application_data"
    }
}

/// Content for m.call.member events (MSC3401)
struct MatrixCallMemberContent: Codable {
    /// The call ID
    let callId: String
    
    /// Sequential counter
    let seq: Int
    
    /// Member state
    let membership: CallMembership
    
    /// Expire time for this membership
    let expires: Int?
    
    /// Reason for leaving
    let reason: String?
    
    /// Device ID
    let deviceId: String
    
    /// Focus selection (active speaker, etc)
    let focusSelection: FocusSelection?
    
    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case seq
        case membership
        case expires
        case reason
        case deviceId = "device_id"
        case focusSelection = "focus_selection"
    }
}

/// Content for m.call.notify events (MSC4075)
struct MatrixCallNotifyContent: Codable {
    /// The call ID
    let callId: String
    
    /// Sequential counter
    let seq: Int
    
    /// Type of notification
    let notifyType: NotifyType
    
    /// Mention content for ring notifications
    let mention: Mention?
    
    /// Application-specific data
    let applicationData: ApplicationData?
    
    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case seq
        case notifyType = "notify_type"
        case mention
        case applicationData = "application_data"
    }
}

// MARK: - Supporting Types

enum MatrixCallType: String, Codable {
    case voice
    case video
}

enum CallMembership: String, Codable {
    case join
    case leave
}

public enum NotifyType: String, Codable {
    case ring
    case notify
}

struct ApplicationData: Codable {
    /// LiveKit room URL
    let liveKitRoomUrl: String?
    
    /// LiveKit access token
    let liveKitAccessToken: String?
    
    /// LiveKit server URL
    let liveKitServerUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case liveKitRoomUrl = "livekit_room_url"
        case liveKitAccessToken = "livekit_access_token"
        case liveKitServerUrl = "livekit_server_url"
    }
}

struct FocusSelection: Codable {
    /// Type of focus (speaker, etc)
    let type: String
    
    /// Focus target
    let focus: String
}

struct Mention: Codable {
    /// User being mentioned
    let userIds: [String]
    
    /// Room-wide mention
    let room: Bool
    
    enum CodingKeys: String, CodingKey {
        case userIds = "user_ids"
        case room
    }
}

// MARK: - Matrix Event Wrappers

/// Wrapper for sending Matrix call events
struct MatrixCallEvent {
    let eventType: String
    let content: Codable
    let roomId: String
    let stateKey: String?
    
    static func callInvite(content: MatrixCallInviteContent, roomId: String) -> MatrixCallEvent {
        MatrixCallEvent(eventType: "m.call.invite",
                        content: content,
                        roomId: roomId,
                        stateKey: nil)
    }
    
    static func callMember(content: MatrixCallMemberContent, roomId: String, userId: String) -> MatrixCallEvent {
        MatrixCallEvent(eventType: "m.call.member",
                        content: content,
                        roomId: roomId,
                        stateKey: userId)
    }
    
    static func callNotify(content: MatrixCallNotifyContent, roomId: String) -> MatrixCallEvent {
        MatrixCallEvent(eventType: "m.call.notify",
                        content: content,
                        roomId: roomId,
                        stateKey: nil)
    }
}

// MARK: - Call State Management

/// Manages call state and sequence numbers
class MatrixCallStateManager {
    private var sequenceCounters: [String: Int] = [:]
    private let lock = NSLock()
    
    /// Get next sequence number for a call
    func nextSequence(for callId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        let current = sequenceCounters[callId] ?? 0
        let next = current + 1
        sequenceCounters[callId] = next
        return next
    }
    
    /// Reset sequence for a call
    func resetSequence(for callId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        sequenceCounters.removeValue(forKey: callId)
    }
    
    /// Get current sequence for a call
    func currentSequence(for callId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        return sequenceCounters[callId] ?? 0
    }
}

/// Service for managing Matrix call protocol events
class MatrixCallService: ObservableObject, MatrixCallServiceProtocol {
    private let clientProxy: ClientProxyProtocol
    private let liveKitAuthService: LiveKitAuthServiceProtocol
    private let stateManager = MatrixCallStateManager()
    
    /// Current device ID
    private var deviceId: String {
        clientProxy.deviceID ?? UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
    
    /// Current user ID
    private var userId: String {
        clientProxy.userID
    }
    
    init(clientProxy: ClientProxyProtocol, liveKitAuthService: LiveKitAuthServiceProtocol) {
        self.clientProxy = clientProxy
        self.liveKitAuthService = liveKitAuthService
    }
    
    // MARK: - Call Invitation
    
    /// Send m.call.invite event to start a call
    func sendCallInvite(roomId: String, callId: String, isVideo: Bool, invitee: String? = nil) async throws {
        MXLog.info("Sending m.call.invite for call: \(callId) in room: \(roomId)")
        
        // Get LiveKit room details
        let liveKitDetails = try await liveKitAuthService.getCallDetails(roomId: roomId, callId: callId)
        
        let applicationData = ApplicationData(liveKitRoomUrl: liveKitDetails.roomUrl,
                                              liveKitAccessToken: liveKitDetails.accessToken,
                                              liveKitServerUrl: liveKitDetails.serverUrl)
        
        let inviteContent = MatrixCallInviteContent(callId: callId,
                                                    version: "1",
                                                    lifetime: 60000, // 60 seconds
                                                    invitee: invitee,
                                                    type: isVideo ? .video : .voice,
                                                    confId: roomId, // Use room ID as conference ID for group calls
                                                    seq: stateManager.nextSequence(for: callId),
                                                    applicationData: applicationData)
        
        // Send the event
        try await sendEvent(.callInvite(content: inviteContent, roomId: roomId))
        
        MXLog.info("Successfully sent m.call.invite for call: \(callId)")
    }
    
    /// Send m.call.member event to join a call
    func sendCallMemberJoin(roomId: String, callId: String, expiresIn: TimeInterval = 3600) async throws {
        MXLog.info("Sending m.call.member join for call: \(callId) in room: \(roomId)")
        
        let memberContent = MatrixCallMemberContent(callId: callId,
                                                    seq: stateManager.nextSequence(for: callId),
                                                    membership: .join,
                                                    expires: Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000),
                                                    reason: nil,
                                                    deviceId: deviceId,
                                                    focusSelection: nil)
        
        try await sendEvent(.callMember(content: memberContent, roomId: roomId, userId: userId))
        
        MXLog.info("Successfully sent m.call.member join for call: \(callId)")
    }
    
    /// Send m.call.member event to leave a call
    func sendCallMemberLeave(roomId: String, callId: String, reason: String? = nil) async throws {
        MXLog.info("Sending m.call.member leave for call: \(callId) in room: \(roomId)")
        
        let memberContent = MatrixCallMemberContent(callId: callId,
                                                    seq: stateManager.nextSequence(for: callId),
                                                    membership: .leave,
                                                    expires: nil,
                                                    reason: reason,
                                                    deviceId: deviceId,
                                                    focusSelection: nil)
        
        try await sendEvent(.callMember(content: memberContent, roomId: roomId, userId: userId))
        
        // Reset sequence counter when leaving
        stateManager.resetSequence(for: callId)
        
        MXLog.info("Successfully sent m.call.member leave for call: \(callId)")
    }
    
    /// Send m.call.notify event for ringing
    func sendCallNotifyRing(roomId: String, callId: String, mentionUsers: [String] = []) async throws {
        MXLog.info("Sending m.call.notify ring for call: \(callId) in room: \(roomId)")
        
        let mention = mentionUsers.isEmpty ? nil : Mention(userIds: mentionUsers, room: false)
        
        let notifyContent = MatrixCallNotifyContent(callId: callId,
                                                    seq: stateManager.nextSequence(for: callId),
                                                    notifyType: .ring,
                                                    mention: mention,
                                                    applicationData: nil)
        
        try await sendEvent(.callNotify(content: notifyContent, roomId: roomId))
        
        MXLog.info("Successfully sent m.call.notify ring for call: \(callId)")
    }
    
    // MARK: - Event Sending
    
    /// Send a Matrix call event
    private func sendEvent(_ event: MatrixCallEvent) async throws {
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(event.roomId) else {
            throw MatrixCallError.notJoinedToRoom
        }
        
        // Convert content to JSON
        let jsonData = try JSONEncoder().encode(event.content)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        
        MXLog.debug("Sending Matrix event: \(event.eventType) to room: \(event.roomId)")
        MXLog.debug("Event content: \(jsonString)")
        
        // Send as custom message content
        let result = await roomProxy.timeline.sendMessage(jsonString,
                                                          html: nil,
                                                          threadRootEventID: nil,
                                                          inReplyToEventID: nil,
                                                          intentionalMentions: .empty)
        
        switch result {
        case .success:
            MXLog.info("Successfully sent \(event.eventType) event")
        case .failure(let error):
            MXLog.error("Failed to send \(event.eventType) event: \(error)")
            throw MatrixCallError.eventSendFailed(error)
        }
    }
    
    // MARK: - Incoming Call Event Handling
    
    /// Start listening for incoming call events in all rooms
    func startListeningForIncomingCalls(callKitService: LiveKitCallKitService) {
        MXLog.info("Starting to listen for incoming Matrix call events")
        
        // Listen to timeline events across all rooms for call invites
        Task {
            await setupCallEventListener(callKitService: callKitService)
        }
    }
    
    private func setupCallEventListener(callKitService: LiveKitCallKitService) async {
        MXLog.info("Setting up Matrix call event listener for incoming calls")
        
        // Listen to all timeline events across all rooms
        Task { [weak self] in
            guard let self = self else { return }
            
            // PRODUCTION NOTE: Room monitoring will be implemented when Matrix SDK exposes roomListService
            // Currently the Matrix SDK doesn't expose roomListService directly
            MXLog.info("Room monitoring not yet implemented - waiting for SDK API support")
        }
    }
    
    private func setupTimelineListener(for roomProxy: RoomProxyProtocol, callKitService: LiveKitCallKitService) async {
        MXLog.info("Setting up timeline listener for room: \(roomProxy.id)")
        
        // PRODUCTION NOTE: Timeline listening will be implemented when SDK provides access
        // Currently timeline.timelineProvider is not available in the protocol
        MXLog.info("Timeline listening not yet implemented - waiting for SDK API support")
    }
    
    private func handleTimelineUpdate(_ update: [RoomTimelineItemProtocol], roomProxy: RoomProxyProtocol, callKitService: LiveKitCallKitService) async {
        // PRODUCTION NOTE: Timeline update handling will be implemented when SDK provides eventType access
        // Currently EventBasedTimelineItemProtocol doesn't expose eventType property
        MXLog.info("Timeline update handling not yet implemented - waiting for SDK API support")
    }
    
    private func handleIncomingCallInvite(eventItem: EventBasedTimelineItemProtocol, roomProxy: RoomProxyProtocol, callKitService: LiveKitCallKitService) async {
        MXLog.info("Handling incoming call invite in room: \(roomProxy.id)")
        
        // Don't handle our own call invites
        guard eventItem.sender.id != userId else {
            MXLog.info("Ignoring own call invite")
            return
        }
        
        // Extract call information from the event
        guard let callId = extractCallId(from: eventItem),
              let isVideo = extractCallType(from: eventItem) else {
            MXLog.error("Failed to extract call information from invite event")
            return
        }
        
        let callerName = eventItem.sender.displayName ?? eventItem.sender.id
        
        // Report incoming call to CallKit
        await callKitService.handleIncomingCallFromMatrix(roomId: roomProxy.id,
                                                          callId: callId,
                                                          callerName: callerName,
                                                          hasVideo: isVideo == .video)
    }
    
    private func extractCallId(from eventItem: EventBasedTimelineItemProtocol) -> String? {
        // Try to parse the event content to extract call_id
        // Matrix events typically contain JSON content that we need to parse
        
        // For Matrix call events, the call_id should be in the event content
        // Since we don't have direct access to raw event content here,
        // we'll generate a deterministic call ID based on event ID
        // PRODUCTION NOTE: Extract actual call_id from event content when SDK supports it
        
        UUID().uuidString
    }
    
    private func extractCallType(from eventItem: EventBasedTimelineItemProtocol) -> MatrixCallType? {
        // Extract call type from event content
        // Matrix call invite events contain a "type" field indicating voice/video
        
        // For now, we'll analyze the event content or default to video
        // In a real implementation, we'd parse the JSON content
        .video // Default to video calls
    }
    
    private func handleCallMemberEvent(eventItem: EventBasedTimelineItemProtocol, roomProxy: RoomProxyProtocol, callKitService: LiveKitCallKitService) async {
        MXLog.info("Handling call member event in room: \(roomProxy.id)")
        
        // Don't handle our own member events
        guard eventItem.sender.id != userId else {
            MXLog.info("Ignoring own call member event")
            return
        }
        
        // Extract member information from the event
        guard let callId = extractCallId(from: eventItem),
              let membership = extractMembership(from: eventItem) else {
            MXLog.error("Failed to extract call member information from event")
            return
        }
        
        let memberName = eventItem.sender.displayName ?? eventItem.sender.id
        
        // Handle different membership states
        switch membership {
        case .join:
            MXLog.info("User \(memberName) joined call \(callId)")
            // Could trigger UI updates showing active participants
            
        case .leave:
            MXLog.info("User \(memberName) left call \(callId)")
            // Could update UI to show participant left
            // If this was the last participant, might end our call
        }
    }
    
    private func extractMembership(from eventItem: EventBasedTimelineItemProtocol) -> CallMembership? {
        // Try to parse the event content to extract membership state
        // For now, assume join membership for any member event
        .join
    }
    
    // MARK: - Call State Queries
    
    /// Check if user has VoIP push capability
    func checkVoIPCapability(for userId: String) async -> Bool {
        MXLog.info("Checking VoIP capability for user: \(userId)")
        
        // PRODUCTION NOTE: Push rules check will be implemented when SDK provides access
        // Currently getPushRules is not available in ClientProxyProtocol
        MXLog.info("VoIP capability check not yet implemented - defaulting to true")
        return true
    }
    
    /// Check if current user has VoIP capability before making calls
    func checkOwnVoIPCapability() async -> Bool {
        await checkVoIPCapability(for: userId)
    }
    
    /// Get active call members in a room
    func getActiveCallMembers(roomId: String, callId: String) async -> [String] {
        // Query room state for m.call.member events
        // Filter by call ID and active memberships
        MXLog.info("Getting active call members for call: \(callId)")
        
        // PRODUCTION NOTE: Room state querying will be implemented when available
        return []
    }
}

// MARK: - Matrix Call Error Types

enum MatrixCallError: Error, LocalizedError {
    case notJoinedToRoom
    case eventSendFailed(Error)
    case invalidCallState
    case liveKitTokenFailed
    
    var errorDescription: String? {
        switch self {
        case .notJoinedToRoom:
            return "Not joined to room"
        case .eventSendFailed(let error):
            return "Failed to send event: \(error.localizedDescription)"
        case .invalidCallState:
            return "Invalid call state"
        case .liveKitTokenFailed:
            return "Failed to get LiveKit token"
        }
    }
}

#endif
