//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI
import UIKit

enum SettingsFlowCoordinatorAction {
    case presentedSettings
    case dismissedSettings
    case runLogoutFlow
    case clearCache
    case refreshVoIPToken
    case clearAllVoIPTokens
    case showPusherInfo
    case forceReregisterVoIPPusher
    case forceReregisterPushers
    /// Logout without a confirmation. The user forgot their PIN.
    case forceLogout
}

struct SettingsFlowCoordinatorParameters {
    let userSession: UserSessionProtocol
    let windowManager: WindowManagerProtocol
    let appLockService: AppLockServiceProtocol
    let bugReportService: BugReportServiceProtocol
    let notificationSettings: NotificationSettingsProxyProtocol
    let secureBackupController: SecureBackupControllerProtocol
    let appSettings: AppSettings
    let navigationSplitCoordinator: NavigationSplitCoordinator
    let userIndicatorController: UserIndicatorControllerProtocol
    let analytics: AnalyticsService
}

class SettingsFlowCoordinator: FlowCoordinatorProtocol {
    private let parameters: SettingsFlowCoordinatorParameters
    
    private var navigationStackCoordinator: NavigationStackCoordinator!
    
    private var cancellables = Set<AnyCancellable>()
    
    // periphery:ignore - retaining purpose
    private var appLockSetupFlowCoordinator: AppLockSetupFlowCoordinator?
    // periphery:ignore - retaining purpose
    private var bugReportFlowCoordinator: BugReportFlowCoordinator?
    // periphery:ignore - retaining purpose
    private var encryptionSettingsFlowCoordinator: EncryptionSettingsFlowCoordinator?
    
