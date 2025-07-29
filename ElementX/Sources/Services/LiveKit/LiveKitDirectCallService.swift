//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import Combine
import Foundation

// MARK: - Call States

enum DirectCallState {
    case idle
    case ringing(callId: String)
    case connecting(callId: String)
    case active(callId: String)
    case ended
    case noAnswer
    case declined
    case error(Error)
}

// MARK: - Call Direction

// Use existing CallDirection from HomeScreenModels.swift

// MARK: - Call Information

struct DirectCall {
    let callId: String
    let roomId: String
    let direction: CallDirection
    let otherParticipantId: String
    let otherParticipantName: String?
    let isVideoCall: Bool
    var state: DirectCallState
    let createdAt: Date
}

// MARK: - Direct Call Service

final class LiveKitDirectCallService: ObservableObject {
    @Published var currentCall: DirectCall?
    @Published private var callState: DirectCallState = .idle
    
    private var callTimer: Timer?
    private let callTimeout: TimeInterval = 60.0
    
    var callStatePublisher: AnyPublisher<DirectCallState, Never> {
        $callState.eraseToAnyPublisher()
    }
    
    init() {
        MXLog.info("LiveKitDirectCallService initialized")
    }
    
    func configure(clientProxy: ClientProxyProtocol,
                   liveKitCallService: LiveKitCallService,
                   callKitService: LiveKitCallKitService) {
        MXLog.info("LiveKitDirectCallService configured")
    }
    
    func startCall(roomId: String, isVideoCall: Bool) async throws {
        let callId = UUID().uuidString
        
        currentCall = DirectCall(callId: callId,
                                 roomId: roomId,
                                 direction: .outgoing,
                                 otherParticipantId: "@unknown:example.com",
                                 otherParticipantName: "Unknown User",
                                 isVideoCall: isVideoCall,
                                 state: .ringing(callId: callId),
                                 createdAt: Date())
        
        updateCallState(.ringing(callId: callId))
        startCallTimeout(callId: callId)
        
        MXLog.info("Outgoing call started - CallID: \(callId)")
    }
    
    func answerCall(callId: String) async throws {
        guard let call = currentCall, call.callId == callId else { return }
        stopCallTimeout()
        updateCallState(.active(callId: callId))
        MXLog.info("Call answered - CallID: \(callId)")
    }
    
    func declineCall(callId: String) async throws {
        await endCallInternal(reason: .declined)
        MXLog.info("Call declined - CallID: \(callId)")
    }
    
    func endCall() async throws {
        guard let call = currentCall else { return }
        await endCallInternal(reason: .ended)
        MXLog.info("Call ended - CallID: \(call.callId)")
    }
    
    private func startCallTimeout(callId: String) {
        stopCallTimeout()
        callTimer = Timer.scheduledTimer(withTimeInterval: callTimeout, repeats: false) { [weak self] _ in
            Task { [weak self] in
                await self?.handleCallTimeout(callId: callId)
            }
        }
    }
    
    private func stopCallTimeout() {
        callTimer?.invalidate()
        callTimer = nil
    }
    
    private func handleCallTimeout(callId: String) async {
        guard let call = currentCall, call.callId == callId else { return }
        MXLog.info("Call timeout - CallID: \(callId)")
        await endCallInternal(reason: .noAnswer)
    }
    
    private func endCallInternal(reason: DirectCallState) async {
        stopCallTimeout()
        updateCallState(reason)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.currentCall = nil
            self?.updateCallState(.idle)
        }
    }
    
    private func updateCallState(_ newState: DirectCallState) {
        callState = newState
        currentCall?.state = newState
    }
}
#endif
