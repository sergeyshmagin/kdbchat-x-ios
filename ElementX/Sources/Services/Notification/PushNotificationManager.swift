//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK
import CryptoKit
import PushKit
#if !IS_NSE
import UIKit
import CallKit
#endif

/// Централизованный менеджер push-уведомлений с поддержкой VoIP
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()
    
    private let appSettings: AppSettings
    private var pushRegistry: PKPushRegistry?
    #if !IS_NSE
    private var voipCallKitProvider: CXProvider?
    #endif
    
    // MARK: - Profile Tag Management
    
    /// Генерирует profile_tag в формате voip_calls_only_[device_suffix] для VoIP pushers
    private func generateVoIPProfileTag(userId: String, deviceId: String) -> String {
        // Для VoIP pushers используем специальный формат
        let deviceSuffix = String(deviceId.suffix(8))
        return "voip_calls_only_\(deviceSuffix)"
    }
    
    /// Генерирует обычный profile_tag SHA256(user_id + device_id).prefix(16) для Alert pushers
    private func generateAlertProfileTag(userId: String, deviceId: String) -> String {
        let combined = "\(userId)\(deviceId)"
        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        let hashString = hash.map { String(format: "%02hhx", $0) }.joined()
        return String(hashString.prefix(16))
    }
    
    private func getDeviceProfileTag(userId: String?, deviceId: String?, isVoIP: Bool) -> String {
        let typePrefix = isVoIP ? "voip" : "alert"
        let key = "device_profile_tag_\(typePrefix)_\(userId ?? "unknown")_\(deviceId ?? "unknown")"
        
        if let saved = UserDefaults.standard.string(forKey: key) {
            return saved
        }
        
        guard let userId = userId, let deviceId = deviceId else {
            // Fallback для случаев когда клиент еще не инициализирован
            let fallback = isVoIP ? "voip_calls_only_DEFAULT" : "device_\(UUID().uuidString.prefix(8))"
            MXLog.warning("Generated fallback profile_tag: \(fallback)")
            return String(fallback)
        }
        
        let generated = isVoIP ? generateVoIPProfileTag(userId: userId, deviceId: deviceId) 
                               : generateAlertProfileTag(userId: userId, deviceId: deviceId)
        UserDefaults.standard.set(generated, forKey: key)
        MXLog.info("Generated new \(typePrefix) profile_tag: \(generated) for user: \(userId)")
        return generated
    }
    
    // MARK: - Initialization
    
    init(appSettings: AppSettings = AppSettings()) {
        self.appSettings = appSettings
        super.init()
        setupVoIPPush()
        startVoIPEventMonitoring()
    }
    
    // MARK: - VoIP Push Setup
    
    private func setupVoIPPush() {
        #if !IS_NSE
        guard !ProcessInfo.processInfo.arguments.contains("UITesting") else {
            MXLog.info("Skipping VoIP push setup for UI testing")
            return
        }
        
        #if !IS_NSE
        // Настройка CallKit Provider
        let configuration = CXProviderConfiguration(localizedName: "kdbchat")
        configuration.supportedHandleTypes = [.generic]
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        
        voipCallKitProvider = CXProvider(configuration: configuration)
        voipCallKitProvider?.setDelegate(self, queue: nil)
        #endif
        
        #if !IS_NSE
        // Настройка PKPushRegistry
        pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
        pushRegistry?.delegate = self
        pushRegistry?.desiredPushTypes = [.voIP]
        #endif
        
        MXLog.info("📱 VoIP push setup completed")
        #endif
    }
    
    // MARK: - Push Registration
    
    /// Регистрирует pusher с Matrix homeserver
    /// - Parameters:
    ///   - pushToken: Push token от системы
    ///   - isVoIP: Тип push уведомления (VoIP или Alert)
    ///   - clientProxy: Matrix client для регистрации
    ///   - force: Принудительная регистрация (игнорировать кэш)
    func registerPusher(pushToken: Data, isVoIP: Bool, clientProxy: Any? = nil, force: Bool = false) async throws {
        #if !IS_NSE
        let buildConfig = BuildConfiguration.shared
        let tokenString = pushToken.map { String(format: "%02.2hhx", $0) }.joined()
        
        // Проверяем предупреждения окружения
        if let warning = buildConfig.showProductionWarningIfNeeded() {
            MXLog.warning("⚠️ Environment Warning: \(warning)")
        }
        
        // Проверяем настройки регистрации
        if !isVoIP && !buildConfig.shouldRegisterAlert {
            MXLog.info("🚫 Alert push registration disabled by configuration")
            return
        }
        
        if isVoIP && !buildConfig.shouldRegisterVoIP {
            MXLog.info("🚫 VoIP push registration disabled by configuration")
            return
        }
        
        guard let client = clientProxy as? ClientProxyProtocol else {
            // Сохраняем токен для регистрации после логина
            let key = isVoIP ? "pending_voip_token" : "pending_alert_token"
            UserDefaults.standard.set(pushToken, forKey: key)
            MXLog.info("💾 Saved \(isVoIP ? "VoIP" : "Alert") token for later registration")
            return
        }
        
        let userId = client.userID
        let deviceId = client.deviceID
        let appId = isVoIP ? "io.sergeyshmagin.kdbchat.voip" : buildConfig.alertAppId
        let profileTag = getDeviceProfileTag(userId: userId, deviceId: deviceId, isVoIP: isVoIP)
        
        MXLog.info("📱 Registering \(isVoIP ? "VoIP" : "Alert") pusher - App ID: \(appId), Profile: \(profileTag)")
        
        // Проверяем дубликаты регистрации (если не принудительная)
        if !force && !shouldRegisterPusher(tokenString: tokenString, isVoIP: isVoIP, appId: appId, profileTag: profileTag) {
            MXLog.info("⏭️ Skipping duplicate pusher registration")
            return
        }
        
        // Регистрируем pusher через Matrix SDK
        do {
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                                 alert: APSAlert(locKey: "Notification", locArgs: [])),
                                                pusherNotificationClientIdentifier: client.pusherNotificationClientIdentifier)
            
            let pushGatewayFullURL = isVoIP ? "https://sygnal.aibots.kz/_matrix/push/v1/notify" 
                                           : buildConfig.pushGatewayURL.appendingPathComponent("_matrix/push/v1/notify").absoluteString
            
            let configuration = try await PusherConfiguration(
                identifiers: .init(pushkey: tokenString, appId: appId),
                kind: .http(data: .init(
                    url: pushGatewayFullURL,
                    format: .eventIdOnly,
                    defaultPayload: defaultPayload.toJsonString()
                )),
                appDisplayName: InfoPlistReader.main.bundleDisplayName,
                deviceDisplayName: UIDevice.current.name,
                profileTag: profileTag,
                lang: Locale.current.languageCode ?? "en"
            )
            
            try await client.setPusher(with: configuration)
            
            updateRegistrationCache(tokenString: tokenString, isVoIP: isVoIP, appId: appId, profileTag: profileTag)
            MXLog.info("✅ Successfully registered \(isVoIP ? "VoIP" : "Alert") pusher with Matrix")
            
        } catch {
            let errorMessage = "Failed to register \(isVoIP ? "VoIP" : "Alert") pusher: \(error.localizedDescription)"
            MXLog.error("❌ \(errorMessage)")
            recordRegistrationError(errorMessage)
            throw PushError.registrationFailed(error.localizedDescription)
        }
        #endif
    }
    
    /// Удаляет pusher при логауте
    func unregisterPusher(isVoIP: Bool, clientProxy: Any) async throws {
        #if !IS_NSE
        let buildConfig = BuildConfiguration.shared
        let appId = getAppId(isVoIP: isVoIP, buildConfig: buildConfig)
        
        // Получаем последний зарегистрированный токен
        let cacheKey = "last_push_registration_\(isVoIP ? "voip" : "alert")"
        guard let lastRegistration = UserDefaults.standard.string(forKey: cacheKey),
              let tokenString = lastRegistration.components(separatedBy: "_").first else {
            MXLog.warning("⚠️ No cached token found for \(isVoIP ? "VoIP" : "Alert") pusher")
            return
        }
        
        guard let client = clientProxy as? ClientProxyProtocol else {
            throw PushError.clientNotAvailable
        }
        
        let profileTag = getDeviceProfileTag(userId: client.userID, deviceId: client.deviceID, isVoIP: isVoIP)
        
        MXLog.info("🗑️ Unregistering \(isVoIP ? "VoIP" : "Alert") pusher")
        
        do {
            // Для удаления pusher используем специальную конфигурацию с пустым URL
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                                 alert: APSAlert(locKey: "Notification", locArgs: [])),
                                                pusherNotificationClientIdentifier: client.pusherNotificationClientIdentifier)
            
            let configuration = try await PusherConfiguration(
                identifiers: .init(pushkey: tokenString, appId: appId),
                kind: .http(data: .init(
                    url: "",
                    format: .eventIdOnly,
                    defaultPayload: defaultPayload.toJsonString()
                )),
                appDisplayName: InfoPlistReader.main.bundleDisplayName,
                deviceDisplayName: UIDevice.current.name,
                profileTag: profileTag,
                lang: Locale.current.languageCode ?? "en"
            )
            
            try await client.setPusher(with: configuration)
            
            // Очищаем кэш
            UserDefaults.standard.removeObject(forKey: cacheKey)
            UserDefaults.standard.removeObject(forKey: "\(cacheKey)_timestamp")
            
            MXLog.info("✅ Successfully unregistered \(isVoIP ? "VoIP" : "Alert") pusher")
            
        } catch {
            MXLog.error("❌ Failed to unregister pusher: \(error)")
            throw PushError.registrationFailed(error.localizedDescription)
        }
        #endif
    }
    
    /// Регистрирует отложенные токены после логина
    func registerPendingTokens(clientProxy: Any) async {
        #if !IS_NSE
        var voipTokenRegistered = false
        var alertTokenRegistered = false
        
        // Регистрируем VoIP токен если есть
        if let voipToken = UserDefaults.standard.data(forKey: "pending_voip_token") {
            MXLog.info("📱 Registering pending VoIP token after login")
            do {
                try await registerPusher(pushToken: voipToken, isVoIP: true, clientProxy: clientProxy)
                UserDefaults.standard.removeObject(forKey: "pending_voip_token")
                voipTokenRegistered = true
            } catch {
                MXLog.error("❌ Failed to register pending VoIP token: \(error)")
            }
        }
        
        // Регистрируем Alert токен если есть
        if let alertToken = UserDefaults.standard.data(forKey: "pending_alert_token") {
            MXLog.info("📱 Registering pending Alert token after login")
            do {
                try await registerPusher(pushToken: alertToken, isVoIP: false, clientProxy: clientProxy)
                UserDefaults.standard.removeObject(forKey: "pending_alert_token")
                alertTokenRegistered = true
            } catch {
                MXLog.error("❌ Failed to register pending Alert token: \(error)")
            }
        }
        
        // КРИТИЧЕСКИ ВАЖНО: Принудительно регистрируем VoIP pusher для ВСЕХ пользователей
        await forceVoIPRegistration(clientProxy: clientProxy, wasTokenRegistered: voipTokenRegistered)
        #endif
    }
    
    /// Принудительная регистрация VoIP pusher для всех пользователей - УЛУЧШЕННАЯ ВЕРСИЯ
    private func forceVoIPRegistration(clientProxy: Any, wasTokenRegistered: Bool) async {
        #if !IS_NSE
        guard let client = clientProxy as? ClientProxyProtocol else {
            MXLog.error("❌ FORCE VoIP REGISTRATION - Invalid client proxy")
            return
        }
        
        MXLog.info("🚨 FORCE VoIP REGISTRATION - Starting for user: \(client.userID) (tokenRegistered: \(wasTokenRegistered))")
        
        // 1. Принудительно запрашиваем VoIP токен независимо от наличия отложенного токена
        await requestVoIPTokenForAllUsers()
        
        // 2. Ждем получения токена с постепенным увеличением времени ожидания
        var attempts = 0
        let maxAttempts = 3
        
        while attempts < maxAttempts {
            attempts += 1
            let waitTime = UInt64(attempts * 2_000_000_000) // 2, 4, 6 секунд
            try? await Task.sleep(nanoseconds: waitTime)
            
            MXLog.info("🔄 FORCE VoIP REGISTRATION - Attempt \(attempts)/\(maxAttempts)")
            
            // 3. Пытаемся зарегистрировать любой доступный VoIP токен
            var registrationSuccessful = false
            
            // Приоритет отложенному токену
            if let voipToken = UserDefaults.standard.data(forKey: "pending_voip_token") {
                MXLog.info("📱 Found pending VoIP token (attempt \(attempts)), registering...")
                do {
                    try await registerPusher(pushToken: voipToken, isVoIP: true, clientProxy: clientProxy, force: true)
                    UserDefaults.standard.removeObject(forKey: "pending_voip_token")
                    registrationSuccessful = true
                    MXLog.info("✅ Successfully registered pending VoIP pusher on attempt \(attempts)")
                } catch {
                    let errorMessage = "Failed to register pending VoIP pusher on attempt \(attempts): \(error.localizedDescription)"
                    MXLog.error("❌ \(errorMessage)")
                    recordRegistrationError(errorMessage)
                }
            }
            
            // Если pending токен не сработал, пробуем сохраненный
            if !registrationSuccessful, let storedToken = UserDefaults.standard.data(forKey: "voip_push_token") {
                MXLog.info("💾 Found stored VoIP token (attempt \(attempts)), registering...")
                do {
                    try await registerPusher(pushToken: storedToken, isVoIP: true, clientProxy: clientProxy, force: true)
                    registrationSuccessful = true
                    MXLog.info("✅ Successfully registered stored VoIP pusher on attempt \(attempts)")
                } catch {
                    let errorMessage = "Failed to register stored VoIP pusher on attempt \(attempts): \(error.localizedDescription)"
                    MXLog.error("❌ \(errorMessage)")
                    recordRegistrationError(errorMessage)
                }
            }
            
            if registrationSuccessful {
                // Отмечаем успешную регистрацию
                let voipPusherKey = "voip_pusher_registered_\(client.userID)_\(client.deviceID ?? "unknown")"
                UserDefaults.standard.set(true, forKey: voipPusherKey)
                MXLog.info("🏁 FORCE VoIP REGISTRATION - Completed successfully on attempt \(attempts)")
                return
            }
            
            // Если это не последняя попытка, запрашиваем токен снова
            if attempts < maxAttempts {
                MXLog.warning("⚠️ FORCE VoIP REGISTRATION - Attempt \(attempts) failed, retrying...")
                await requestVoIPTokenForAllUsers()
            }
        }
        
        MXLog.error("❌ FORCE VoIP REGISTRATION - Failed after \(maxAttempts) attempts")
        #endif
    }
    
    /// Принудительно запрашивает VoIP токен для всех пользователей
    private func requestVoIPTokenForAllUsers() async {
        #if !IS_NSE
        guard let registry = pushRegistry else {
            MXLog.error("❌ PKPushRegistry not available for VoIP token request")
            return
        }
        
        MXLog.info("🚨 Requesting VoIP push token for all users (force refresh)")
        
        await MainActor.run {
            // Сначала отключаем, затем включаем чтобы принудительно получить свежий токен
            registry.desiredPushTypes = []
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
        
        await MainActor.run {
            registry.desiredPushTypes = [.voIP]
        }
        
        MXLog.info("✅ VoIP token request initiated for all users")
        #endif
    }
    
    /// Принудительно запрашивает VoIP токен для нового пользователя
    private func requestVoIPTokenForNewUser() async {
        #if !IS_NSE
        guard let registry = pushRegistry else {
            MXLog.error("❌ PKPushRegistry not available for new user VoIP registration")
            return
        }
        
        MXLog.info("🆕 Requesting VoIP push token for new user")
        
        await MainActor.run {
            // Сначала отключаем, затем включаем чтобы принудительно получить токен
            registry.desiredPushTypes = []
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
        await MainActor.run {
            registry.desiredPushTypes = [.voIP]
        }
        #endif
    }
    
    private func getAppId(isVoIP: Bool, buildConfig: BuildConfiguration) -> String {
        if isVoIP {
            return buildConfig.voipAppId
        } else {
            return buildConfig.alertAppId
        }
    }
    
    // MARK: - Registration Cache
    
    private func shouldRegisterPusher(tokenString: String, isVoIP: Bool, appId: String, profileTag: String) -> Bool {
        let key = "last_push_registration_\(isVoIP ? "voip" : "alert")"
        let lastRegistration = UserDefaults.standard.string(forKey: key)
        let currentRegistration = "\(tokenString)_\(appId)_\(profileTag)"
        
        // Проверяем возраст последней регистрации (не регистрируем чаще чем раз в час)
        let timestampKey = "\(key)_timestamp"
        if let lastTimestamp = UserDefaults.standard.object(forKey: timestampKey) as? Date {
            let hourAgo = Date().addingTimeInterval(-3600) // 1 час назад
            if lastTimestamp > hourAgo && lastRegistration == currentRegistration {
                return false // Слишком недавно регистрировали тот же pusher
            }
        }
        
        return lastRegistration != currentRegistration
    }
    
    private func updateRegistrationCache(tokenString: String, isVoIP: Bool, appId: String, profileTag: String) {
        let key = "last_push_registration_\(isVoIP ? "voip" : "alert")"
        let registration = "\(tokenString)_\(appId)_\(profileTag)"
        UserDefaults.standard.set(registration, forKey: key)
        UserDefaults.standard.set(Date(), forKey: "\(key)_timestamp")
        
        MXLog.info("💾 Cached pusher registration: \(isVoIP ? "VoIP" : "Alert") - \(profileTag)")
    }
    
    // MARK: - VoIP Events Monitoring
    
    private func startVoIPEventMonitoring() {
        #if !IS_NSE
        // Мониторинг событий VoIP из NSE через App Group
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVoIPEventFromNSE(_:)),
            name: NSNotification.Name("VoIPEventFromNSE"),
            object: nil
        )
        #endif
    }
    
    @objc private func handleVoIPEventFromNSE(_ notification: Notification) {
        #if !IS_NSE
        guard let userInfo = notification.userInfo,
              let eventType = userInfo["event_type"] as? String else { return }
        
        switch eventType {
        case "m.call.invite":
            let stringUserInfo = Dictionary(uniqueKeysWithValues: userInfo.compactMap { key, value in
                if let stringKey = key as? String {
                    return (stringKey, value)
                }
                return nil
            })
            handleIncomingCallEvent(userInfo: stringUserInfo)
        case "m.call.hangup":
            let stringUserInfo = Dictionary(uniqueKeysWithValues: userInfo.compactMap { key, value in
                if let stringKey = key as? String {
                    return (stringKey, value)
                }
                return nil
            })
            handleCallHangupEvent(userInfo: stringUserInfo)
        default:
            break
        }
        #endif
    }
    
    private func handleIncomingCallEvent(userInfo: [String: Any]) {
        #if !IS_NSE
        guard let callId = userInfo["call_id"] as? String,
              let roomId = userInfo["room_id"] as? String else { return }
        
        // Извлекаем имя звонящего с улучшенным алгоритмом
        let callerInfo = extractCallerInfoFromUserInfo(userInfo)
        MXLog.info("📞 Handling incoming call from: \(callerInfo.displayName)")
        
        Task {
            #if LIVEKIT_ENABLED
            // Интеграция с LiveKit CallKit Service
            await LiveKitCallKitService.shared.handleIncomingCallFromMatrix(
                roomId: roomId,
                callId: callId,
                callerName: callerInfo.displayName
            )
            #else
            // Fallback CallKit implementation
            let callUUID = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: callId)
            update.localizedCallerName = callerInfo.displayName
            update.hasVideo = userInfo["is_video"] as? Bool ?? false
            
            voipCallKitProvider?.reportNewIncomingCall(with: callUUID, update: update) { error in
                if let error = error {
                    MXLog.error("❌ CallKit error: \(error)")
                } else {
                    MXLog.info("✅ CallKit incoming call reported with caller: \(callerInfo.displayName)")
                }
            }
            #endif
        }
        #endif
    }
    
    /// Извлекает информацию о звонящем из userInfo с множественными fallback вариантами
    private func extractCallerInfoFromUserInfo(_ userInfo: [String: Any]) -> (senderId: String, displayName: String) {
        let senderId = userInfo["sender_id"] as? String ?? userInfo["sender"] as? String ?? ""
        var displayName = "Unknown Caller"
        
        // 1. Прямое извлечение из caller_name
        if let callerName = userInfo["caller_name"] as? String, !callerName.isEmpty {
            displayName = callerName
            MXLog.info("✅ Extracted caller name from caller_name: \(displayName)")
        }
        // 2. Из sender_display_name
        else if let senderDisplayName = userInfo["sender_display_name"] as? String, !senderDisplayName.isEmpty {
            displayName = senderDisplayName
            MXLog.info("✅ Extracted caller name from sender_display_name: \(displayName)")
        }
        // 3. Из room_name
        else if let roomName = userInfo["room_name"] as? String, !roomName.isEmpty,
                roomName != userInfo["room_id"] as? String {
            displayName = roomName
            MXLog.info("✅ Using room name as caller name: \(displayName)")
        }
        // 4. Извлечение из Matrix User ID
        else if senderId.hasPrefix("@") {
            if let atIndex = senderId.firstIndex(of: "@"),
               let colonIndex = senderId.firstIndex(of: ":") {
                let username = String(senderId[senderId.index(after: atIndex)..<colonIndex])
                displayName = username.capitalized
                MXLog.info("✅ Extracted username from Matrix ID: \(displayName)")
            }
        }
        else {
            MXLog.warning("⚠️ Could not extract caller name, using fallback: \(displayName)")
        }
        
        return (senderId: senderId, displayName: displayName)
    }
    
    private func handleCallHangupEvent(userInfo: [String: Any]) {
        #if !IS_NSE
        guard let callId = userInfo["call_id"] as? String else { return }
        
        // Завершаем CallKit call
        // Реализация зависит от текущей архитектуры CallKit
        MXLog.info("📞 Call hangup received for call: \(callId)")
        #endif
    }
    
    // MARK: - VoIP Token Management
    
    func refreshVoIPToken() async {
        #if !IS_NSE
        MXLog.info("🔄 Refreshing VoIP push token")
        
        // Clear cached registration to force refresh
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip")
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip_timestamp")
        
        // Re-enable VoIP push registration to get new token
        guard let registry = pushRegistry else {
            MXLog.error("❌ PKPushRegistry not available for token refresh")
            return
        }
        
        await MainActor.run {
            registry.desiredPushTypes = []
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        await MainActor.run {
            registry.desiredPushTypes = [.voIP]
        }
        #endif
    }
    
    func clearAllVoIPTokens() async {
        #if !IS_NSE
        MXLog.info("🗑️ Clearing all VoIP tokens and cache")
        
        // Clear all VoIP-related UserDefaults
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip")
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip_timestamp")
        UserDefaults.standard.removeObject(forKey: "pending_voip_token")
        
        // Clear device profile tags (force regeneration)
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys
        for key in keys {
            if key.hasPrefix("device_profile_tag_") {
                defaults.removeObject(forKey: key)
            }
        }
        
        // Force complete VoIP push re-registration
        await refreshVoIPToken()
        #endif
    }
    
    // MARK: - Diagnostics
    
    /// Current device profile tag for diagnostics
    var deviceVoIPProfileTag: String {
        return getDeviceProfileTag(userId: "current", deviceId: "device", isVoIP: true)
    }
    
    var deviceAlertProfileTag: String {
        return getDeviceProfileTag(userId: "current", deviceId: "device", isVoIP: false)
    }
    
    /// Проверяет статус PKPushRegistry
    var isPKPushRegistryActive: Bool {
        #if !IS_NSE
        guard let registry = pushRegistry else { return false }
        return registry.desiredPushTypes?.contains(.voIP) == true
        #else
        return false
        #endif
    }
    
    /// Выполняет комплексную проверку здоровья VoIP системы
    func performVoIPHealthCheck(for userSession: Any) async -> VoIPHealthStatus {
        #if !IS_NSE
        guard let client = userSession as? ClientProxyProtocol else {
            MXLog.error("❌ [VoIPHealthCheck] Invalid client proxy")
            return VoIPHealthStatus(
                hasVoIPToken: false,
                isPusherRegistered: false,
                isPKPushRegistryActive: false,
                isAppConfigurationValid: false,
                overallHealth: .unhealthy
            )
        }
        
        MXLog.info("🩺 [VoIPHealthCheck] Starting comprehensive health check for user: \(client.userID)")
        
        var status = VoIPHealthStatus()
        
        // 1. Проверяем наличие VoIP токена
        status.hasVoIPToken = UserDefaults.standard.data(forKey: "pending_voip_token") != nil ||
                              UserDefaults.standard.data(forKey: "voip_push_token") != nil
        
        // 2. Проверяем регистрацию pusher на сервере (локальная проверка)
        let userId = client.userID
        let deviceId = client.deviceID ?? "unknown"
        let voipPusherKey = "voip_pusher_registered_\(userId)_\(deviceId)"
        let isRegistered = UserDefaults.standard.bool(forKey: voipPusherKey)
        let hasRecentRegistration = UserDefaults.standard.string(forKey: "last_push_registration_voip") != nil
        status.isPusherRegistered = isRegistered && hasRecentRegistration
        
        // 3. Проверяем PKPushRegistry
        status.isPKPushRegistryActive = isPKPushRegistryActive
        
        // 4. Проверяем конфигурацию приложения
        let buildConfig = BuildConfiguration.shared
        status.isAppConfigurationValid = buildConfig.shouldRegisterVoIP && 
                                       buildConfig.voipAppId == "io.sergeyshmagin.kdbchat.voip"
        
        // 5. Определяем общее состояние
        if status.hasVoIPToken && status.isPusherRegistered && status.isPKPushRegistryActive && status.isAppConfigurationValid {
            status.overallHealth = .healthy
        } else if status.hasVoIPToken && status.isPKPushRegistryActive {
            status.overallHealth = .degraded
        } else {
            status.overallHealth = .unhealthy
        }
        
        MXLog.info("🏥 [VoIPHealthCheck] Health check completed: \(status)")
        return status
        #else
        return VoIPHealthStatus(
            hasVoIPToken: false,
            isPusherRegistered: false,
            isPKPushRegistryActive: false,
            isAppConfigurationValid: false,
            overallHealth: .unhealthy
        )
        #endif
    }
    
    /// Принудительно восстанавливает VoIP pusher регистрацию
    func forceVoIPRecovery(for userSession: Any) async -> Bool {
        #if !IS_NSE
        guard let client = userSession as? ClientProxyProtocol else {
            MXLog.error("❌ [VoIPHealthCheck] Invalid client proxy for recovery")
            return false
        }
        
        MXLog.info("🚑 [VoIPHealthCheck] Starting forced VoIP pusher recovery for user: \(client.userID)")
        
        do {
            // 1. Очищаем все флаги и кэши
            let userId = client.userID
            let deviceId = client.deviceID ?? "unknown"
            let voipPusherKey = "voip_pusher_registered_\(userId)_\(deviceId)"
            
            UserDefaults.standard.removeObject(forKey: voipPusherKey)
            UserDefaults.standard.removeObject(forKey: "last_push_registration_voip")
            UserDefaults.standard.removeObject(forKey: "last_push_registration_voip_timestamp")
            
            MXLog.info("🗑️ [VoIPHealthCheck] Cleared VoIP flags for user: \(userId)")
            
            // 2. Перезапускаем PKPushRegistry
            await refreshVoIPToken()
            
            // 3. Ждем получения токена
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 секунды
            
            // 4. Принудительно регистрируем pusher
            await registerPendingTokens(clientProxy: client)
            
            // 5. Проверяем результат
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
            let finalStatus = await performVoIPHealthCheck(for: client)
            let isRecovered = finalStatus.overallHealth != .unhealthy
            
            if isRecovered {
                UserDefaults.standard.set(true, forKey: voipPusherKey)
            }
            
            MXLog.info(isRecovered ? "✅ [VoIPHealthCheck] Recovery successful" : "❌ [VoIPHealthCheck] Recovery failed")
            return isRecovered
            
        } catch {
            MXLog.error("❌ [VoIPHealthCheck] Recovery failed with error: \(error)")
            return false
        }
        #else
        return false
        #endif
    }
    
    /// Генерирует полный диагностический отчет для пользователя
    func generateComprehensiveDiagnosticsReport(for userSession: Any? = nil) async -> String {
        #if !IS_NSE
        let buildConfig = BuildConfiguration.shared
        var client: ClientProxyProtocol?
        
        if let session = userSession as? ClientProxyProtocol {
            client = session
        }
        
        // Basic system info
        let hasPendingVoIPToken = UserDefaults.standard.data(forKey: "pending_voip_token") != nil
        let hasStoredVoIPToken = UserDefaults.standard.data(forKey: "voip_push_token") != nil
        let lastVoIPRegistration = UserDefaults.standard.string(forKey: "last_push_registration_voip")
        let lastVoIPTimestamp = UserDefaults.standard.object(forKey: "last_push_registration_voip_timestamp") as? Date
        let lastRegistrationError = UserDefaults.standard.string(forKey: "last_push_registration_error")
        
        // Health check
        var healthStatus = VoIPHealthStatus()
        if let client = client {
            healthStatus = await performVoIPHealthCheck(for: client)
        }
        
        // Registration history
        let registrationHistory = getRegistrationHistory()
        
        let report = """
        📱 COMPREHENSIVE PUSH DIAGNOSTICS REPORT
        ==========================================
        
        👤 User Information:
        • User ID: \(client?.userID ?? "Not logged in")
        • Device ID: \(client?.deviceID ?? "Unknown")
        • Report Generated: \(Date().description)
        
        🏥 VoIP Health Status:
        \(healthStatus.description)
        
        🔑 Token Status:
        • Pending VoIP Token: \(hasPendingVoIPToken ? "✅ Present" : "❌ Missing")
        • Stored VoIP Token: \(hasStoredVoIPToken ? "✅ Present" : "❌ Missing")
        • PKPushRegistry Active: \(isPKPushRegistryActive ? "✅ Active" : "❌ Inactive")
        
        📊 Registration History:
        • Last VoIP Registration: \(lastVoIPRegistration ?? "Never")
        • Last Registration Time: \(lastVoIPTimestamp?.description ?? "Never")
        • Last Error: \(lastRegistrationError ?? "None")
        
        🏷️ Configuration:
        • VoIP Profile Tag: \(deviceVoIPProfileTag)
        • Alert Profile Tag: \(deviceAlertProfileTag)
        • VoIP App ID: \(buildConfig.voipAppId)
        • Alert App ID: \(buildConfig.alertAppId)
        • Push Gateway: \(buildConfig.pushGatewayURL)
        • Environment: \(buildConfig.currentEnvironment.displayName)
        • Production APNs: \(buildConfig.currentEnvironment.usesProductionPush)
        
        ⚙️ System Status:
        • VoIP Registration Enabled: \(buildConfig.shouldRegisterVoIP ? "✅" : "❌")
        • Alert Registration Enabled: \(buildConfig.shouldRegisterAlert ? "✅" : "❌")
        • Verbose Logging: \(buildConfig.enableVerbosePushLogging ? "✅" : "❌")
        
        📝 Registration History:
        \(registrationHistory)
        
        🔧 Troubleshooting:
        \(generateTroubleshootingAdvice(healthStatus: healthStatus))
        
        ⚠️ Configuration Warnings:
        \(buildConfig.validateConfiguration().isEmpty ? "None" : buildConfig.validateConfiguration().joined(separator: "\n"))
        """
        
        return report
        #else
        return "📱 NSE Context - Limited diagnostics available"
        #endif
    }
    
    func getDiagnosticsInfo() -> String {
        #if !IS_NSE
        let buildConfig = BuildConfiguration.shared
        #else
        return "📱 NSE Push Notification Manager - Limited diagnostics in NSE context"
        #endif
        
        #if !IS_NSE
        // Token diagnostics
        let hasPendingVoIPToken = UserDefaults.standard.data(forKey: "pending_voip_token") != nil
        let hasStoredVoIPToken = UserDefaults.standard.data(forKey: "voip_push_token") != nil
        let lastVoIPRegistration = UserDefaults.standard.string(forKey: "last_push_registration_voip")
        let lastVoIPTimestamp = UserDefaults.standard.object(forKey: "last_push_registration_voip_timestamp") as? Date
        
        var info = """
        📱 Push Notification Manager Diagnostics:
        
        🏷️ VoIP Profile Tag: \(deviceVoIPProfileTag)
        🏷️ Alert Profile Tag: \(deviceAlertProfileTag)
        📦 VoIP App ID: \(buildConfig.voipAppId)
        📨 Alert App ID: \(buildConfig.alertAppId)
        🌐 Push Gateway: \(buildConfig.pushGatewayURL)
        🔧 Environment: \(buildConfig.currentEnvironment.displayName)
        📡 Production APNs: \(buildConfig.currentEnvironment.usesProductionPush)
        📱 PKPushRegistry Active: \(isPKPushRegistryActive)
        
        🔑 Token Status:
        • Pending VoIP Token: \(hasPendingVoIPToken ? "✅" : "❌")
        • Stored VoIP Token: \(hasStoredVoIPToken ? "✅" : "❌")
        • Last VoIP Registration: \(lastVoIPRegistration ?? "None")
        • Last Registration Time: \(lastVoIPTimestamp?.description ?? "Never")
        
        ⚙️ Registration Status:
        • VoIP Enabled: \(buildConfig.shouldRegisterVoIP)
        • Alert Enabled: \(buildConfig.shouldRegisterAlert)
        • Verbose Logging: \(buildConfig.enableVerbosePushLogging)
        """
        
        info += "\n\(buildConfig.diagnosticInfo())\n"
        
        let warnings = buildConfig.validateConfiguration()
        if !warnings.isEmpty {
            info += "\n⚠️ Configuration Warnings:\n"
            for warning in warnings {
                info += "• \(warning)\n"
            }
        }
        
        return info
        #endif
    }
    
    /// Записывает ошибку регистрации для диагностики
    func recordRegistrationError(_ error: String) {
        UserDefaults.standard.set(error, forKey: "last_push_registration_error")
        UserDefaults.standard.set(Date(), forKey: "last_push_registration_error_timestamp")
        
        // Ведем историю последних 10 ошибок
        var errorHistory = UserDefaults.standard.stringArray(forKey: "push_registration_error_history") ?? []
        let errorEntry = "\(Date().description): \(error)"
        errorHistory.append(errorEntry)
        
        // Оставляем только последние 10 записей
        if errorHistory.count > 10 {
            errorHistory = Array(errorHistory.suffix(10))
        }
        
        UserDefaults.standard.set(errorHistory, forKey: "push_registration_error_history")
        MXLog.error("📝 Recorded push registration error: \(error)")
    }
    
    /// Получает историю регистрации для диагностики
    private func getRegistrationHistory() -> String {
        let errorHistory = UserDefaults.standard.stringArray(forKey: "push_registration_error_history") ?? []
        
        if errorHistory.isEmpty {
            return "No registration errors recorded"
        }
        
        return errorHistory.joined(separator: "\n")
    }
    
    /// Генерирует советы по устранению неполадок
    private func generateTroubleshootingAdvice(healthStatus: VoIPHealthStatus) -> String {
        var advice: [String] = []
        
        if healthStatus.overallHealth == .unhealthy {
            advice.append("🚨 CRITICAL: VoIP push notifications are not working")
            
            if !healthStatus.hasVoIPToken {
                advice.append("• Problem: No VoIP token available")
                advice.append("  Solution: Try force re-registering VoIP pusher in Developer Options")
            }
            
            if !healthStatus.isPusherRegistered {
                advice.append("• Problem: VoIP pusher not registered with Matrix server")
                advice.append("  Solution: Check network connection and try force re-registration")
            }
            
            if !healthStatus.isPKPushRegistryActive {
                advice.append("• Problem: PKPushRegistry not active")
                advice.append("  Solution: Restart the app and check iOS notification permissions")
            }
            
            if !healthStatus.isAppConfigurationValid {
                advice.append("• Problem: App configuration invalid")
                advice.append("  Solution: Contact app developer - configuration issue")
            }
        } else if healthStatus.overallHealth == .degraded {
            advice.append("⚠️ WARNING: VoIP push notifications partially working")
            advice.append("• Try force re-registering VoIP pusher to improve reliability")
        } else {
            advice.append("✅ SUCCESS: VoIP push notifications are working correctly")
        }
        
        return advice.isEmpty ? "No specific advice available" : advice.joined(separator: "\n")
    }
}