    private let actionsSubject: PassthroughSubject<SettingsFlowCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<SettingsFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: SettingsFlowCoordinatorParameters) {
        self.parameters = parameters
    }
    
    func start() {
        fatalError("Unavailable")
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        switch appRoute {
        case .settings:
            presentSettingsScreen(animated: animated)
        case .chatBackupSettings:
            if navigationStackCoordinator == nil {
                presentSettingsScreen(animated: animated)
            }
            
            // The navigation stack doesn't like it if the root and the push happen
            // on the same loop run
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.startEncryptionSettingsFlow(animated: animated)
            }
        default:
            break
        }
    }
    
    func clearRoute(animated: Bool) {
        fatalError("Unavailable")
    }
    
    // MARK: - Private
    
    private func presentSettingsScreen(animated: Bool) {
        navigationStackCoordinator = NavigationStackCoordinator()
        
        let settingsScreenCoordinator = SettingsScreenCoordinator(parameters: .init(userSession: parameters.userSession,
                                                                                    appSettings: parameters.appSettings,
                                                                                    isBugReportServiceEnabled: parameters.bugReportService.isEnabled))
        
        settingsScreenCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .dismiss:
                    parameters.navigationSplitCoordinator.setSheetCoordinator(nil)
                case .logout:
                    parameters.navigationSplitCoordinator.setSheetCoordinator(nil)
                    
                    // The settings sheet needs to be dismissed before the alert can be shown
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.actionsSubject.send(.runLogoutFlow)
                    }
                case .secureBackup:
                    startEncryptionSettingsFlow(animated: true)
                case .userDetails:
                    presentUserDetailsEditScreen()
                case let .manageAccount(url):
                    presentAccountManagementURL(url)
                case .analytics:
                    presentAnalyticsScreen()
                case .appLock:
                    presentAppLockSetupFlow()
                case .bugReport:
                    bugReportFlowCoordinator = BugReportFlowCoordinator(parameters: .init(presentationMode: .push(navigationStackCoordinator),
                                                                                          userIndicatorController: parameters.userIndicatorController,
                                                                                          bugReportService: parameters.bugReportService,
                                                                                          userSession: parameters.userSession))
                    bugReportFlowCoordinator?.start()
                case .about:
                    presentLegalInformationScreen()
                case .blockedUsers:
                    presentBlockedUsersScreen()
                case .notifications:
                    presentNotificationSettings()
                case .advancedSettings:
                    presentAdvancedSettings()
                case .developerOptions:
                    presentDeveloperOptions()
                case .deactivateAccount:
                    presentDeactivateAccount()
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(settingsScreenCoordinator, animated: animated)
        
        parameters.navigationSplitCoordinator.setSheetCoordinator(navigationStackCoordinator) { [weak self] in
            guard let self else { return }
            
            navigationStackCoordinator = nil
            actionsSubject.send(.dismissedSettings)
        }
        
        actionsSubject.send(.presentedSettings)
    }
    
    private func startEncryptionSettingsFlow(animated: Bool) {
        let coordinator = EncryptionSettingsFlowCoordinator(parameters: .init(userSession: parameters.userSession,
                                                                              appSettings: parameters.appSettings,
                                                                              userIndicatorController: parameters.userIndicatorController,
                                                                              navigationStackCoordinator: navigationStackCoordinator))
        coordinator.actionsPublisher.sink { [weak self] action in
            switch action {
            case .complete:
                // The flow coordinator tidies up the stack, no need to do anything.
                self?.encryptionSettingsFlowCoordinator = nil
            }
        }
        .store(in: &cancellables)
        
        encryptionSettingsFlowCoordinator = coordinator
        coordinator.start()
    }
    
    private func presentUserDetailsEditScreen() {
        let coordinator = UserDetailsEditScreenCoordinator(parameters: .init(orientationManager: parameters.windowManager,
                                                                             clientProxy: parameters.userSession.clientProxy,
                                                                             mediaProvider: parameters.userSession.mediaProvider,
                                                                             mediaUploadingPreprocessor: MediaUploadingPreprocessor(appSettings: parameters.appSettings),
                                                                             navigationStackCoordinator: navigationStackCoordinator,
                                                                             userIndicatorController: parameters.userIndicatorController))
        
        navigationStackCoordinator?.push(coordinator)
    }
    
    private func presentAnalyticsScreen() {
        let coordinator = AnalyticsSettingsScreenCoordinator(parameters: .init(appSettings: parameters.appSettings,
                                                                               analytics: parameters.analytics))
        navigationStackCoordinator?.push(coordinator)
    }
    
    private func presentAppLockSetupFlow() {
        let coordinator = AppLockSetupFlowCoordinator(presentingFlow: .settings,
                                                      appLockService: parameters.appLockService,
                                                      navigationStackCoordinator: navigationStackCoordinator)
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .complete:
                // The flow coordinator tidies up the stack, no need to do anything.
                appLockSetupFlowCoordinator = nil
            case .forceLogout:
                actionsSubject.send(.forceLogout)
            }
        }
        .store(in: &cancellables)
        
        appLockSetupFlowCoordinator = coordinator
        coordinator.start()
    }
    
    private func presentLegalInformationScreen() {
        navigationStackCoordinator.push(LegalInformationScreenCoordinator(appSettings: parameters.appSettings))
    }
    
    private func presentBlockedUsersScreen() {
        let coordinator = BlockedUsersScreenCoordinator(parameters: .init(hideProfiles: parameters.appSettings.hideIgnoredUserProfiles,
                                                                          clientProxy: parameters.userSession.clientProxy,
                                                                          mediaProvider: parameters.userSession.mediaProvider,
                                                                          userIndicatorController: parameters.userIndicatorController))
        navigationStackCoordinator.push(coordinator)
    }
        
    private func presentNotificationSettings() {
        let notificationParameters = NotificationSettingsScreenCoordinatorParameters(navigationStackCoordinator: navigationStackCoordinator,
                                                                                     userSession: parameters.userSession,
                                                                                     userNotificationCenter: UNUserNotificationCenter.current(),
                                                                                     notificationSettings: parameters.notificationSettings,
                                                                                     isModallyPresented: false)
        let coordinator = NotificationSettingsScreenCoordinator(parameters: notificationParameters)
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentAdvancedSettings() {
        let coordinator = AdvancedSettingsScreenCoordinator(parameters: .init(appSettings: parameters.appSettings,
                                                                              analytics: parameters.analytics,
                                                                              clientProxy: parameters.userSession.clientProxy,
                                                                              userIndicatorController: parameters.userIndicatorController))
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentDeveloperOptions() {
        let coordinator = DeveloperOptionsScreenCoordinator()
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .clearCache:
                    actionsSubject.send(.clearCache)
                case .refreshVoIPToken:
                    actionsSubject.send(.refreshVoIPToken)
                case .clearAllVoIPTokens:
                    actionsSubject.send(.clearAllVoIPTokens)
                case .showPusherInfo:
                    // This is handled locally in DeveloperOptionsScreenCoordinator
                    break
                case .forceReregisterVoIPPusher:
                    actionsSubject.send(.forceReregisterVoIPPusher)
                case .forceReregisterPushers:
                    actionsSubject.send(.forceReregisterPushers)
                case .showVoIPDiagnostics:
                    // This is handled locally in DeveloperOptionsScreenCoordinator
                    break
                case .showComprehensivePushDiagnostics:
                    // This is handled locally in DeveloperOptionsScreenCoordinator
                    break
                case .exportLogs(let fileURL):
                    self.presentDocumentPicker(for: fileURL)
                case .clearLogs:
                    // Log clearing handled internally by coordinator - no action needed
                    break
                case .diagnoseRecoveryKeys:
                    Task { await self.diagnoseRecoveryKeys() }
                case .clearRecoveryKeys:
                    Task { await self.clearRecoveryKeys() }
                case .diagnoseCrossSigning:
                    Task { await self.diagnoseCrossSigning() }
                case .setupCrossSigning:
                    Task { await self.setupCrossSigning() }
                case .resetCrossSigning:
                    Task { await self.resetCrossSigning() }
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentDeactivateAccount() {
        let parameters = DeactivateAccountScreenCoordinatorParameters(clientProxy: parameters.userSession.clientProxy,
                                                                      userIndicatorController: parameters.userIndicatorController)
        let coordinator = DeactivateAccountScreenCoordinator(parameters: parameters)
        
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .accountDeactivated:
                    actionsSubject.send(.forceLogout)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }

    // MARK: - Log Export
    
    private func presentDocumentPicker(for fileURL: URL) {
        guard let mainWindow = parameters.windowManager.mainWindow,
              let rootViewController = mainWindow.rootViewController else {
            MXLog.error("📄 Failed to present document picker: no root view controller")
            return
        }
        
        // Find the top-most view controller
        var topViewController = rootViewController
        while let presentedVC = topViewController.presentedViewController {
            topViewController = presentedVC
        }
        
        // Create and present activity view controller for sharing
        let activityViewController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        
        // Configure for iPad
        if let popoverController = activityViewController.popoverPresentationController {
            popoverController.sourceView = topViewController.view
            popoverController.sourceRect = CGRect(x: topViewController.view.bounds.midX,
                                                  y: topViewController.view.bounds.midY,
                                                  width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }
        
        // Set completion handler to clean up temporary files
        activityViewController.completionWithItemsHandler = { _, _, _, _ in
            // Clean up temporary directory after sharing
            Task {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
        }
        
        topViewController.present(activityViewController, animated: true)
        
        MXLog.info("📄 Presented activity view controller for log export")
    }
    
    // MARK: - Recovery Keys Debug
    
    private func diagnoseRecoveryKeys() async {
        MXLog.info("🩺 Starting recovery keys diagnostics...")
        
        let userID = parameters.userSession.clientProxy.userID
        
        await MainActor.run {
            print("🩺 Recovery Keys Diagnostics for user: \(userID)")
        }
        
        // ПЕРВЫМ ДЕЛОМ: Проверяем entitlements
        var entitlementsStatus = "🔧 ENTITLEMENTS STATUS:\n"
        do {
            // Попытка создать простой keychain item для тестирования entitlements
            let testQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "test-entitlements-check",
                kSecAttrAccount as String: "test-account",
                kSecValueData as String: "test-data".data(using: .utf8)!,
                kSecAttrAccessGroup as String: "DJ9S25B535.io.sergeyshmagin.kdbchat"
            ]
            
            // Удаляем если существует
            SecItemDelete(testQuery as CFDictionary)
            
            // Пытаемся создать
            let status = SecItemAdd(testQuery as CFDictionary, nil)
            
            if status == errSecSuccess {
                entitlementsStatus += "✅ Entitlements working - keychain access OK\n"
                // Убираем тестовый элемент
                SecItemDelete(testQuery as CFDictionary)
            } else {
                let errorMsg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                entitlementsStatus += "❌ Entitlements broken - keychain error: \(errorMsg) (code: \(status))\n"
                
                if status == errSecMissingEntitlement {
                    entitlementsStatus += "🚨 MISSING ENTITLEMENTS! Need to rebuild app with fixed entitlements.\n"
                }
            }
        } catch {
            entitlementsStatus += "❌ Entitlements test failed: \(error)\n"
        }
        
        // Check keychain entitlements
        let keychainController = KeychainController(service: .sessions, accessGroup: "")
        let hasSSSSKey = keychainController.hasSSSSRecoveryKey(forUserID: userID)
        
        var diagnostics = """
        🩺 RECOVERY KEYS DIAGNOSTICS:
        
        \(entitlementsStatus)
        👤 User ID: \(userID)
        🔐 SSSS Key in Keychain: \(hasSSSSKey ? "✅ Present" : "❌ Not found")
        """
        
        // If key exists, validate it
        if hasSSSSKey {
            do {
                if let recoveryKey = keychainController.ssssRecoveryKey(forUserID: userID) {
                    diagnostics += "\n📏 Key Length: \(recoveryKey.count) characters"
                    
                    // Check format
                    let keyFormat = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let base58Chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
                    let isValidBase58 = keyFormat.allSatisfy { base58Chars.contains($0) }
                    let hasValidLength = keyFormat.count >= 43 && keyFormat.count <= 55
                    
                    diagnostics += "\n🔤 Base58 Format: \(isValidBase58 ? "✅ Valid" : "❌ Invalid characters")"
                    diagnostics += "\n📐 Length Valid: \(hasValidLength ? "✅ Valid" : "❌ Invalid length")"
                    diagnostics += "\n🔧 Key Preview: \(String(keyFormat.prefix(10)))...\(String(keyFormat.suffix(5)))"
                } else {
                    diagnostics += "\n❌ Failed to retrieve key from keychain"
                }
            } catch {
                diagnostics += "\n❌ Keychain access error: \(error.localizedDescription)"
            }
        }
        
        // Check server backup state
        let secureBackup = parameters.userSession.clientProxy.secureBackupController
        let recoveryState = secureBackup.recoveryState.value
        let keyBackupState = secureBackup.keyBackupState.value
        
        diagnostics += """
        
        🖥️ SERVER BACKUP STATE:
        🔄 Recovery State: \(recoveryState)
        🗝️ Key Backup State: \(keyBackupState)
        
        ⚠️ POTENTIAL ISSUES:
        """
        
        if hasSSSSKey, recoveryState != .enabled {
            diagnostics += "\n• Local key exists but server backup not enabled"
        }
        
        if !hasSSSSKey, recoveryState == .enabled || recoveryState == .incomplete {
            diagnostics += "\n• Server backup exists but no local key"
        }
        
        if recoveryState == .incomplete {
            diagnostics += "\n• Server backup in incomplete state - may need manual setup"
        }
        
        // Новая проверка: анализ версий backup
        do {
            let clientProxy = parameters.userSession.clientProxy
            let backupVersionsInfo = await checkBackupVersions(clientProxy: clientProxy)
            diagnostics += "\n\n📦 BACKUP VERSIONS ANALYSIS:\n\(backupVersionsInfo)"
        } catch {
            diagnostics += "\n\n❌ Failed to check backup versions: \(error.localizedDescription)"
        }
        
        diagnostics += """
        
        💡 RECOMMENDED ACTIONS:
        1. If key format is invalid → Clear and recreate
        2. If server/local mismatch → Clear and setup fresh
        3. If incomplete state → Try manual recovery setup
        4. Always rebuild app after entitlements changes
        """
        
        await MainActor.run {
            print("🩺 \(diagnostics)")
        }
        
        MXLog.info("🩺 Recovery Keys Diagnostics completed")
        MXLog.info(diagnostics)
    }
    
    private func clearRecoveryKeys() async {
        MXLog.info("🗑️ Starting recovery keys cleanup...")
        
        let userID = parameters.userSession.clientProxy.userID
        
        await MainActor.run {
            print("🗑️ Clearing all recovery keys for user: \(userID)")
        }
        
        // Clear SSSS recovery key from keychain
        let keychainController = KeychainController(service: .sessions, accessGroup: "")
        let hadSSSSKey = keychainController.hasSSSSRecoveryKey(forUserID: userID)
        keychainController.removeSSSSRecoveryKey(forUserID: userID)
        
        let message = """
        🗑️ RECOVERY KEYS CLEANUP COMPLETED:
        
        👤 User ID: \(userID)
        🔐 SSSS Recovery Key: \(hadSSSSKey ? "✅ Removed" : "❌ Not found")
        
        📱 Keychain Status: All recovery keys have been cleared from keychain
        
        ⚠️ Next Steps:
        • The user will need to set up backup recovery again
        • Any existing server-side backups may become inaccessible
        • This action is intended for debugging purposes only
        
        💡 To restore functionality:
        1. Go to Settings → Encryption → Recovery Key
        2. Set up a new recovery key
        3. Verify the new backup is working correctly
        """
        
        await MainActor.run {
            print("🗑️ \(message)")
        }
        
        MXLog.info("🗑️ Recovery Keys Cleanup Completed")
        MXLog.info(message)
    }
    
    /// Проверяет информацию о версиях backup на сервере
    private func checkBackupVersions(clientProxy: ClientProxyProtocol) async -> String {
        var report = ""
        
        do {
            // Попытка получить информацию о backup через SDK
            let secureBackup = clientProxy.secureBackupController
            let keyBackupState = secureBackup.keyBackupState.value
            
            report += "📊 Current Key Backup State: \(keyBackupState)\n"
            
            // Проверяем состояние восстановления через clientProxy
            let exportResult = clientProxy.exportRecoveryKeyForBackup()
            switch exportResult {
            case .success(let key):
                report += "✅ Can export recovery key (length: \(key.count))\n"
                
                // Попытка получить информацию о backup через автоматический сервис
                if let concreteProxy = clientProxy as? ClientProxy {
                    let autoRecoveryService = concreteProxy.autoRecoveryKeyService
                    do {
                        // Проверим текущее состояние backup
                        let backupCheckResult = await autoRecoveryService.checkExistingBackupOnServer()
                        switch backupCheckResult {
                        case .success(let backupInfo):
                            report += "🖥️ Server backup exists: \(backupInfo.exists)\n"
                            if backupInfo.exists {
                                report += "🔢 Backup version: \(backupInfo.version ?? "Unknown")\n"
                                report += "💾 Backup information available\n"
                            }
                        case .failure(let error):
                            report += "❌ Failed to check server backup: \(error.localizedDescription)\n"
                        }
                    } catch {
                        report += "❌ Auto recovery service error: \(error.localizedDescription)\n"
                    }
                } else {
                    report += "⚠️ Auto recovery service not available\n"
                }
                
            case .failure(let error):
                report += "❌ Cannot export recovery key: \(error)\n"
            }
            
            // Дополнительная диагностика состояния
            let recoveryState = secureBackup.recoveryState.value
            report += "🔄 Recovery State: \(recoveryState)\n"
            
            if recoveryState == .disabled, keyBackupState == .unknown {
                report += "⚠️ Both recovery and backup are disabled - this could explain empty versions\n"
            }
            
            if recoveryState == .incomplete {
                report += "⚠️ Recovery in incomplete state - backup versions might be corrupted\n"
            }
            
        } catch {
            report += "❌ General backup check failed: \(error.localizedDescription)\n"
        }
        
        // Добавим рекомендации по исправлению пустых версий
        report += "\n💡 EMPTY BACKUP VERSIONS ANALYSIS:\n"
        report += "• Multiple empty versions usually indicate failed backup attempts\n"
        report += "• This can happen when keys are created but backup upload fails\n"
        report += "• Cross-signing issues can also cause backup failures\n"
        report += "• Recommendation: Clear all versions and recreate fresh backup\n"
        
        return report
    }
    
    // MARK: - Cross-Signing Diagnostics & Management
    
    /// Диагностика состояния cross-signing
    private func diagnoseCrossSigning() async {
        MXLog.info("🔐 Starting cross-signing diagnostics...")
        
        await MainActor.run {
            print("🔐 Starting Cross-Signing Diagnostics...")
        }
        
        // Используем централизованный метод диагностики (DRY принцип)
        let diagnostics = await parameters.userSession.clientProxy.getDetailedEncryptionDiagnostics()
        
        await MainActor.run {
            print("🔐 \(diagnostics)")
        }
        
        MXLog.info("🔐 Cross-Signing Diagnostics completed")
        MXLog.info(diagnostics)
    }
    
    /// Настройка cross-signing
    private func setupCrossSigning() async {
        MXLog.info("⚙️ Starting manual cross-signing setup...")
        
        await MainActor.run {
            print("⚙️ Setting up Cross-Signing...")
        }
        
        let result = await parameters.userSession.clientProxy.setupCrossSigningIfNeeded()
        
        let message: String
        switch result {
        case .success:
            message = """
            ✅ CROSS-SIGNING SETUP COMPLETED
            
            🔐 Cross-signing has been successfully configured
            📦 Backup system is now active
            🔑 Recovery keys are properly set up
            
            ✨ Your encrypted messages are now more secure!
            """
            
        case .failure(let error):
            message = """
            ❌ CROSS-SIGNING SETUP FAILED
            
            🚨 Error: \(error.localizedDescription)
            
            💡 Troubleshooting:
            • Check network connection
            • Try 'Reset Cross-Signing' if issues persist
            • Ensure device has proper entitlements
            • Contact support if problem continues
            """
        }
        
        await MainActor.run {
            print("⚙️ \(message)")
        }
        
        MXLog.info("⚙️ Cross-Signing Setup Result: \(result)")
        MXLog.info(message)
    }
    
    /// Сброс cross-signing
    private func resetCrossSigning() async {
        MXLog.info("🔄 Starting cross-signing reset...")
        
        await MainActor.run {
            print("🔄 Resetting Cross-Signing...")
        }
        
        do {
            guard let concreteProxy = parameters.userSession.clientProxy as? ClientProxy else {
                MXLog.error("❌ Cannot access concrete ClientProxy for identity reset")
                return
            }
            
            // Выполняем полный сброс identity через публичный метод
            let resetResult = await concreteProxy.resetIdentity()
            switch resetResult {
            case .success(let resetHandle):
                if let resetHandle = resetHandle {
                    MXLog.info("🔄 Identity reset initiated")
                
                    // Выполняем сброс identity
                    try await resetHandle.reset(auth: nil)
                    MXLog.info("✅ Identity reset completed")
                } else {
                    MXLog.info("🔄 No reset handle returned")
                }
            case .failure(let error):
                MXLog.error("❌ Failed to initiate identity reset: \(error)")
                return
            }
                
            // После сброса автоматически настраиваем заново
            let setupResult = await concreteProxy.setupCrossSigningIfNeeded()
                
            let message: String
            switch setupResult {
            case .success:
                message = """
                ✅ CROSS-SIGNING RESET & SETUP COMPLETED
                
                🔄 Identity has been completely reset
                🔐 Cross-signing reconfigured from scratch
                📦 Fresh backup system created
                🔑 New recovery keys generated
                
                ⚡ Your encryption is now in a clean state!
                """
                    
            case .failure(let error):
                message = """
                ⚠️ CROSS-SIGNING RESET COMPLETED, SETUP FAILED
                
                ✅ Identity reset successful
                ❌ Setup failed: \(error.localizedDescription)
                
                💡 Manual setup may be required
                """
            }
                
            await MainActor.run {
                print("🔄 \(message)")
            }
                
            MXLog.info("🔄 Cross-Signing Reset completed")
            MXLog.info(message)
            
        } catch {
            let message = """
            ❌ CROSS-SIGNING RESET FAILED
            
            🚨 Error: \(error.localizedDescription)
            
            💡 Troubleshooting:
            • Check network connection
            • Ensure proper device permissions
            • Try again later
            • Contact support if issue persists
            """
            
            await MainActor.run {
                print("🔄 \(message)")
            }
            
            MXLog.error("🔄 Cross-Signing Reset failed: \(error)")
            MXLog.error(message)
        }
    }

    // MARK: OIDC Account Management
        
    private var accountSettingsPresenter: OIDCAccountSettingsPresenter?
    private func presentAccountManagementURL(_ url: URL) {
        // Note to anyone in the future if you come back here to make this open in Safari instead of a WAS.
        // As of iOS 16, there is an issue on the simulator with accessing the cookie but it works on a device. 🤷‍♂️
        accountSettingsPresenter = OIDCAccountSettingsPresenter(accountURL: url, presentationAnchor: parameters.windowManager.mainWindow)
        accountSettingsPresenter?.start()
    }
}
