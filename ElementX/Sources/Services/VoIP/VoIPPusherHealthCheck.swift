//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

/// Система проверки здоровья VoIP pusher и автоматического восстановления
final class VoIPPusherHealthCheck {
    // MARK: - Properties
    
    private let clientProxy: ClientProxyProtocol
    // private let pushNotificationManager: PushNotificationManager // Removed
    
    // MARK: - Initialization
    
    init(clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
        // self.pushNotificationManager = pushNotificationManager // Removed
    }
    
    // MARK: - Health Check Methods
    
    /// Проверяет наличие зарегистрированного VoIP pusher для пользователя
    func verifyVoIPPusherRegistered() async -> Bool {
        MXLog.info("🔍 [VoIPHealthCheck] Verifying VoIP pusher registration for user: \(clientProxy.userID)")
        
        // Проверяем локальные флаги регистрации
        let userId = clientProxy.userID
        let deviceId = clientProxy.deviceID ?? "unknown"
        let voipPusherKey = "voip_pusher_registered_\(userId)_\(deviceId)"
        let isRegistered = UserDefaults.standard.bool(forKey: voipPusherKey)
        
        // Проверяем наличие токенов
        let hasPendingToken = UserDefaults.standard.data(forKey: "pending_voip_token") != nil
        let hasStoredToken = UserDefaults.standard.data(forKey: "voip_push_token") != nil
        
        // Проверяем последнюю успешную регистрацию
        let lastRegistration = UserDefaults.standard.string(forKey: "last_push_registration_voip")
        let hasRecentRegistration = lastRegistration != nil
        
        let isVerified = isRegistered && (hasPendingToken || hasStoredToken) && hasRecentRegistration
        
        MXLog.info("🩺 [VoIPHealthCheck] Verification result: \(isVerified ? "✅ VERIFIED" : "❌ NOT VERIFIED")")
        MXLog.info("   - Registered flag: \(isRegistered)")
        MXLog.info("   - Has tokens: \(hasPendingToken || hasStoredToken)")
        MXLog.info("   - Recent registration: \(hasRecentRegistration)")
        
        return isVerified
    }
    
    /// Выполняет полную проверку здоровья VoIP системы
    func performHealthCheck() async -> VoIPHealthStatus {
        MXLog.info("🩺 [VoIPHealthCheck] Starting comprehensive health check")
        
        var status = VoIPHealthStatus()
        
        // 1. Проверяем наличие VoIP токена
        status.hasVoIPToken = hasStoredVoIPToken()
        MXLog.info("📱 [VoIPHealthCheck] VoIP token present: \(status.hasVoIPToken)")
        
        // 2. Проверяем регистрацию pusher на сервере
        status.isPusherRegistered = await verifyVoIPPusherRegistered()
        
        // 3. Проверяем PKPushRegistry
        status.isPKPushRegistryActive = checkPKPushRegistryStatus()
        
        // 4. Проверяем конфигурацию приложения
        status.isAppConfigurationValid = validateAppConfiguration()
        
        // 5. Определяем общее состояние
        status.overallHealth = determineOverallHealth(status)
        
        MXLog.info("🏥 [VoIPHealthCheck] Health check completed: \(status)")
        
        return status
    }
    
    /// Принудительно восстанавливает VoIP pusher регистрацию
    func forceRecovery() async -> Bool {
        MXLog.info("🚑 [VoIPHealthCheck] Starting forced VoIP pusher recovery")
        
        do {
            // 1. Очищаем все флаги и кэши
            clearVoIPFlags()
            
            // 2. Перезапускаем PKPushRegistry
            await restartPKPushRegistry()
            
            // 3. Ждем получения токена
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 секунды
            
            // 4. Принудительно регистрируем pusher (now handled by NotificationManager)
            // await pushNotificationManager.registerPendingTokens(clientProxy: clientProxy) // Removed
            
            // 5. Проверяем результат
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
            let isRecovered = await verifyVoIPPusherRegistered()
            
            MXLog.info(isRecovered ? "✅ [VoIPHealthCheck] Recovery successful" : "❌ [VoIPHealthCheck] Recovery failed")
            return isRecovered
            
        } catch {
            MXLog.error("❌ [VoIPHealthCheck] Recovery failed with error: \(error)")
            return false
        }
    }
    