// MARK: - PKPushRegistryDelegate

extension PushNotificationManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        #if !IS_NSE
        guard type == .voIP else { return }
        
        let tokenString = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        MXLog.info("📱 VoIP push token updated: \(tokenString.prefix(16))...")
        
        // Сразу сохраняем токен для использования
        UserDefaults.standard.set(pushCredentials.token, forKey: "voip_push_token")
        UserDefaults.standard.set(pushCredentials.token, forKey: "pending_voip_token")
        MXLog.info("💾 Stored VoIP token for registration")
        
        Task {
            do {
                try await registerPusher(pushToken: pushCredentials.token, isVoIP: true)
                MXLog.info("✅ VoIP pusher registered immediately after token update")
            } catch {
                MXLog.error("❌ Failed to register VoIP pusher: \(error)")
                // Токен уже сохранен в pending, будет зарегистрирован позже
            }
        }
        #endif
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        #if !IS_NSE
        guard type == .voIP else {
            completion()
            return
        }
        
        MXLog.info("📞 Received VoIP push notification")
        MXLog.info("📋 VoIP push payload: \(payload.dictionaryPayload)")
        
        // Извлекаем данные о звонке из payload
        let payloadDict = payload.dictionaryPayload
        let callerInfo = extractCallerInfoFromPayload(payloadDict)
        
        // КРИТИЧЕСКИ ВАЖНО: немедленно отчитываемся CallKit о входящем звонке
        let callUUID = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerInfo.senderId)
        update.localizedCallerName = callerInfo.displayName // ← ПРАВИЛЬНОЕ ИМЯ ЗВОНЯЩЕГО
        update.hasVideo = payloadDict["is_video"] as? Bool ?? true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        
        MXLog.info("📞 Reporting incoming call from: '\(callerInfo.displayName)' (VoIP Push)")
        
        #if !IS_NSE
        voipCallKitProvider?.reportNewIncomingCall(with: callUUID, update: update) { error in
            if let error = error {
                MXLog.error("❌ CallKit error: \(error)")
                completion()
            } else {
                MXLog.info("✅ CallKit incoming call reported successfully for: \(callerInfo.displayName)")
                
                #if LIVEKIT_ENABLED
                // Интеграция с LiveKit CallKit Service для дальнейшей обработки
                LiveKitCallKitService.shared.handleVoIPPush(payload: payload, completion: completion)
                #else
                completion()
                #endif
            }
        }
        #else
        completion()
        #endif
        #endif
    }
    
    /// Извлекает информация о звонящем из VoIP push payload
    private func extractCallerInfoFromPayload(_ payload: [AnyHashable: Any]) -> (senderId: String, displayName: String) {
        let senderId = payload["sender"] as? String ?? ""
        var displayName = "Incoming Call"
        
        // 1. Прямое извлечение из sender_display_name
        if let senderDisplayName = payload["sender_display_name"] as? String, !senderDisplayName.isEmpty {
            displayName = senderDisplayName
            MXLog.info("✅ [VoIP] Extracted caller name from sender_display_name: \(displayName)")
        }
        // 2. Из content.sender_display_name
        else if let content = payload["content"] as? [String: Any],
                let senderDisplayName = content["sender_display_name"] as? String, !senderDisplayName.isEmpty {
            displayName = senderDisplayName
            MXLog.info("✅ [VoIP] Extracted caller name from content.sender_display_name: \(displayName)")
        }
        // 3. Из room_name
        else if let roomName = payload["room_name"] as? String, !roomName.isEmpty,
                roomName != payload["room_id"] as? String {
            displayName = roomName
            MXLog.info("✅ [VoIP] Using room name as caller name: \(displayName)")
        }
        // 4. Извлечение из Matrix User ID (@testuser1:domain → Testuser1)
        else if senderId.hasPrefix("@") {
            if let atIndex = senderId.firstIndex(of: "@"),
               let colonIndex = senderId.firstIndex(of: ":") {
                let username = String(senderId[senderId.index(after: atIndex)..<colonIndex])
                displayName = username.capitalized
                MXLog.info("✅ [VoIP] Extracted username from Matrix ID: \(displayName)")
            } else {
                displayName = String(senderId.dropFirst()).capitalized
                MXLog.info("✅ [VoIP] Fallback username extraction: \(displayName)")
            }
        }
        // 5. Из nested event content
        else if let content = payload["content"] as? [String: Any],
                let eventContent = content["event"] as? [String: Any],
                let sender = eventContent["sender"] as? String, sender.hasPrefix("@") {
            if let atIndex = sender.firstIndex(of: "@"),
               let colonIndex = sender.firstIndex(of: ":") {
                let username = String(sender[sender.index(after: atIndex)..<colonIndex])
                displayName = username.capitalized
                MXLog.info("✅ [VoIP] Extracted from nested event sender: \(displayName)")
            }
        }
        else {
            MXLog.warning("⚠️ [VoIP] Could not extract caller name from payload, using fallback: \(displayName)")
        }
        
        return (senderId: senderId, displayName: displayName)
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        #if !IS_NSE
        guard type == .voIP else { return }
        
        MXLog.warning("⚠️ VoIP push token invalidated - starting recovery")
        
        // Очищаем все связанные с токеном данные
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip")
        UserDefaults.standard.removeObject(forKey: "last_push_registration_voip_timestamp")
        UserDefaults.standard.removeObject(forKey: "voip_push_token")
        UserDefaults.standard.removeObject(forKey: "pending_voip_token")
        
        // Принудительно запрашиваем новый токен
        Task {
            await requestVoIPTokenForAllUsers()
            MXLog.info("🔄 Requested new VoIP token after invalidation")
        }
        #endif
    }
}

