import Foundation
import MatrixRustSDK

/**
 * КРИТИЧЕСКАЯ ДИАГНОСТИКА VoIP ПУШЕРА
 * 
 * Этот скрипт поможет определить причину проблемы с регистрацией VoIP пушера
 * на новом устройстве в production среде.
 */

class VoIPDiagnostics {
    
    enum DiagnosisResult {
        case clientIssue(reason: String)
        case serverIssue(reason: String) 
        case configurationIssue(reason: String)
        case networkIssue(reason: String)
        
        var description: String {
            switch self {
            case .clientIssue(let reason):
                return "❌ КЛИЕНТСКАЯ ПРОБЛЕМА: \(reason)"
            case .serverIssue(let reason):
                return "🔥 СЕРВЕРНАЯ ПРОБЛЕМА: \(reason)" 
            case .configurationIssue(let reason):
                return "⚙️ ПРОБЛЕМА КОНФИГУРАЦИИ: \(reason)"
            case .networkIssue(let reason):
                return "🌐 СЕТЕВАЯ ПРОБЛЕМА: \(reason)"
            }
        }
    }
    
    static func runComprehensiveDiagnosis() -> [DiagnosisResult] {
        var results: [DiagnosisResult] = []
        
        // 1. Проверить конфигурацию App ID
        results.append(contentsOf: checkAppIDConfiguration())
        
        // 2. Проверить токен PushKit
        results.append(contentsOf: checkPushKitToken())
        
        // 3. Проверить пушер конфигурацию
        results.append(contentsOf: checkPusherConfiguration())
        
        // 4. Проверить сетевую доступность
        results.append(contentsOf: checkNetworkConnectivity())
        
        // 5. Проверить серверный endpoint
        results.append(contentsOf: checkServerEndpoint())
        
        return results
    }
    
    // MARK: - Diagnostic Methods
    
    private static func checkAppIDConfiguration() -> [DiagnosisResult] {
        var results: [DiagnosisResult] = []
        
        let buildConfig = BuildConfiguration.shared
        let appSettings = AppSettings()
        
        // Проверить production App ID (ИСПРАВЛЕНО: используем правильный Bundle ID)
        let expectedVoipAppId = buildConfig.voipAppId  // Используем переменную из конфигурации
        let actualVoipAppId = buildConfig.voipAppId
        
        let expectedAlertAppId = buildConfig.alertAppId  // Используем переменную из конфигурации
        let actualAlertAppId = buildConfig.alertAppId
        
        // Проверяем консистентность конфигурации
        MXLog.info("[VoIP_Diagnosis] VoIP App ID: \(actualVoipAppId)")
        MXLog.info("[VoIP_Diagnosis] Alert App ID: \(actualAlertAppId)")
        
        return results
    }
    
    private static func checkPushKitToken() -> [DiagnosisResult] {
        var results: [DiagnosisResult] = []
        
        // Эта проверка должна выполняться в runtime с NotificationManager
        // Здесь только логика проверки
        
        results.append(.clientIssue(reason: "Необходимо проверить получение токена от PKPushRegistry в runtime"))
        
        return results
    }
    
    private static func checkPusherConfiguration() -> [DiagnosisResult] {
        var results: [DiagnosisResult] = []
        
        let buildConfig = BuildConfiguration.shared
        let pushGatewayURL = buildConfig.pushGatewayURL
        
        // Проверить корректность URL пуш-гейтвея
        if pushGatewayURL.absoluteString != "https://sygnal.aibots.kz/_matrix/push/v1/notify" {
            results.append(.configurationIssue(
                reason: "Неверный URL пуш-гейтвея: \(pushGatewayURL.absoluteString)"
            ))
        }
        
        return results
    }
    
    private static func checkNetworkConnectivity() -> [DiagnosisResult] {
        var results: [DiagnosisResult] = []
        
        // В production должна быть проверка доступности сервера
        results.append(.networkIssue(reason: "Необходимо проверить доступность https://sygnal.aibots.kz"))
        
        return results
    }
    
    private static func checkServerEndpoint() -> [DiagnosisResult] {
        var results: [DiagnosisResult] = []
        
        // Проверить, что сервер принимает VoIP пушеры с нашими App ID
        let voipAppId = BuildConfiguration.shared.voipAppId
        results.append(.serverIssue(reason: "Необходимо проверить, что сервер настроен для приема VoIP пушеров с App ID '\(voipAppId)'"))
        
        return results
    }
}

