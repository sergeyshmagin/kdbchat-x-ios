//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum DeveloperOptionsScreenCoordinatorAction {
    case clearCache
    case refreshVoIPToken
    case clearAllVoIPTokens
    case showPusherInfo
    case forceReregisterVoIPPusher
    case forceReregisterPushers
    case showVoIPDiagnostics
    case showComprehensivePushDiagnostics
    case exportLogs(URL)
    case clearLogs
    case diagnoseRecoveryKeys
    case clearRecoveryKeys
    case diagnoseCrossSigning
    case setupCrossSigning
    case resetCrossSigning
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
                case .forceReregisterPushers:
                    actionsSubject.send(.forceReregisterPushers)
                case .showVoIPDiagnostics:
                    Task { await self.showVoIPDiagnostics() }
                case .showComprehensivePushDiagnostics:
                    Task { await self.showComprehensivePushDiagnostics() }
                case .exportLogs:
                    Task { await self.exportLogs() }
                case .clearLogs:
                    Task { await self.clearAllLogs() }
                case .diagnoseRecoveryKeys:
                    actionsSubject.send(.diagnoseRecoveryKeys)
                case .clearRecoveryKeys:
                    actionsSubject.send(.clearRecoveryKeys)
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
    
    private func showVoIPDiagnostics() async {
        // For now, show basic diagnostics since NotificationManager is not in ServiceLocator
        let message = """
        🩺 VoIP PUSHER DIAGNOSTICS:
        
        📱 Configuration:
        • VoIP App ID: \(ServiceLocator.shared.settings.voipAppId)
        • Regular App ID: \(ServiceLocator.shared.settings.pusherAppID)
        • Push Gateway: \(ServiceLocator.shared.settings.pushGatewayNotifyEndpoint)
        • CallKit Integration: Required (iOS 13+)
        
        📋 Diagnostic Actions:
        1. Check Xcode console for VoIP registration logs
        2. Look for "[NotificationManager] 📲 VoIP token received"
        3. Verify "[NotificationManager] ✅ VoIP pusher registration completed"
        4. Check for retry attempts if registration failed
        
        🔍 Common Issues:
        • No token: Check provisioning profile and Apple Developer settings
        • Registration fails: Check network and Matrix server access
        • No incoming calls: Verify Sygnal configuration and CallKit integration
        • App terminated: Ensure CallKit is properly configured for VoIP pushes
        
        💡 Use "Force Re-register VoIP Pusher" to retry registration
        """
        
        await MainActor.run {
            print("🩺 \(message)")
        }
        
        MXLog.info("🩺 VoIP Diagnostics Generated")
        MXLog.info(message)
        
        // Trigger an action to show diagnostics in the logs
        actionsSubject.send(.showVoIPDiagnostics)
    }
    
    // MARK: - Log Export
    
    private func exportLogs() async {
        MXLog.info("📄 Starting log export...")
        
        do {
            // Get all log files from the tracing system
            let logFiles = Tracing.logFiles
            
            guard !logFiles.isEmpty else {
                MXLog.warning("📄 No log files found to export")
                await MainActor.run {
                    print("📄 No log files found to export")
                }
                return
            }
            
            // Create a temporary directory for the exported logs
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ElementX-Logs-\(Date().timeIntervalSince1970)")
            
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Copy all log files to the temporary directory
            var copiedFiles: [URL] = []
            for (index, logFile) in logFiles.enumerated() {
                let destinationURL = tempDir.appendingPathComponent("log-\(index)-\(logFile.lastPathComponent)")
                try FileManager.default.copyItem(at: logFile, to: destinationURL)
                copiedFiles.append(destinationURL)
            }
            
            // Create a combined log file for easier viewing
            let combinedLogURL = tempDir.appendingPathComponent("combined-logs.txt")
            var combinedContent = """
            ElementX Log Export
            Generated: \(Date())
            Bundle ID: \(InfoPlistReader.main.bundleIdentifier)
            App Version: \(InfoPlistReader.main.bundleShortVersionString) (\(InfoPlistReader.main.bundleVersion))
            Log Level: \(ServiceLocator.shared.settings.logLevel.title)
            
            === COMBINED LOGS ===
                
            """
            
            for (index, logFile) in logFiles.enumerated() {
                combinedContent += "\n=== LOG FILE \(index + 1): \(logFile.lastPathComponent) ===\n"
                if let content = try? String(contentsOf: logFile) {
                    combinedContent += content
                } else {
                    combinedContent += "[Failed to read log file]\n"
                }
                combinedContent += "\n=== END LOG FILE \(index + 1) ===\n\n"
            }
            
            try combinedContent.write(to: combinedLogURL, atomically: true, encoding: .utf8)
            copiedFiles.append(combinedLogURL)
            
            MXLog.info("📄 Successfully exported \(copiedFiles.count) log files to: \(tempDir.path)")
            
            await MainActor.run {
                print("📄 Log export completed. Files saved to: \(tempDir.path)")
                print("📄 Files exported:")
                for file in copiedFiles {
                    print("  - \(file.lastPathComponent)")
                }
            }
            
            // Send the combined log file URL for sharing
            actionsSubject.send(.exportLogs(combinedLogURL))
            
            // ВАЖНО: Очищаем оригинальные логи после успешного экспорта
            // чтобы предотвратить накопление логов и экономить место
            await clearOriginalLogFiles()
            
        } catch {
            MXLog.error("📄 Log export failed: \(error)")
            await MainActor.run {
                print("📄 Log export failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Немедленно очищает ВСЕ лог файлы (кнопка "Clear All Logs")
    private func clearAllLogs() async {
        MXLog.info("🧹 Starting manual cleanup of ALL log files...")
        
        let initialLogFiles = Tracing.logFiles
        let initialCount = initialLogFiles.count
        
        await MainActor.run {
            print("🧹 Clearing \(initialCount) log files...")
        }
        
        // Показываем размер логов перед очисткой
        var totalSize: Int64 = 0
        for logFileURL in initialLogFiles {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }
        
        let sizeInMB = Double(totalSize) / (1024.0 * 1024.0)
        MXLog.info("🧹 Total log size to clear: \(String(format: "%.1f", sizeInMB)) MB")
        
        await MainActor.run {
            print("🧹 Clearing \(String(format: "%.1f", sizeInMB)) MB of log data...")
        }
        
        // Очищаем логи
        Tracing.deleteLogFiles()
        
        // Проверяем результат
        let remainingLogFiles = Tracing.logFiles
        let clearedCount = initialCount - remainingLogFiles.count
        
        if remainingLogFiles.isEmpty {
            MXLog.info("✅ Successfully cleared ALL \(clearedCount) log files (\(String(format: "%.1f", sizeInMB)) MB freed)")
            await MainActor.run {
                print("✅ Successfully cleared ALL log files!")
                print("📊 Freed: \(String(format: "%.1f", sizeInMB)) MB")
                print("📈 Files cleared: \(clearedCount)")
            }
        } else {
            MXLog.warning("⚠️ Partially cleared logs: \(clearedCount)/\(initialCount) files cleared, \(remainingLogFiles.count) remain")
            await MainActor.run {
                print("⚠️ Warning: Only \(clearedCount) of \(initialCount) log files were cleared")
                print("❌ Remaining files:")
                for file in remainingLogFiles {
                    print("  - \(file.lastPathComponent)")
                }
            }
        }
        
        // Отправляем action для обновления UI
        actionsSubject.send(.clearLogs)
    }
    
    /// Очищает оригинальные лог файлы после успешного экспорта
    private func clearOriginalLogFiles() async {
        MXLog.info("🧹 Starting cleanup of original log files after export...")
        
        await MainActor.run {
            print("🧹 Clearing original log files to free up space...")
        }
        
        // Используем системный метод очистки логов
        Tracing.deleteLogFiles()
        
        // Проверяем результат
        let remainingLogFiles = Tracing.logFiles
        
        if remainingLogFiles.isEmpty {
            MXLog.info("🧹 Successfully cleared all original log files")
            await MainActor.run {
                print("✅ Original log files cleared successfully")
            }
        } else {
            MXLog.warning("⚠️ Some log files remain after cleanup: \(remainingLogFiles.count) files")
            await MainActor.run {
                print("⚠️ Warning: \(remainingLogFiles.count) log files could not be cleared")
                for file in remainingLogFiles {
                    print("  - \(file.lastPathComponent)")
                }
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