// MARK: - CXProviderDelegate

#if !IS_NSE
extension PushNotificationManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        MXLog.info("📞 CallKit provider reset")
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MXLog.info("📞 User answered call")
        
        #if LIVEKIT_ENABLED
        // Интеграция с LiveKit
        Task {
            // LiveKitCallKitService doesn't have answerCall method, CallKit handles this internally
            action.fulfill()
        }
        #else
        action.fulfill()
        #endif
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MXLog.info("📞 User ended call")
        
        #if LIVEKIT_ENABLED
        // Интеграция с LiveKit
        Task {
            try? await LiveKitCallKitService.shared.endCall(callUUID: action.callUUID)
            action.fulfill()
        }
        #else
        action.fulfill()
        #endif
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }
}
#endif

// MARK: - VoIP Health Status

struct VoIPHealthStatus: CustomStringConvertible {
    var hasVoIPToken: Bool = false
    var isPusherRegistered: Bool = false
    var isPKPushRegistryActive: Bool = false
    var isAppConfigurationValid: Bool = false
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
        return """
        VoIP Health Status:
        - Token: \(hasVoIPToken ? "✅" : "❌")
        - Pusher: \(isPusherRegistered ? "✅" : "❌")  
        - PKPush: \(isPKPushRegistryActive ? "✅" : "❌")
        - Config: \(isAppConfigurationValid ? "✅" : "❌")
        - Overall: \(overallHealth.description)
        """
    }
}

// MARK: - Error Types

enum PushError: Error {
    case clientNotAvailable
    case invalidToken
    case registrationFailed(String)
    case duplicateRegistration
}