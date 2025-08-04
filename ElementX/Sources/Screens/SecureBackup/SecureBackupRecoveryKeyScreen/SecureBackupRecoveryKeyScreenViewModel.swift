//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SecureBackupRecoveryKeyScreenViewModelType = StateStoreViewModelV2<SecureBackupRecoveryKeyScreenViewState, SecureBackupRecoveryKeyScreenViewAction>

class SecureBackupRecoveryKeyScreenViewModel: SecureBackupRecoveryKeyScreenViewModelType, SecureBackupRecoveryKeyScreenViewModelProtocol {
    private let secureBackupController: SecureBackupControllerProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let clientProxy: ClientProxyProtocol?
    
    private var actionsSubject: PassthroughSubject<SecureBackupRecoveryKeyScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<SecureBackupRecoveryKeyScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(secureBackupController: SecureBackupControllerProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         isModallyPresented: Bool,
         clientProxy: ClientProxyProtocol? = nil,
         forceMode: SecureBackupRecoveryKeyScreenViewMode? = nil) {
        self.secureBackupController = secureBackupController
        self.userIndicatorController = userIndicatorController
        self.clientProxy = clientProxy
        
        let mode = forceMode ?? secureBackupController.recoveryState.value.viewMode
        super.init(initialViewState: .init(isModallyPresented: isModallyPresented,
                                           mode: mode,
                                           bindings: .init()))
        
        // If forced to viewRecovery mode, automatically load the key
        if mode == .viewRecovery {
            DispatchQueue.main.async { [weak self] in
                self?.process(viewAction: .loadExistingKey)
            }
        }
    }
    
    // MARK: - Public
    
    override func process(viewAction: SecureBackupRecoveryKeyScreenViewAction) {
        MXLog.info("View model: received view action: \(viewAction)")
        
        switch viewAction {
        case .loadExistingKey:
            guard let clientProxy = clientProxy else {
                MXLog.error("Cannot load existing key: clientProxy not available")
                state.bindings.alertInfo = .init(id: .init(),
                                                 title: "Ошибка",
                                                 message: "Не удалось загрузить ключ восстановления")
                return
            }
            
            let result = clientProxy.exportRecoveryKeyForBackup()
            switch result {
            case .success(let key):
                state.recoveryKey = key
                state.doneButtonEnabled = true
            case .failure(let error):
                MXLog.error("Failed loading existing recovery key with error: \(error)")
                state.bindings.alertInfo = .init(id: .init(),
                                                 title: "Ошибка",
                                                 message: "Не удалось загрузить ключ восстановления")
            }
        case .generateKey:
            state.isGeneratingKey = true
            
            Task {
                switch await secureBackupController.generateRecoveryKey() {
                case .success(let key):
                    state.recoveryKey = key
                case .failure(let error):
                    MXLog.error("Failed generating recovery key with error: \(error)")
                    state.bindings.alertInfo = .init(id: .init())
                }
                
                state.isGeneratingKey = false
            }
        case .copyKey:
            guard let recoveryKey = state.recoveryKey else {
                MXLog.error("Attempted to copy nil recovery key")
                return
            }
            
            UIPasteboard.general.string = recoveryKey
            
            // Добавляем тактильную обратную связь
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            
            // Улучшенное уведомление с иконкой
            userIndicatorController.submitIndicator(
                UserIndicator(
                    id: "recovery_key_copied",
                    type: .toast,
                    title: "Ключ восстановления скопирован",
                    iconName: "doc.on.clipboard"
                )
            )
            
            state.doneButtonEnabled = true
            MXLog.info("Recovery key copied to clipboard with enhanced user feedback")
        case .keySaved:
            state.doneButtonEnabled = true
        case .confirmKey:
            Task {
                showLoadingIndicator()
                
                switch await secureBackupController.confirmRecoveryKey(state.bindings.confirmationRecoveryKey) {
                case .success:
                    actionsSubject.send(.done(mode: state.mode))
                case .failure(let error):
                    MXLog.error("Failed confirming recovery key with error: \(error)")
                    state.bindings.alertInfo = .init(id: .init(),
                                                     title: L10n.screenRecoveryKeyConfirmErrorTitle,
                                                     message: L10n.screenRecoveryKeyConfirmErrorContent)
                }
                
                hideLoadingIndicator()
            }
        case .cancel:
            actionsSubject.send(.cancel)
        case .done:
            state.bindings.alertInfo = .init(id: .init(),
                                             title: L10n.screenRecoveryKeySetupConfirmationTitle,
                                             message: L10n.screenRecoveryKeySetupConfirmationDescription,
                                             primaryButton: .init(title: L10n.actionContinue) { [weak self] in
                                                 guard let self else { return }
                                                 actionsSubject.send(.done(mode: state.mode))
                                             },
                                             secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
        }
    }
    
    private static let loadingIndicatorIdentifier = "\(SecureBackupRecoveryKeyScreenViewModel.self)-Loading"
    
    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
    }
    
    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
}

extension SecureBackupRecoveryState {
    var viewMode: SecureBackupRecoveryKeyScreenViewMode {
        switch self {
        case .disabled:
            return .setupRecovery
        case .enabled:
            return .changeRecovery
        case .incomplete:
            return .fixRecovery
        default:
            return .unknown
        }
    }
}
