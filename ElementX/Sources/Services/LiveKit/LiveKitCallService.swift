//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import LiveKit

enum LiveKitCallError: Error, LocalizedError {
    case connectionFailed
    case authenticationFailed
    case permissionDenied
    case roomNotFound
    
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
    
    // MARK: - Private Properties

    private let room = Room()
    private let authService: LiveKitAuthServiceProtocol
    private let clientProxy: ClientProxyProtocol?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Configuration

    private let serverURL = "wss://video.aibots.kz"
    
    init(authService: LiveKitAuthServiceProtocol, clientProxy: ClientProxyProtocol? = nil) {
        self.authService = authService
        self.clientProxy = clientProxy
        setupRoomObservers()
    }
    
    // MARK: - Public Methods

    @MainActor
    func startCall(roomId: String) async throws {
        do {
            let token = try await authService.getAccessToken(roomId: roomId)
            try await room.connect(url: serverURL, token: token)
            
            // Enable local audio and video by default
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)
            
            isConnected = true
            localParticipant = room.localParticipant
            updateMediaStates()
            
            MXLog.info("LiveKit call started successfully for room: \(roomId)")
        } catch {
            MXLog.error("Failed to start LiveKit call: \(error)")
            self.error = .connectionFailed
            throw error
        }
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
    
    @MainActor
    private func updateMediaStates() {
        let localParticipant = room.localParticipant
        isMuted = !localParticipant.isMicrophoneEnabled()
        isVideoEnabled = localParticipant.isCameraEnabled()
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
