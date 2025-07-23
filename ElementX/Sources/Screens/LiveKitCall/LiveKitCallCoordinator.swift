//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import Combine
import SwiftUI

// The CoordinatorProtocol and LiveKitAuthServiceProtocol are not conditionally compiled
// since they are used in the main app regardless of LiveKit being enabled

struct LiveKitCallCoordinatorParameters {
    let roomId: String
    let authService: LiveKitAuthServiceProtocol
}

enum LiveKitCallCoordinatorAction {
    case dismiss
}

final class LiveKitCallCoordinator: CoordinatorProtocol {
    private let parameters: LiveKitCallCoordinatorParameters
    private var viewModel: LiveKitCallViewModel?
    
    private let actionsSubject: PassthroughSubject<LiveKitCallCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<LiveKitCallCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: LiveKitCallCoordinatorParameters) {
        self.parameters = parameters
    }
    
    convenience init(roomId: String, authService: LiveKitAuthServiceProtocol) {
        self.init(parameters: LiveKitCallCoordinatorParameters(roomId: roomId, authService: authService))
    }
    
    func start() {
        // Coordinator started
        
        // Listen for force dismiss notifications
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ForceDismissLiveKitCall"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.actionsSubject.send(.dismiss)
            }
        }
    }
    
    func stop() {
        viewModel = nil
        // Remove observers
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ForceDismissLiveKitCall"), object: nil)
    }
    
    func toPresentable() -> AnyView {
        let viewModel = LiveKitCallViewModel(roomId: parameters.roomId,
                                           callService: LiveKitCallService(authService: parameters.authService))
        
        self.viewModel = viewModel
        
        return AnyView(LiveKitCallScreen(roomId: parameters.roomId, authService: parameters.authService))
    }
}
#endif