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
import SwiftUI

@MainActor
final class LiveKitCallViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var participants: [Participant] = []
    @Published var localParticipant: LocalParticipant?
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var error: LiveKitCallError?
    @Published var isLoading = false
    @Published var isSpeakerOn = false
    @Published var isScreenSharing = false
    @Published var cameraFlipAngle: Double = 0
    @Published var callState: CallState = .idle
    
    // MARK: - Private Properties

    private let roomId: String
    private let callService: LiveKitCallService
    private var cancellables = Set<AnyCancellable>()
    
    init(roomId: String, callService: LiveKitCallService) {
        self.roomId = roomId
        self.callService = callService
        setupBindings()
    }
    
    // MARK: - Public Methods

    func startCall() async {
        isLoading = true
        error = nil
        
        // First, test auth server connectivity if using real authentication
        MXLog.info("Testing LiveKit authentication server connectivity...")
        let authTestResult = await callService.authService.testConnection()
        if !authTestResult {
            MXLog.warning("Auth server connectivity test failed, but continuing with fallback")
        }
        
        // Try connecting with retry mechanism
        var retryCount = 0
        let maxRetries = 3
        
        while retryCount < maxRetries {
            do {
                MXLog.info("Starting call attempt \(retryCount + 1)/\(maxRetries) for room: \(roomId)")
                try await callService.startCall(roomId: roomId)
                MXLog.info("✅ LiveKit call started successfully for room: \(roomId)")
                isLoading = false
                return
            } catch let connectionError {
                retryCount += 1
                self.error = connectionError as? LiveKitCallError ?? .connectionFailed
                MXLog.error("❌ Failed to start call (attempt \(retryCount)): \(connectionError)")
                
                if retryCount < maxRetries {
                    let waitTime = retryCount * 2 // Progressive backoff: 2s, 4s, 6s
                    MXLog.info("⏳ Retrying connection in \(waitTime) seconds... (attempt \(retryCount + 1)/\(maxRetries))")
                    try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
                    self.error = nil // Clear error before retry
                }
            }
        }
        
        MXLog.error("❌ Failed to connect after \(maxRetries) attempts")
        isLoading = false
    }
    
    func endCall() async {
        await callService.endCall()
        MXLog.info("LiveKit call ended for room: \(roomId)")
    }
    
    func toggleMicrophone() async {
        await callService.toggleMicrophone()
    }
    
    func toggleCamera() async {
        await callService.toggleCamera()
    }
    
    func retryConnection() async {
        await startCall()
    }
    
    // MARK: - Private Methods

    private func setupBindings() {
        // Bind call service properties to view model
        callService.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$isConnected)
            
        callService.$participants
            .receive(on: DispatchQueue.main)
            .assign(to: &$participants)
            
        callService.$localParticipant
            .receive(on: DispatchQueue.main)
            .assign(to: &$localParticipant)
            
        callService.$isMuted
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMuted)
            
        callService.$isVideoEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$isVideoEnabled)
            
        callService.$error
            .receive(on: DispatchQueue.main)
            .assign(to: &$error)
            
        callService.$callState
            .receive(on: DispatchQueue.main)
            .assign(to: &$callState)
    }
}

// MARK: - Helper Extensions

extension LiveKitCallViewModel {
    var hasParticipants: Bool {
        !participants.isEmpty
    }
    
    var participantCount: Int {
        participants.count + (localParticipant != nil ? 1 : 0)
    }
    
    var connectionStatusText: String {
        if isLoading {
            return "Connecting..."
        } else if isConnected {
            return "Connected"
        } else if error != nil {
            return "Connection Failed"
        } else {
            return "Disconnected"
        }
    }
    
    // MARK: - Enhanced UI Functions
    
    func toggleSpeaker() async {
        // Toggle speaker/earpiece
        isSpeakerOn.toggle()
        
        // Configure audio session through CallService
        await callService.setSpeakerEnabled(isSpeakerOn)
        MXLog.info("Audio output switched to: \(isSpeakerOn ? "speaker" : "earpiece")")
    }
    
    func flipCamera() async {
        // Animate camera flip
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraFlipAngle += 180
        }
        
        // Implement actual camera switching in LiveKit
        await callService.switchCamera()
        MXLog.info("Camera flipped successfully")
    }
    
    func toggleScreenShare() async {
        do {
            if isScreenSharing {
                // Stop screen sharing
                await callService.stopScreenShare()
                isScreenSharing = false
            } else {
                // Start screen sharing
                try await callService.startScreenShare()
                isScreenSharing = true
            }
        } catch {
            MXLog.error("Failed to toggle screen share: \(error)")
            // Revert state on error
            isScreenSharing = !isScreenSharing
        }
    }
}
#endif