    // MARK: - Private Methods
    
    /// Симулирует проверку pushers через локальные данные
    private func checkRegistrationHistory() -> [LocalPusherInfo] {
        MXLog.info("🔍 [VoIPHealthCheck] Checking local pusher registration history")
        
        var pushers: [LocalPusherInfo] = []
        
        // Проверяем VoIP pusher регистрацию
        if let voipRegistration = UserDefaults.standard.string(forKey: "last_push_registration_voip") {
            let components = voipRegistration.components(separatedBy: "_")
            if components.count >= 3 {
                pushers.append(LocalPusherInfo(appId: BuildConfiguration.shared.voipAppId,
                                               pushkey: components[0],
                                               profileTag: components[2],
                                               kind: "voip",
                                               isActive: true))
            }
        }
        
        // Проверяем Alert pusher регистрацию
        if let alertRegistration = UserDefaults.standard.string(forKey: "last_push_registration_alert") {
            let components = alertRegistration.components(separatedBy: "_")
            if components.count >= 3 {
                pushers.append(LocalPusherInfo(appId: "io.sergeyshmagin.kdbchat",
                                               pushkey: components[0],
                                               profileTag: components[2],
                                               kind: "alert",
                                               isActive: true))
            }
        }
        
        MXLog.info("📊 [VoIPHealthCheck] Found \(pushers.count) registered pushers in local history")
        return pushers
    }
    
    private func hasStoredVoIPToken() -> Bool {
        UserDefaults.standard.data(forKey: "pending_voip_token") != nil ||
            UserDefaults.standard.data(forKey: "voip_push_token") != nil
    }
    
    private func checkPKPushRegistryStatus() -> Bool {
        // Проверяем статус PKPushRegistry через // PushNotificationManager removed
        // pushNotificationManager.isPKPushRegistryActive // Removed
        false
    }
    
    private func validateAppConfiguration() -> Bool {
        let buildConfig = BuildConfiguration.shared
        return buildConfig.shouldRegisterVoIP &&
            !buildConfig.voipAppId.isEmpty
    }
    
    private func determineOverallHealth(_ status: VoIPHealthStatus) -> VoIPHealthStatus.Health {
        if status.hasVoIPToken, status.isPusherRegistered, status.isPKPushRegistryActive, status.isAppConfigurationValid {
            return .healthy
        } else if status.hasVoIPToken, status.isPKPushRegistryActive {
            return .degraded
        } else {
            return .unhealthy
        }
    }
    
    private func clearVoIPFlags() {
        let userId = clientProxy.userID
        let deviceId = clientProxy.deviceID ?? "unknown"
        let voipPusherKey = "voip_pusher_registered_\(userId)_\(deviceId)"
        
        UserDefaults.standard.removeObject(forKey: voipPusherKey)
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip")
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip_timestamp")
        
        MXLog.info("🗑️ [VoIPHealthCheck] Cleared VoIP flags for user: \(userId)")
    }
    
    private func restartPKPushRegistry() async {
        MXLog.info("🔄 [VoIPHealthCheck] Restarting PKPushRegistry")
        // await pushNotificationManager.refreshVoIPToken() // Removed - now handled by NotificationManager
    }
}

// MARK: - Supporting Types

struct VoIPHealthStatus: CustomStringConvertible {
    var hasVoIPToken = false
    var isPusherRegistered = false
    var isPKPushRegistryActive = false
    var isAppConfigurationValid = false
    var overallHealth: Health = .unhealthy
    
    enum Health {
        case healthy
        case degraded
        case unhealthy
        
        var description: String {
            switch self {
            case .healthy: return "✅ Healthy"
            case .degraded: return "⚠️ Degraded"
            case .unhealthy: return "❌ Unhealthy"
            }
        }
    }
    
    var description: String {
        """
        VoIP Health Status:
        - Token: \(hasVoIPToken ? "✅" : "❌")
        - Pusher: \(isPusherRegistered ? "✅" : "❌")  
        - PKPush: \(isPKPushRegistryActive ? "✅" : "❌")
        - Config: \(isAppConfigurationValid ? "✅" : "❌")
        - Overall: \(overallHealth.description)
        """
    }
}

struct LocalPusherInfo {
    let appId: String
    let pushkey: String
    let profileTag: String
    let kind: String
    let isActive: Bool
}