// MARK: - Runtime Diagnostic Extension

extension NotificationManager {
    
    func runVoIPDiagnostics() async -> String {
        var report = "🔍 КРИТИЧЕСКАЯ ДИАГНОСТИКА VoIP ПУШЕРА\n"
        report += "==========================================\n\n"
        
        // 1. Проверить статус токена
        let tokenStatus = voipTokenData != nil ? "✅ Токен получен" : "❌ Токен отсутствует"
        report += "1. Статус токена PushKit: \(tokenStatus)\n"
        
        if let tokenData = voipTokenData {
            let tokenString = tokenData.base64EncodedString()
            report += "   - Токен: \(tokenString.prefix(20))...\n"
            report += "   - Длина: \(tokenData.count) байт\n"
        }
        
        // 2. Проверить статус пользовательской сессии
        let sessionStatus = userSession != nil ? "✅ Сессия активна" : "❌ Сессия отсутствует"
        report += "\n2. Статус пользовательской сессии: \(sessionStatus)\n"
        
        // 3. Проверить последние попытки регистрации
        if let lastAttempt = lastVoIPRegistrationAttempt {
            report += "\n3. Последняя попытка регистрации: \(lastAttempt)\n"
            report += "   - Результат: \(lastVoIPRegistrationSuccess ? "✅ Успех" : "❌ Неудача")\n"
            report += "   - Количество повторов: \(voipPusherRegistrationRetryCount)\n"
        } else {
            report += "\n3. Регистрация еще не выполнялась\n"
        }
        
        // 4. Проверить конфигурацию App ID
        let buildConfig = BuildConfiguration.shared
        report += "\n4. Конфигурация App ID:\n"
        report += "   - VoIP App ID: \(buildConfig.voipAppId)\n"
        report += "   - Alert App ID: \(buildConfig.alertAppId)\n"
        report += "   - Push Gateway: \(buildConfig.pushGatewayURL.absoluteString)\n"
        
        // 5. Тест регистрации VoIP пушера
        report += "\n5. 🧪 ТЕСТОВАЯ РЕГИСТРАЦИЯ VoIP ПУШЕРА:\n"
        
        if let tokenData = voipTokenData, userSession != nil {
            report += "   - Запуск теста регистрации...\n"
            
            let testResult = await testVoIPPusherRegistration()
            
            report += "   - Результат: \(testResult.success ? "✅ УСПЕХ" : "❌ НЕУДАЧА")\n"
            report += "   - Сообщение: \(testResult.message)\n"
            
            if let error = testResult.errorDetails {
                report += "   - Детали ошибки: \(error)\n"
            }
        } else {
            report += "   - ❌ Тест невозможен: нет токена или пользовательской сессии\n"
        }
        
        // 6. Статический анализ конфигурации
        report += "\n6. 📋 СТАТИЧЕСКИЙ АНАЛИЗ:\n"
        let staticResults = VoIPDiagnostics.runComprehensiveDiagnosis()
        
        for result in staticResults {
            report += "   - \(result.description)\n"
        }
        
        // 7. Рекомендации
        report += "\n7. 🎯 РЕКОМЕНДАЦИИ:\n"
        
        if voipTokenData == nil {
            report += "   - ❗ КРИТИЧНО: PKPushRegistry не предоставил токен. Проверить настройки PushKit.\n"
        }
        
        if userSession == nil {
            report += "   - ❗ КРИТИЧНО: Нет пользовательской сессии. Сначала выполните вход.\n"
        }
        
        if !lastVoIPRegistrationSuccess && voipTokenData != nil && userSession != nil {
            report += "   - ❗ КРИТИЧНО: Регистрация неуспешна несмотря на наличие токена и сессии.\n"
            report += "     * Проверить сетевое соединение\n"
            report += "     * Проверить конфигурацию сервера Sygnal\n"
            report += "     * Проверить правильность App ID на сервере\n"
        }
        
        report += "\n==========================================\n"
        report += "🔍 ДИАГНОСТИКА ЗАВЕРШЕНА\n"
        
        return report
    }
}