//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Production-ready build configuration system for VoIP push notifications
final class BuildConfiguration {
    static let shared = BuildConfiguration()
    
    enum Environment: String, CaseIterable {
        case debug = "Debug"
        case testflight = "TestFlight" 
        case appstore = "AppStore"
        
        var displayName: String {
            switch self {
            case .debug: return "Debug"
            case .testflight: return "TestFlight"
            case .appstore: return "App Store"
            }
        }
        
        var usesProductionPush: Bool {
            switch self {
            case .debug: return false
            case .testflight, .appstore: return true
            }
        }
    }
    
    // MARK: - Environment Detection
    
    var currentEnvironment: Environment {
        #if DEBUG
        return .debug
        #elseif TESTFLIGHT
        return .testflight
        #else
        return .appstore
        #endif
    }
    
    // MARK: - VoIP Push Configuration
    
    /// VoIP App ID (одинаковый для всех сред)
    var voipAppId: String { "io.sergeyshmagin.kdbchat.voip" }
    
    /// Alert App ID (зависит от среды)
    var alertAppId: String {
        switch currentEnvironment {
        case .debug: return "io.sergeyshmagin.kdbchat.ios.debug"
        case .testflight, .appstore: return "io.sergeyshmagin.kdbchat.ios"
        }
    }
    
    /// Push Gateway URL
    var pushGatewayURL: URL {
        switch currentEnvironment {
        case .debug: return URL(string: "https://push-dev.kdbchat.io")!
        case .testflight, .appstore: return URL(string: "https://push-prod.kdbchat.io")!
        }
    }
    
    // MARK: - Registration Control
    
    /// Должен ли регистрировать VoIP push
    var shouldRegisterVoIP: Bool {
        switch currentEnvironment {
        case .debug: return true // Включено для отладки
        case .testflight, .appstore: return true // Включено для продакшна
        }
    }
    
    /// Должен ли регистрировать Alert push  
    var shouldRegisterAlert: Bool {
        switch currentEnvironment {
        case .debug: return true // Включено для отладки
        case .testflight, .appstore: return true // Включено для продакшна
        }
    }
    
    /// Включить подробное логирование push
    var enableVerbosePushLogging: Bool {
        switch currentEnvironment {
        case .debug: return true
        case .testflight: return false // Отключено для TestFlight
        case .appstore: return false // Отключено для AppStore
        }
    }
    
    // MARK: - Validation
    
    /// Проверяет конфигурацию на несовместимости
    func validateConfiguration() -> [String] {
        var warnings: [String] = []
        
        // Проверяем совместимость App ID и APNs среды
        if currentEnvironment.usesProductionPush && alertAppId.contains("debug") {
            warnings.append("Production APNs environment with debug App ID detected")
        }
        
        if !currentEnvironment.usesProductionPush && !alertAppId.contains("debug") {
            warnings.append("Sandbox APNs environment with production App ID detected")
        }
        
        // Проверяем доступность Push Gateway
        if pushGatewayURL.host?.isEmpty ?? true {
            warnings.append("Push Gateway URL host is empty")
        }
        
        return warnings
    }
    
    /// Показывает предупреждение о продакшн среде если нужно
    func showProductionWarningIfNeeded() -> String? {
        switch currentEnvironment {
        case .debug:
            return "🛠️ DEBUG: Using sandbox APNs and debug App IDs"
        case .testflight:
            return "✈️ TESTFLIGHT: Using production APNs"
        case .appstore:
            return nil // Продакшн работает без предупреждений
        }
    }
    
    // MARK: - Diagnostics
    
    func diagnosticInfo() -> String {
        let warnings = validateConfiguration()
        let warningsText = warnings.isEmpty ? "None" : warnings.joined(separator: ", ")
        
        return """
        🔧 Build Configuration Diagnostics:
        • Environment: \(currentEnvironment.displayName)
        • VoIP App ID: \(voipAppId)
        • Alert App ID: \(alertAppId)
        • Push Gateway: \(pushGatewayURL)
        • Production APNs: \(currentEnvironment.usesProductionPush)
        • VoIP Registration: \(shouldRegisterVoIP)
        • Alert Registration: \(shouldRegisterAlert)
        • Verbose Logging: \(enableVerbosePushLogging)
        • Warnings: \(warningsText)
        """
    }
}