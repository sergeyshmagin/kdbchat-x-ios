//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum SecureBackupRecoveryKeyScreenViewModelAction {
    case done(mode: SecureBackupRecoveryKeyScreenViewMode)
    case cancel
}

enum SecureBackupRecoveryKeyScreenViewMode {
    case setupRecovery
    case changeRecovery
    case fixRecovery
    case viewRecovery
    case unknown
}

struct SecureBackupRecoveryKeyScreenViewState: BindableState {
    /// Whether the screen is presented modally or within a navigation stack.
    var isModallyPresented: Bool
    
    let mode: SecureBackupRecoveryKeyScreenViewMode
    
    var recoveryKey: String?
    var isGeneratingKey = false
    var doneButtonEnabled = false
    
    var bindings: SecureBackupRecoveryKeyScreenViewBindings
    
    var title: String {
        switch mode {
        case .setupRecovery:
            return recoveryKey == nil ? L10n.screenRecoveryKeySetupTitle : L10n.screenRecoveryKeySaveTitle
        case .changeRecovery:
            return recoveryKey == nil ? L10n.screenRecoveryKeyChangeTitle : L10n.screenRecoveryKeySaveTitle
        case .fixRecovery:
            return L10n.screenRecoveryKeyConfirmTitle
        case .viewRecovery:
            return L10n.commonRecoveryKey
        default:
            return L10n.errorUnknown
        }
    }
    
    var subtitle: String? {
        switch mode {
        case .setupRecovery:
            return recoveryKey == nil ? L10n.screenRecoveryKeySetupDescription : L10n.screenRecoveryKeySaveDescription
        case .changeRecovery:
            return recoveryKey == nil ? L10n.screenRecoveryKeyChangeDescription : L10n.screenRecoveryKeySaveDescription
        case .fixRecovery:
            return L10n.screenRecoveryKeyConfirmDescription
        case .viewRecovery:
            return "Ваш ключ восстановления для резервного копирования сообщений"
        default:
            return nil
        }
    }
    
    var recoveryKeySubtitle: String? {
        switch mode {
        case .setupRecovery:
            return recoveryKey == nil ? L10n.screenRecoveryKeySetupGenerateKeyDescription : L10n.screenRecoveryKeySaveKeyDescription
        case .changeRecovery:
            return recoveryKey == nil ? L10n.screenRecoveryKeyChangeGenerateKeyDescription : L10n.screenRecoveryKeySaveKeyDescription
        case .fixRecovery:
            return L10n.screenRecoveryKeyConfirmKeyDescription
        case .viewRecovery:
            return "Скопируйте этот ключ в безопасное место. Он понадобится для восстановления сообщений на новых устройствах."
        default:
            return nil
        }
    }
}

struct SecureBackupRecoveryKeyScreenViewBindings {
    var confirmationRecoveryKey = ""
    var alertInfo: AlertInfo<UUID>?
}

enum SecureBackupRecoveryKeyScreenViewAction {
    case generateKey
    case loadExistingKey
    case copyKey
    case keySaved
    case confirmKey
    case done
    case cancel
}
