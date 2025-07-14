//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import LiveKit

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
        
        do {
            try await callService.startCall(roomId: roomId)
            MXLog.info("LiveKit call started for room: \(roomId)")
        } catch {
            self.error = error as? LiveKitCallError ?? .connectionFailed
            MXLog.error("Failed to start call: \(error)")
        }
        
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
}
