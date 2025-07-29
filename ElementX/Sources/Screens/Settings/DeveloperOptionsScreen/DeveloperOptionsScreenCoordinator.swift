//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI
import UserNotifications

enum DeveloperOptionsScreenCoordinatorAction {
    case clearCache
    case refreshVoIPToken
    case clearAllVoIPTokens
    case showPusherInfo
    case forceReregisterVoIPPusher
    case showComprehensivePushDiagnostics
}

final class DeveloperOptionsScreenCoordinator: CoordinatorProtocol {
    private var viewModel: DeveloperOptionsScreenViewModelProtocol
    
    private let actionsSubject: PassthroughSubject<DeveloperOptionsScreenCoordinatorAction, Never> = .init()
    private var cancellables = Set<AnyCancellable>()
    
    var actions: AnyPublisher<DeveloperOptionsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init() {
        viewModel = DeveloperOptionsScreenViewModel(developerOptions: ServiceLocator.shared.settings,
                                                    elementCallBaseURL: ServiceLocator.shared.settings.elementCallBaseURL)
        
        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .clearCache:
                    actionsSubject.send(.clearCache)
                case .checkNotificationPermissions:
                    Task { await self.checkNotificationPermissions() }
                case .requestNotificationPermissions:
                    Task { await self.requestNotificationPermissions() }
                case .refreshVoIPToken:
                    actionsSubject.send(.refreshVoIPToken)
                case .clearAllVoIPTokens:
                    actionsSubject.send(.clearAllVoIPTokens)
                case .showPusherInfo:
                    Task { await self.showPusherInfo() }
                case .forceReregisterVoIPPusher:
                    actionsSubject.send(.forceReregisterVoIPPusher)
                case .showComprehensivePushDiagnostics:
                    Task { await self.showComprehensivePushDiagnostics() }
                }
            }
            .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(DeveloperOptionsScreen(context: viewModel.context))
    }
    
    // MARK: - Notification Permissions Debugging
    
    private func checkNotificationPermissions() async {
        let center = UNUserNotificationCenter.current()
        let authStatus = await center.authorizationStatus()
        let settings = await center.notificationSettings()
        let appSettings = ServiceLocator.shared.settings
        
        let message = """
        🔔 NOTIFICATION PERMISSIONS STATUS:
        
        📱 Authorization: \(authStatus.description)
        🎵 Sound: \(settings.soundSetting.description)
        🚨 Alert: \(settings.alertSetting.description)
        🔴 Badge: \(settings.badgeSetting.description)
        📢 Notification Center: \(settings.notificationCenterSetting.description)
        🔒 Lock Screen: \(settings.lockScreenSetting.description)
        
        ⚙️ App Settings:
        • Enable Notifications: \(appSettings?.enableNotifications ?? false)
        • Hide Badge: \(appSettings?.hideUnreadMessagesBadge ?? false)
        • Enable In-App: \(appSettings?.enableInAppNotifications ?? false)
        
        📋 Next Steps:
        \(authStatus == .authorized ? "✅ Permissions granted!" : "❌ Go to iOS Settings → [App] → Notifications")
        """
        
        await MainActor.run {
            print("📱 \(message)")
        }
        
        MXLog.info(message)
    }
    
    private func showPusherInfo() async {
        let message = """
        📱 Pusher Configuration Info:
        
        🏷️ App IDs:
        • VoIP App ID: \(ServiceLocator.shared.settings.voipAppId)
        • Regular Pusher App ID: \(ServiceLocator.shared.settings.pusherAppID)
        • Base Bundle ID: \(InfoPlistReader.main.baseBundleIdentifier)
        
        📡 Push Gateway: \(ServiceLocator.shared.settings.pushGatewayNotifyEndpoint.absoluteString)
        """
        
        await MainActor.run {
            print("📱 \(message)")
        }
        
        MXLog.info(message)
    }
    
    private func showComprehensivePushDiagnostics() async {
        // Removed PushNotificationManager reference - this functionality has been removed
        let report = "Push diagnostics not available - PushNotificationManager has been removed"
        
        await MainActor.run {
            print("🩺 \(report)")
        }
        
        MXLog.info("🩺 Comprehensive Push Diagnostics Report Generated")
        MXLog.info(report)
    }
    
    private func requestNotificationPermissions() async {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            let message = granted ?
                "✅ Notification permissions granted!" :
                "❌ Notification permissions denied. Check iOS Settings → [App] → Notifications"
                
            await MainActor.run {
                print("📱 \(message)")
            }
            
            MXLog.info("🔔 Notification permission request result: \(granted)")
            
            if granted {
                // Register for remote notifications
                // Note: NotificationManager access would need to be added to ServiceLocator
                print("📱 Would register for remote notifications here")
            }
        } catch {
            MXLog.error("🔔 Notification permission request failed: \(error)")
            
            await MainActor.run {
                print("📱 Permission Request Failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Extensions

extension UNAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: return "Not Determined"
        case .denied: return "Denied ❌"
        case .authorized: return "Authorized ✅"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
}

extension UNNotificationSetting {
    var description: String {
        switch self {
        case .notSupported: return "Not Supported"
        case .disabled: return "Disabled ❌"
        case .enabled: return "Enabled ✅"
        @unknown default: return "Unknown"
        }
    }
}
