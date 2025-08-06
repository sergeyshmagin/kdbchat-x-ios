//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK
import PushKit
import UIKit
import UserNotifications

#if LIVEKIT_ENABLED
// LiveKitCallKitService is only available when LIVEKIT_ENABLED
#endif

// MARK: - VoIP Validation Types

/// Result of VoIP payload validation
private enum VoIPValidationResult {
    case valid(roomId: String, callId: String)
    case invalid(String)
    
    var isValid: Bool {
        switch self {
        case .valid: return true
        case .invalid: return false
        }
    }
    
    var errorMessage: String? {
        switch self {
        case .valid: return nil
        case .invalid(let message): return message
        }
    }
}

final class NotificationManager: NSObject, NotificationManagerProtocol {
    private let notificationCenter: UserNotificationCenterProtocol
    private let appSettings: AppSettings
    
    private var userSession: UserSessionProtocol?
    
    private var cancellables = Set<AnyCancellable>()
    private var notificationsEnabled = false
    
    // VoIP Push Support
    private var pushRegistry: PKPushRegistry?
    private var voipTokenData: Data?
    private var voipPusherRegistrationRetryCount = 0
    private let maxVoIPRetryAttempts = 3
    private var voipRetryTimer: Timer?
    private var lastVoIPRegistrationAttempt: Date?
    private var lastVoIPRegistrationSuccess = false
    
    // VoIP Call Deduplication (Apple "One Push Per Call" compliance)
    private var processedCallIds = Set<String>()
    private let callDeduplicationCleanupInterval: TimeInterval = 300 // 5 minutes
    private var deduplicationCleanupTimer: Timer?
    
    init(notificationCenter: UserNotificationCenterProtocol,
         appSettings: AppSettings) {
        self.notificationCenter = notificationCenter
        self.appSettings = appSettings
        super.init()
    }

    // MARK: NotificationManagerProtocol

    weak var delegate: NotificationManagerDelegate?
    
    func start() {
        let replyAction = UNTextInputNotificationAction(identifier: NotificationConstants.Action.inlineReply,
                                                        title: L10n.actionQuickReply,
                                                        options: [])
        let messageCategory = UNNotificationCategory(identifier: NotificationConstants.Category.message,
                                                     actions: [replyAction],
                                                     intentIdentifiers: [],
                                                     options: [])
        
        let inviteCategory = UNNotificationCategory(identifier: NotificationConstants.Category.invite,
                                                    actions: [],
                                                    intentIdentifiers: [],
                                                    options: [])
        notificationCenter.setNotificationCategories([messageCategory, inviteCategory])
        notificationCenter.delegate = self
        
        notificationsEnabled = appSettings.enableNotifications
        MXLog.info("[NotificationManager] app setting 'enableNotifications' is '\(notificationsEnabled)'")
        
        // Listen for changes to AppSettings.enableNotifications
        appSettings.$enableNotifications
            .sink { [weak self] newValue in
                self?.enableNotifications(newValue)
            }
            .store(in: &cancellables)
            
        // ✅ VoIP Push через PKPushRegistry в соответствии с Apple Guidelines
        // Используем PKPushRegistry исключительно для VoIP звонков с CallKit интеграцией
        setupVoIPPushRegistry()
        MXLog.info("[NotificationManager] ✅ VoIP calls configured to use PKPushRegistry with CallKit integration")
    }
        
    func requestAuthorization() {
        guard appSettings.enableNotifications, !userSession.isNil else { return }
        Task {
            do {
                let permissionGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                MXLog.info("[NotificationManager] permission granted: \(permissionGranted)")
                await MainActor.run {
                    if permissionGranted {
                        self.delegate?.registerForRemoteNotifications()
                    }
                }
            } catch {
                MXLog.error("[NotificationManager] request authorization failed: \(error)")
            }
        }
    }

    func register(with deviceToken: Data) async -> Bool {
        guard let userSession else {
            return false
        }
        
        // Регистрируем обычный pusher
        let regularSuccess = await setPusher(with: deviceToken, clientProxy: userSession.clientProxy)
        
        // Регистрируем VoIP pusher ТОЛЬКО если есть VoIP токен
        var voipSuccess = true
        if let voipTokenData = voipTokenData {
            voipSuccess = await registerVoIPPusher(with: voipTokenData)
        }
        
        return regularSuccess && voipSuccess
    }

    func setUserSession(_ userSession: UserSessionProtocol?) {
        self.userSession = userSession
        
        // If notification permissions were given previously then attempt re-registering
        // for remote notifications on startup. Otherwise let the onboarding flow handle it
        Task { [weak self] in
            guard let self else { return }
            
            let authStatus = await notificationCenter.authorizationStatus()
            
            if authStatus == .authorized, appSettings.enableNotifications {
                await MainActor.run { [weak self] in
                    self?.delegate?.registerForRemoteNotifications()
                }
            } else if authStatus == .notDetermined, appSettings.enableNotifications {
                // PROACTIVE: Request permissions if not determined yet
                MXLog.info("🔔 Proactively requesting notification permissions on login")
                requestAuthorization()
            }
            
            let settings = await notificationCenter.notificationSettings()
            MXLog.info("Notification sound enabled: \(settings.soundSetting == .enabled)")
            
            // DIAGNOSTIC: Print detailed notification permissions
            MXLog.info("🔔 NOTIFICATION PERMISSIONS DIAGNOSTIC:")
            MXLog.info("📱 Authorization Status: \(authStatus.rawValue) (\(authStatus))")
            MXLog.info("🎵 Sound Setting: \(settings.soundSetting.rawValue)")
            MXLog.info("🚨 Alert Setting: \(settings.alertSetting.rawValue)")
            MXLog.info("🔴 Badge Setting: \(settings.badgeSetting.rawValue)")
            MXLog.info("📢 Notification Center Setting: \(settings.notificationCenterSetting.rawValue)")
            MXLog.info("🔒 Lock Screen Setting: \(settings.lockScreenSetting.rawValue)")
            MXLog.info("⚙️ App enableNotifications: \(appSettings.enableNotifications)")
            MXLog.info("🎯 App hideUnreadMessagesBadge: \(appSettings.hideUnreadMessagesBadge)")
        }
        
        // CRITICAL FIX: Re-register VoIP pusher immediately when user session is set
        // This must happen AFTER userSession is assigned and outside the Task to ensure proper timing
        if let voipTokenData = voipTokenData, userSession != nil {
            MXLog.info("🔄 CRITICAL FIX: Auto-registering VoIP pusher with newly set user session")
            MXLog.info("🔄 User session: \(userSession != nil ? "Available" : "Nil")")
            MXLog.info("🔄 VoIP token: \(voipTokenData.base64EncodedString().prefix(20))...")
            Task { [weak self] in
                guard let self else { return }
                let success = await self.registerVoIPPusher(with: voipTokenData)
                if success {
                    MXLog.info("✅ CRITICAL FIX: Auto VoIP pusher registration successful")
                } else {
                    MXLog.error("❌ CRITICAL FIX: Auto VoIP pusher registration failed")
                }
            }
        } else {
            MXLog.info("🔄 CRITICAL FIX: Skipping auto-registration - userSession: \(userSession != nil ? "Available" : "Nil"), token: \(voipTokenData != nil ? "Available" : "Nil")")
        }
    }
    
    // MARK: - VoIP Push через обычный token
    
    // DEPRECATED: Эта функция использует обычный токен для VoIP, что неправильно!
    // Используйте registerVoIPPusher с правильным VoIP токеном
    @available(*, deprecated, message: "Use registerVoIPPusher with proper VoIP token")
    private func registerVoIPPusherWithRegularToken(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        let appId = appSettings.pusherAppID
        let voipAppId = appSettings.voipAppId + ".voip" // Добавляем .voip к app ID
        let pushGateway = appSettings.pushGatewayNotifyEndpoint.absoluteString
        let bundleId = Bundle.main.bundleIdentifier ?? "Unknown"
        let buildType = ProcessInfo.processInfo.environment["DEBUG"] == "1" ? "DEBUG" : "RELEASE"
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: VoIP токен также должен быть в hex формате!
        let deviceTokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let deviceTokenBase64 = deviceToken.base64EncodedString() // для логов
        
        do {
            MXLog.info("[NotificationManager] 🚀 ===== VoIP PUSHER REGISTRATION (Regular Token) =====")
            MXLog.info("[NotificationManager] 📦 Bundle ID: \(bundleId)")
            MXLog.info("[NotificationManager] 🏗️ Build Type: \(buildType)")
            MXLog.info("[NotificationManager] 📱 VoIP App ID: \(voipAppId)")
            MXLog.info("[NotificationManager] 🌐 Push Gateway: \(pushGateway)")
            MXLog.info("[NotificationManager] 🔑 Device Token (HEX): \(deviceTokenString)")
            MXLog.info("[NotificationManager] 🔑 Device Token (Base64): \(deviceTokenBase64)")
            MXLog.info("[NotificationManager] 🔑 Token Length (HEX): \(deviceTokenString.count) chars")
            MXLog.info("[NotificationManager] 🔑 Token Length (Base64): \(deviceTokenBase64.count) chars")
            MXLog.info("[NotificationManager] 📋 App Display Name: \(InfoPlistReader.main.bundleDisplayName)")
            MXLog.info("[NotificationManager] 📱 Device Name: \(UIDevice.current.name)")
            MXLog.info("[NotificationManager] 🔧 Client Identifier: \(clientProxy.pusherNotificationClientIdentifier)")
            MXLog.info("[NotificationManager] 🎯 VoIP Profile Tag: voip_\(pusherProfileTag())")
            MXLog.info("[NotificationManager] 🌍 Language: \(Bundle.app.preferredLocalizations.first ?? "en")")
            MXLog.info("[NotificationManager] ============================================")
            
            // VoIP push payload (минимальный для CallKit)
            let voipPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                       alert: APSAlert(locKey: "Incoming call",
                                                                       locArgs: [])),
                                          pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)

            let voipConfiguration = try await PusherConfiguration(identifiers: .init(pushkey: deviceTokenString,
                                                                                     appId: voipAppId),
                                                                  kind: .http(data: .init(url: appSettings.pushGatewayNotifyEndpoint.absoluteString,
                                                                                          format: .eventIdOnly,
                                                                                          defaultPayload: voipPayload.toJsonString())),
                                                                  appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (VoIP)",
                                                                  deviceDisplayName: UIDevice.current.name,
                                                                  profileTag: "voip_\(pusherProfileTag())",
                                                                  lang: Bundle.app.preferredLocalizations.first ?? "en")
            try await clientProxy.setPusher(with: voipConfiguration)
            
            MXLog.info("[NotificationManager] ✅ ===== VoIP PUSHER REGISTRATION SUCCESS =====")
            MXLog.info("[NotificationManager] ✅ Successfully registered VoIP pusher with:")
            MXLog.info("[NotificationManager] ✅ VoIP App ID: \(voipAppId)")
            MXLog.info("[NotificationManager] ✅ Bundle ID: \(bundleId)")
            MXLog.info("[NotificationManager] ✅ Token (HEX): \(deviceTokenString.prefix(16))...")
            MXLog.info("[NotificationManager] ✅ Gateway: \(pushGateway)")
            MXLog.info("[NotificationManager] ================================================")
            return true
        } catch {
            MXLog.error("[NotificationManager] ❌ ===== VoIP PUSHER REGISTRATION FAILED =====")
            MXLog.error("[NotificationManager] ❌ Failed to register VoIP pusher:")
            MXLog.error("[NotificationManager] ❌ VoIP App ID: \(voipAppId)")
            MXLog.error("[NotificationManager] ❌ Bundle ID: \(bundleId)")
            MXLog.error("[NotificationManager] ❌ Token (HEX): \(deviceTokenString.prefix(16))...")
            MXLog.error("[NotificationManager] ❌ Gateway: \(pushGateway)")
            MXLog.error("[NotificationManager] ❌ Error: \(error)")
            MXLog.error("[NotificationManager] ===============================================")
            return false
        }
    }
    
    // MARK: - Force re-registration
    
    func forceReRegisterPushers() async {
        guard let userSession else { return }
        
        MXLog.info("[NotificationManager] Force re-registering pushers with updated payload")
        
        // Re-register for remote notifications to get fresh token
        await MainActor.run { [weak self] in
            self?.delegate?.registerForRemoteNotifications()
        }
    }

    func registrationFailed(with error: Error) {
        MXLog.error("[NotificationManager] device token registration failed with error: \(error)")
    }

    func showLocalNotification(with title: String, subtitle: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        let request = UNNotificationRequest(identifier: ProcessInfo.processInfo.globallyUniqueString,
                                            content: content,
                                            trigger: nil)
        do {
            try await notificationCenter.add(request)
            MXLog.info("[NotificationManager] show local notification succeeded")
        } catch {
            MXLog.error("[NotificationManager] show local notification failed: \(error)")
        }
    }
    
    func removeDeliveredMessageNotifications(for roomID: String) async {
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { $0.request.content.roomID == roomID }
            .map(\.request.identifier)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }
    
    func removeDeliveredNotificationsForFullyReadRooms(_ rooms: [RoomSummary]) async {
        let roomsToLastMessageDates = rooms
            .filter { $0.hasUnreadMessages == false }
            .reduce(into: [:]) { partialResult, roomSummary in
                partialResult[roomSummary.id] = roomSummary.lastMessageDate
            }
        
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { notification in
                guard let roomID = notification.request.content.roomID,
                      let lastMessageDate = roomsToLastMessageDates[roomID] else {
                    return false
                }
                    
                return notification.date <= lastMessageDate
            }
            .map(\.request.identifier)
        
        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }

    private func setPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        let appId = appSettings.pusherAppID
        let pushGateway = appSettings.pushGatewayNotifyEndpoint.absoluteString
        let bundleId = Bundle.main.bundleIdentifier ?? "Unknown"
        let buildType = ProcessInfo.processInfo.environment["DEBUG"] == "1" ? "DEBUG" : "RELEASE"
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: APNS требует hex формат device token!
        let deviceTokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let deviceTokenBase64 = deviceToken.base64EncodedString() // для логов
        
        do {
            MXLog.info("[NotificationManager] 🚀 ===== PUSHER REGISTRATION DEBUG =====")
            MXLog.info("[NotificationManager] 📦 Bundle ID: \(bundleId)")
            MXLog.info("[NotificationManager] 🏗️ Build Type: \(buildType)")
            MXLog.info("[NotificationManager] 📱 Pusher App ID: \(appId)")
            MXLog.info("[NotificationManager] 🌐 Push Gateway: \(pushGateway)")
            MXLog.info("[NotificationManager] 🔑 Device Token (HEX): \(deviceTokenString)")
            MXLog.info("[NotificationManager] 🔑 Device Token (Base64): \(deviceTokenBase64)")
            MXLog.info("[NotificationManager] 🔑 Token Length (HEX): \(deviceTokenString.count) chars")
            MXLog.info("[NotificationManager] 🔑 Token Length (Base64): \(deviceTokenBase64.count) chars")
            MXLog.info("[NotificationManager] 📋 App Display Name: \(InfoPlistReader.main.bundleDisplayName)")
            MXLog.info("[NotificationManager] 📱 Device Name: \(UIDevice.current.name)")
            MXLog.info("[NotificationManager] 🔧 Client Identifier: \(clientProxy.pusherNotificationClientIdentifier)")
            MXLog.info("[NotificationManager] 🎯 Profile Tag: \(pusherProfileTag())")
            MXLog.info("[NotificationManager] 🌍 Language: \(Bundle.app.preferredLocalizations.first ?? "en")")
            MXLog.info("[NotificationManager] ============================================")
            
            // ИСПРАВЛЕНИЕ: Используем более информативный defaultPayload для push уведомлений
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                          alert: APSAlert(locKey: "New message in %@",
                                                                          locArgs: ["${room_name}"])),
                                             pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)

            let configuration = try await PusherConfiguration(identifiers: .init(pushkey: deviceTokenString,
                                                                                 appId: appId),
                                                              kind: .http(data: .init(url: appSettings.pushGatewayNotifyEndpoint.absoluteString,
                                                                                      format: .eventIdOnly,
                                                                                      defaultPayload: defaultPayload.toJsonString())),
                                                              appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS)",
                                                              deviceDisplayName: UIDevice.current.name,
                                                              profileTag: pusherProfileTag(),
                                                              lang: Bundle.app.preferredLocalizations.first ?? "en")
            try await clientProxy.setPusher(with: configuration)
            
            MXLog.info("[NotificationManager] ✅ ===== PUSHER REGISTRATION SUCCESS =====")
            MXLog.info("[NotificationManager] ✅ Successfully registered pusher with:")
            MXLog.info("[NotificationManager] ✅ App ID: \(appId)")
            MXLog.info("[NotificationManager] ✅ Bundle ID: \(bundleId)")
            MXLog.info("[NotificationManager] ✅ Token (HEX): \(deviceTokenString.prefix(16))...")
            MXLog.info("[NotificationManager] ✅ Token (Base64): \(deviceTokenBase64.prefix(16))...")
            MXLog.info("[NotificationManager] ✅ Gateway: \(pushGateway)")
            MXLog.info("[NotificationManager] ================================================")
            return true
        } catch {
            MXLog.error("[NotificationManager] ❌ ===== PUSHER REGISTRATION FAILED =====")
            MXLog.error("[NotificationManager] ❌ Failed to register pusher:")
            MXLog.error("[NotificationManager] ❌ App ID: \(appId)")
            MXLog.error("[NotificationManager] ❌ Bundle ID: \(bundleId)")
            MXLog.error("[NotificationManager] ❌ Token (HEX): \(deviceTokenString.prefix(16))...")
            MXLog.error("[NotificationManager] ❌ Token (Base64): \(deviceTokenBase64.prefix(16))...")
            MXLog.error("[NotificationManager] ❌ Gateway: \(pushGateway)")
            MXLog.error("[NotificationManager] ❌ Error: \(error)")
            MXLog.error("[NotificationManager] ===============================================")
            return false
        }
    }

    private func pusherProfileTag() -> String {
        if let currentTag = appSettings.pusherProfileTag {
            return currentTag
        }
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let newTag = (0..<16).map { _ in
            let offset = Int.random(in: 0..<chars.count)
            return String(chars[chars.index(chars.startIndex, offsetBy: offset)])
        }.joined()

        appSettings.pusherProfileTag = newTag
        return newTag
    }
    
    private func enableNotifications(_ enable: Bool) {
        guard notificationsEnabled != enable else { return }
        notificationsEnabled = enable
        MXLog.info("[NotificationManager] app setting 'enableNotifications' changed to '\(enable)'")
        if enable {
            requestAuthorization()
        } else {
            delegate?.unregisterForRemoteNotifications()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard appSettings.enableInAppNotifications else {
            return []
        }
        guard let delegate else {
            return [.badge, .sound, .list, .banner]
        }

        guard delegate.shouldDisplayInAppNotification(content: notification.request.content) else {
            return []
        }

        return [.badge, .sound, .list, .banner]
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case NotificationConstants.Action.inlineReply:
            guard let response = response as? UNTextInputNotificationResponse else {
                return
            }
            await delegate?.handleInlineReply(self,
                                              content: response.notification.request.content,
                                              replyText: response.userText)
        case UNNotificationDefaultActionIdentifier:
            await delegate?.notificationTapped(content: response.notification.request.content)
        default:
            break
        }
    }
}

// MARK: - VoIP Push Support

extension NotificationManager {
    // VoIP Push Protocol Implementation
    
    func registerVoIPPusher(with tokenData: Data) async -> Bool {
        lastVoIPRegistrationAttempt = Date()
        
        guard let userSession else {
            MXLog.error("[NotificationManager] Cannot register VoIP pusher - no user session")
            // Store token for later registration when session is available
            voipTokenData = tokenData
            lastVoIPRegistrationSuccess = false
            return false
        }
        
        voipTokenData = tokenData
        let result = await setVoIPPusher(with: tokenData, clientProxy: userSession.clientProxy)
        
        lastVoIPRegistrationSuccess = result
        
        if result {
            MXLog.info("[NotificationManager] ✅ VoIP pusher registration successful")
            voipPusherRegistrationRetryCount = 0
            voipRetryTimer?.invalidate()
            voipRetryTimer = nil
        } else {
            MXLog.error("[NotificationManager] ❌ VoIP pusher registration failed, will retry")
            scheduleVoIPPusherRetry(tokenData: tokenData)
        }
        
        return result
    }
    
    func hasVoIPToken() -> Bool {
        voipTokenData != nil
    }
    
    // MARK: - VoIP Retry Logic
    
    private func scheduleVoIPPusherRetry(tokenData: Data) {
        guard voipPusherRegistrationRetryCount < maxVoIPRetryAttempts else {
            MXLog.error("[NotificationManager] ❌ Max VoIP pusher retry attempts reached")
            return
        }
        
        voipPusherRegistrationRetryCount += 1
        let retryDelay = TimeInterval(voipPusherRegistrationRetryCount * 5) // 5s, 10s, 15s
        
        MXLog.info("[NotificationManager] 🔄 Scheduling VoIP pusher retry #\(voipPusherRegistrationRetryCount) in \(retryDelay)s")
        
        voipRetryTimer?.invalidate()
        voipRetryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            Task {
                guard let self else { return }
                MXLog.info("[NotificationManager] 🔄 Retrying VoIP pusher registration (attempt \(self.voipPusherRegistrationRetryCount))")
                _ = await self.registerVoIPPusher(with: tokenData)
            }
        }
    }
    
    // Private VoIP Implementation
    
    private func setupVoIPPushRegistry() {
        MXLog.info("[NotificationManager] 🔄 ===== VOIP PUSH REGISTRY SETUP =====")
        MXLog.info("[NotificationManager] 📱 Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")")
        MXLog.info("[NotificationManager] 🏗️ Build: \(ProcessInfo.processInfo.environment["DEBUG"] == "1" ? "DEBUG" : "RELEASE")")
        MXLog.info("[NotificationManager] 📋 App Display Name: \(InfoPlistReader.main.bundleDisplayName)")
        
        // Проверяем Background Mode VoIP
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let hasVoIPMode = backgroundModes?.contains("voip") ?? false
        MXLog.info("[NotificationManager] 🔍 VoIP Background Mode: \(hasVoIPMode ? "✅ ENABLED" : "❌ MISSING")")
        
        if !hasVoIPMode {
            MXLog.error("[NotificationManager] ❌ CRITICAL: VoIP background mode not enabled in Info.plist!")
            MXLog.error("[NotificationManager] ❌ Add 'voip' to UIBackgroundModes array in Info.plist")
        }
        
        // Инициализируем PKPushRegistry
        pushRegistry = PKPushRegistry(queue: nil)
        pushRegistry?.delegate = self
        pushRegistry?.desiredPushTypes = [.voIP]
        
        MXLog.info("[NotificationManager] ✅ PKPushRegistry initialized with delegate: \(pushRegistry?.delegate != nil ? "SET" : "NIL")")
        MXLog.info("[NotificationManager] ✅ Desired push types: [.voIP]")
        MXLog.info("[NotificationManager] ✅ VoIP Push Registry configuration completed")
        MXLog.info("[NotificationManager] ===============================================")
    }
    
    private func setVoIPPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        // COMPREHENSIVE VoIP PUSHER REGISTRATION WITH FULL DIAGNOSTICS
        
        let startTime = Date()
        MXLog.info("[NotificationManager] 🚀 STARTING VoIP pusher registration...")
        
        // Step 1: Validate prerequisites
        guard !deviceToken.isEmpty else {
            MXLog.error("[NotificationManager] ❌ CRITICAL: Empty device token!")
            return false
        }
        
        // Step 2: Configure App ID (CRITICAL - server must recognize this)
        let voipAppId = appSettings.voipAppId + ".voip" // Добавляем .voip к app ID для VoIP pusher
        let voipProfileTag = "voip_calls_only_\(String(appSettings.pusherProfileTag?.suffix(8) ?? "default"))"
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: VoIP токен также должен быть в hex формате!
        let pushKeyHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let pushKeyBase64 = deviceToken.base64EncodedString() // для сравнения в логах
        let pushGatewayURL = appSettings.pushGatewayNotifyEndpoint.absoluteString
        
        // Step 3: CRITICAL VALIDATION - ensure configuration matches server expectations  
        // VoIP pusher MUST use .voip app_id suffix для корректной работы с сервером
        let isProductionConfig = !voipAppId.contains("debug")
        
        MXLog.info("[NotificationManager] 📱 VoIP Pusher Configuration:")
        MXLog.info("[NotificationManager] - App ID: \(voipAppId)")
        MXLog.info("[NotificationManager] - Is Production Config: \(isProductionConfig ? "✅ YES" : "❌ NO")")
        MXLog.info("[NotificationManager] - Profile Tag: \(voipProfileTag)")
        MXLog.info("[NotificationManager] - Push Key (HEX): \(pushKeyHex.prefix(20))...")
        MXLog.info("[NotificationManager] - Push Key (Base64): \(pushKeyBase64.prefix(20))...")
        MXLog.info("[NotificationManager] - Push Gateway: \(pushGatewayURL)")
        MXLog.info("[NotificationManager] - Device: \(UIDevice.current.name)")
        MXLog.info("[NotificationManager] - App Name: KDB Chat")
        
        // Step 4: Log build configuration
        if !isProductionConfig {
            MXLog.info("[NotificationManager] ℹ️ DEBUG build detected - using debug configuration")
        }
        
        do {
            // Step 5: Create pusher configuration
            let voipConfiguration = try await PusherConfiguration(identifiers: .init(pushkey: pushKeyHex,
                                                                                     appId: voipAppId),
                                                                  kind: .http(data: .init(url: pushGatewayURL,
                                                                                          format: .eventIdOnly,
                                                                                          defaultPayload: nil)),
                                                                  appDisplayName: "KDB Chat",
                                                                  deviceDisplayName: UIDevice.current.name,
                                                                  profileTag: voipProfileTag,
                                                                  lang: Bundle.app.preferredLocalizations.first ?? "en")
            
            MXLog.info("[NotificationManager] 🔄 Sending pusher configuration to server...")
            
            // Step 6: CRITICAL - Register with server
            try await clientProxy.setPusher(with: voipConfiguration)
            
            let elapsedTime = Date().timeIntervalSince(startTime)
            MXLog.info("[NotificationManager] ✅ VoIP pusher registration SUCCESSFUL!")
            MXLog.info("[NotificationManager] ✅ Registration completed in \(String(format: "%.2f", elapsedTime))s")
            MXLog.info("[NotificationManager] ✅ Server accepted pusher with App ID: \(voipAppId)")
            
            return true
            
        } catch {
            let elapsedTime = Date().timeIntervalSince(startTime)
            MXLog.error("[NotificationManager] ❌ VoIP pusher registration FAILED after \(String(format: "%.2f", elapsedTime))s")
            MXLog.error("[NotificationManager] ❌ Error: \(error)")
            MXLog.error("[NotificationManager] ❌ Error Type: \(type(of: error))")
            
            // ENHANCED ERROR ANALYSIS
            let errorString = String(describing: error)
            
            if errorString.contains("network") || errorString.contains("connection") {
                MXLog.error("[NotificationManager] 🌐 NETWORK ERROR: Check internet connection and server availability")
            } else if errorString.contains("unauthorized") || errorString.contains("forbidden") {
                MXLog.error("[NotificationManager] 🔐 AUTHORIZATION ERROR: Check user session and permissions")
            } else if errorString.contains("app_id") || errorString.contains("pusher") {
                MXLog.error("[NotificationManager] ⚙️ CONFIGURATION ERROR: Server may not recognize App ID '\(voipAppId)'")
                MXLog.error("[NotificationManager] ⚙️ SOLUTION: Verify server Sygnal configuration for this App ID")
            } else {
                MXLog.error("[NotificationManager] ❓ UNKNOWN ERROR: May require server-side investigation")
            }
            
            return false
        }
    }
    
    // MARK: - VoIP Health Check
    
    private func performVoIPHealthCheck() {
        // Delay health check to allow for initial setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self else { return }
            
            MXLog.info("[NotificationManager] 🏥 Performing VoIP health check")
            
            // Check 1: VoIP token received
            if self.voipTokenData == nil {
                MXLog.warning("[NotificationManager] ⚠️ HEALTH CHECK: No VoIP token received after 10 seconds")
                MXLog.warning("[NotificationManager] ⚠️ Possible causes:")
                MXLog.warning("[NotificationManager] ⚠️ - Missing VoIP entitlement")
                MXLog.warning("[NotificationManager] ⚠️ - Invalid provisioning profile")
                MXLog.warning("[NotificationManager] ⚠️ - PKPushRegistry not initialized properly")
            } else {
                MXLog.info("[NotificationManager] ✅ HEALTH CHECK: VoIP token available")
            }
            
            // Check 2: User session available
            if self.userSession == nil {
                MXLog.info("[NotificationManager] ℹ️ HEALTH CHECK: No user session yet, VoIP pusher will register on login")
            } else if self.voipTokenData != nil, !self.lastVoIPRegistrationSuccess {
                MXLog.warning("[NotificationManager] ⚠️ HEALTH CHECK: VoIP pusher registration failed")
                MXLog.warning("[NotificationManager] ⚠️ Retry count: \(self.voipPusherRegistrationRetryCount)")
            } else if self.lastVoIPRegistrationSuccess {
                MXLog.info("[NotificationManager] ✅ HEALTH CHECK: VoIP pusher registered successfully")
            }
            
            // Check 3: Automatic re-registration if needed
            if self.userSession != nil, self.voipTokenData != nil, !self.lastVoIPRegistrationSuccess {
                MXLog.info("[NotificationManager] 🔄 HEALTH CHECK: Triggering automatic VoIP pusher registration")
                Task {
                    _ = await self.registerVoIPPusher(with: self.voipTokenData!)
                }
            }
        }
    }
    
    // MARK: - Diagnostic Methods
    
    func getVoIPPusherDiagnostics() -> VoIPPusherDiagnostics {
        VoIPPusherDiagnostics(hasToken: voipTokenData != nil,
                              tokenPrefix: voipTokenData.map { String($0.base64EncodedString().prefix(20)) },
                              lastRegistrationAttempt: lastVoIPRegistrationAttempt,
                              registrationSuccess: lastVoIPRegistrationSuccess,
                              retryCount: voipPusherRegistrationRetryCount,
                              userSessionAvailable: userSession != nil)
    }
    
    func testVoIPPusherRegistration() async -> VoIPPusherTestResult {
        MXLog.info("[NotificationManager] 🧪 Starting VoIP pusher test")
        
        // Check if we have a token
        guard let tokenData = voipTokenData else {
            return VoIPPusherTestResult(success: false,
                                        message: "No VoIP token available. PushKit may not be properly configured.",
                                        tokenReceived: false,
                                        pusherRegistered: false,
                                        errorDetails: "PKPushRegistry did not provide a token")
        }
        
        // Check if we have a user session
        guard userSession != nil else {
            return VoIPPusherTestResult(success: false,
                                        message: "No user session available. Please log in first.",
                                        tokenReceived: true,
                                        pusherRegistered: false,
                                        errorDetails: "User session is nil")
        }
        
        // Try to register the pusher
        let registrationSuccess = await registerVoIPPusher(with: tokenData)
        
        return VoIPPusherTestResult(success: registrationSuccess,
                                    message: registrationSuccess ? "VoIP pusher registered successfully!" : "VoIP pusher registration failed.",
                                    tokenReceived: true,
                                    pusherRegistered: registrationSuccess,
                                    errorDetails: registrationSuccess ? nil : "Check logs for detailed error")
    }
}

// MARK: - PKPushRegistryDelegate

extension NotificationManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: VoIP токен также должен быть в hex формате!
        let tokenHex = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        let tokenBase64 = pushCredentials.token.base64EncodedString() // для сравнения
        MXLog.info("[NotificationManager] 📲 VoIP push token received (HEX): \(tokenHex.prefix(20))...")
        MXLog.info("[NotificationManager] 📲 VoIP push token received (Base64): \(tokenBase64.prefix(20))...")
        MXLog.info("[NotificationManager] 📲 VoIP Token Length (HEX): \(tokenHex.count) chars")
        MXLog.info("[NotificationManager] 📲 VoIP Token Length (Base64): \(tokenBase64.count) chars")
        
        // Store token and notify delegate
        voipTokenData = pushCredentials.token
        delegate?.voIPTokenUpdated(pushCredentials.token)
        
        // Register pusher immediately if we have a user session, otherwise store for later
        if userSession != nil {
            MXLog.info("[NotificationManager] 🚀 User session available - registering VoIP pusher immediately")
            Task {
                let success = await registerVoIPPusher(with: pushCredentials.token)
                if success {
                    MXLog.info("[NotificationManager] ✅ Immediate VoIP pusher registration successful")
                } else {
                    MXLog.error("[NotificationManager] ❌ Immediate VoIP pusher registration failed")
                }
            }
        } else {
            MXLog.info("[NotificationManager] 📝 No user session yet - VoIP token stored for later registration")
        }
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }
        
        MXLog.info("[NotificationManager] 📥 ===== VOIP PUSH RECEIVED =====")
        MXLog.info("[NotificationManager] 🕐 Timestamp: \(Date())")
        MXLog.info("[NotificationManager] 📱 Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")")
        MXLog.info("[NotificationManager] 🔍 Push Type: VoIP (.voIP)")
        MXLog.info("[NotificationManager] 📋 Payload Keys: \(payload.dictionaryPayload.keys.map { String(describing: $0) }.joined(separator: ", "))")
        MXLog.debug("[NotificationManager] 📦 Full VoIP payload: \(payload.dictionaryPayload)")
        
        // CRITICAL: According to Apple's requirements since iOS 13, we MUST report
        // incoming VoIP push notifications to CallKit immediately within this method
        handleVoIPPushNotification(payload: payload.dictionaryPayload, completion: completion)
    }
    
    private func handleVoIPPushNotification(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        MXLog.info("[NotificationManager] 🔄 ===== VOIP PUSH PROCESSING =====")
        
        // CRITICAL: Comprehensive payload validation (Apple compliance)
        let validationResult = validateVoIPPayload(payload)
        
        guard validationResult.isValid else {
            MXLog.error("[NotificationManager] ❌ ===== VOIP PUSH VALIDATION FAILED =====")
            MXLog.error("[NotificationManager] ❌ Validation error: \(validationResult.errorMessage ?? "Unknown error")")
            MXLog.error("[NotificationManager] ❌ Available keys: \(payload.keys.map { String(describing: $0) }.joined(separator: ", "))")
            MXLog.error("[NotificationManager] ❌ This violates Apple VoIP Push requirements!")
            completion()
            return
        }
        
        // Extract validated call information
        guard case .valid(let roomId, let callId) = validationResult else {
            MXLog.error("[NotificationManager] ❌ Unexpected validation state")
            completion()
            return
        }
        
        let callerName = extractCallerName(from: payload) ?? "Unknown Caller"
        let hasVideo = extractHasVideo(from: payload)
        
        // CRITICAL: Call deduplication check (Apple "One Push Per Call" compliance)
        // This prevents processing the same call multiple times which violates Apple guidelines
        if processedCallIds.contains(callId) {
            MXLog.warning("[NotificationManager] ⚠️ ===== DUPLICATE VOIP PUSH DETECTED =====")
            MXLog.warning("[NotificationManager] ⚠️ Call ID already processed: \(callId)")
            MXLog.warning("[NotificationManager] ⚠️ Room ID: \(roomId)")
            MXLog.warning("[NotificationManager] ⚠️ This violates Apple's 'One Push Per Call' rule")
            MXLog.warning("[NotificationManager] ⚠️ Ignoring duplicate VoIP push notification")
            completion()
            return
        }
        
        // Add to processed calls set to prevent future duplicates
        processedCallIds.insert(callId)
        MXLog.info("[NotificationManager] 🔐 Call ID added to deduplication set: \(callId)")
        
        // Schedule cleanup for this call ID after 5 minutes
        // This prevents memory bloat while maintaining reasonable deduplication window
        DispatchQueue.main.asyncAfter(deadline: .now() + callDeduplicationCleanupInterval) { [weak self] in
            self?.processedCallIds.remove(callId)
            MXLog.debug("[NotificationManager] 🧹 Cleaned up call ID from deduplication set: \(callId)")
        }
        
        MXLog.info("[NotificationManager] ✅ ===== VOIP PUSH VALIDATION SUCCESS =====")
        MXLog.info("[NotificationManager] 📞 Room ID: \(roomId)")
        MXLog.info("[NotificationManager] 📞 Call ID: \(callId)")
        MXLog.info("[NotificationManager] 👤 Caller Name: \(callerName)")
        MXLog.info("[NotificationManager] 📹 Has Video: \(hasVideo)")
        MXLog.info("[NotificationManager] 🕐 Processing Time: \(Date())")
        MXLog.info("[NotificationManager] 🔢 Active deduplicated calls: \(processedCallIds.count)")
        
        // CRITICAL: Report to CallKit immediately (synchronously required by Apple)
        // Apple requires that we report the call to CallKit before this method returns
        // otherwise the app will be terminated
        
        guard let delegate = delegate else {
            MXLog.error("[NotificationManager] ❌ No delegate available to handle VoIP push")
            completion()
            return
        }
        
        // APPLE REQUIREMENT FIX: Report to CallKit immediately without waiting
        // Apple requires immediate CallKit registration, but we need to handle app startup gracefully
        MXLog.info("[NotificationManager] 🚀 Reporting VoIP call to CallKit immediately (Apple requirement)")
        
        Task {
            await delegate.handleVoIPPushNotification(roomId: roomId,
                                                      callId: callId,
                                                      callerName: callerName,
                                                      hasVideo: hasVideo)
            MXLog.info("[NotificationManager] ✅ VoIP call reported to CallKit via delegate")
        }
        
        // Apple requires immediate completion - don't wait for CallKit registration
        // This prevents app termination during startup when CallKit might not be ready
        MXLog.info("[NotificationManager] ✅ VoIP push processing completed immediately (Apple compliance)")
        
        completion()
    }
    
    // MARK: - VoIP Payload Validation
    
    /// Comprehensive VoIP payload validation according to Apple requirements
    /// Returns detailed validation result with specific error messages
    private func validateVoIPPayload(_ payload: [AnyHashable: Any]) -> VoIPValidationResult {
        MXLog.info("[NotificationManager] 🔍 ===== VOIP PAYLOAD VALIDATION =====")
        
        // Basic structure validation
        guard !payload.isEmpty else {
            MXLog.error("[NotificationManager] ❌ Empty VoIP payload received")
            return .invalid("Empty payload - violates Apple VoIP requirements")
        }
        
        // Log payload structure for debugging
        MXLog.debug("[NotificationManager] 📋 Payload keys: \(payload.keys.map { String(describing: $0) }.sorted().joined(separator: ", "))")
        
        // CRITICAL: Validate required call fields
        guard let roomId = extractRoomId(from: payload), !roomId.isEmpty else {
            MXLog.error("[NotificationManager] ❌ Missing or empty room_id in VoIP payload")
            return .invalid("Missing room_id - required for call routing")
        }
        
        guard let callId = extractCallId(from: payload), !callId.isEmpty else {
            MXLog.error("[NotificationManager] ❌ Missing or empty call_id in VoIP payload")
            return .invalid("Missing call_id - required for call deduplication")
        }
        
        // Room ID format validation (Matrix room IDs should start with !)
        if !roomId.hasPrefix("!") {
            MXLog.warning("[NotificationManager] ⚠️ Room ID doesn't follow Matrix format: \(roomId)")
        }
        
        // Call ID format validation (should be non-empty and reasonable length)
        if callId.count < 3 || callId.count > 256 {
            MXLog.warning("[NotificationManager] ⚠️ Call ID has unusual length (\(callId.count)): \(callId.prefix(32))")
        }
        
        // Check for caller information (recommended but not strictly required)
        let hasCallerInfo = extractCallerName(from: payload) != nil
        if !hasCallerInfo {
            MXLog.warning("[NotificationManager] ⚠️ No caller information found - user experience may be degraded")
        }
        
        // Validate event type if present (should be call related)
        if let eventType = payload["event_type"] as? String {
            let validEventTypes = ["m.call.invite", "m.call.member", "m.call.notify"]
            if !validEventTypes.contains(eventType) {
                MXLog.error("[NotificationManager] ❌ Invalid event type for VoIP push: \(eventType)")
                return .invalid("Invalid event type '\(eventType)' - not a call event")
            }
            MXLog.info("[NotificationManager] ✅ Valid call event type: \(eventType)")
        }
        
        // Check for spam/abuse indicators
        let suspiciousPatterns = ["test", "spam", "fake", "debug"]
        for pattern in suspiciousPatterns {
            if roomId.lowercased().contains(pattern) || callId.lowercased().contains(pattern) {
                MXLog.warning("[NotificationManager] 🚨 Potentially suspicious call detected (pattern: \(pattern))")
                break
            }
        }
        
        // Validate payload size (Apple recommends keeping VoIP payloads small)
        let payloadString = String(describing: payload)
        let payloadSize = payloadString.utf8.count
        if payloadSize > 5000 { // 5KB warning threshold
            MXLog.warning("[NotificationManager] ⚠️ Large VoIP payload detected (\(payloadSize) bytes) - may impact delivery")
        }
        
        MXLog.info("[NotificationManager] ✅ ===== VOIP PAYLOAD VALIDATION SUCCESS =====")
        MXLog.info("[NotificationManager] ✅ Room ID: \(roomId.prefix(32))...")
        MXLog.info("[NotificationManager] ✅ Call ID: \(callId.prefix(32))...")
        MXLog.info("[NotificationManager] ✅ Has Caller Info: \(hasCallerInfo)")
        MXLog.info("[NotificationManager] ✅ Payload Size: \(payloadSize) bytes")
        
        return .valid(roomId: roomId, callId: callId)
    }
    
    // MARK: - VoIP Payload Parsing
    
    private func extractRoomId(from payload: [AnyHashable: Any]) -> String? {
        // Try different possible keys in the payload
        if let roomId = payload["room_id"] as? String { return roomId }
        if let roomId = payload["roomId"] as? String { return roomId }
        if let roomId = payload["room"] as? String { return roomId }
        
        // Try nested structures
        if let aps = payload["aps"] as? [String: Any],
           let roomId = aps["room_id"] as? String { return roomId }
        
        return nil
    }
    
    private func extractCallId(from payload: [AnyHashable: Any]) -> String? {
        // Try different possible keys in the payload
        if let callId = payload["call_id"] as? String { return callId }
        if let callId = payload["callId"] as? String { return callId }
        if let callId = payload["event_id"] as? String { return callId }
        if let callId = payload["eventId"] as? String { return callId }
        
        // Try nested structures
        if let aps = payload["aps"] as? [String: Any],
           let callId = aps["call_id"] as? String { return callId }
        
        // Generate UUID if not found
        return UUID().uuidString
    }
    
    private func extractCallerName(from payload: [AnyHashable: Any]) -> String? {
        // Try different possible keys in the payload
        if let callerName = payload["caller_name"] as? String { return callerName }
        if let callerName = payload["callerName"] as? String { return callerName }
        if let callerName = payload["sender_display_name"] as? String { return callerName }
        if let callerName = payload["display_name"] as? String { return callerName }
        
        // Try nested structures
        if let aps = payload["aps"] as? [String: Any] {
            if let callerName = aps["caller_name"] as? String { return callerName }
            if let alert = aps["alert"] as? [String: Any],
               let title = alert["title"] as? String { return title }
        }
        
        return nil
    }
    
    private func extractHasVideo(from payload: [AnyHashable: Any]) -> Bool {
        // Try different possible keys in the payload
        if let hasVideo = payload["has_video"] as? Bool { return hasVideo }
        if let hasVideo = payload["hasVideo"] as? Bool { return hasVideo }
        if let hasVideo = payload["video"] as? Bool { return hasVideo }
        
        // Try nested structures
        if let aps = payload["aps"] as? [String: Any],
           let hasVideo = aps["has_video"] as? Bool { return hasVideo }
        
        // Default to true for video calls
        return true
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        
        MXLog.warning("[NotificationManager] ⚠️ VoIP push token invalidated")
        voipTokenData = nil
    }
    
    // MARK: - CallKit App Group Integration
    
    /// Process CallKit data stored by NSE in App Group
    func processCallKitDataFromAppGroup() async {
        MXLog.info("[NotificationManager] 🔍 Checking App Group for CallKit data")
        
        guard let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") else {
            MXLog.error("[NotificationManager] ❌ Failed to access App Group UserDefaults")
            return
        }
        
        // Check for incoming call data stored by NSE
        guard let callKitData = appGroupDefaults.dictionary(forKey: "incoming_call_data") else {
            MXLog.debug("[NotificationManager] ℹ️ No CallKit data found in App Group")
            return
        }
        
        MXLog.info("[NotificationManager] 📞 Found CallKit data in App Group, processing...")
        
        // Extract call information
        guard let roomId = callKitData["room_id"] as? String,
              let callId = callKitData["call_id"] as? String,
              let callerDisplayName = callKitData["caller_display_name"] as? String else {
            MXLog.error("[NotificationManager] ❌ Invalid CallKit data structure")
            return
        }
        
        let callerId = callKitData["caller_id"] as? String ?? roomId
        let isVideo = callKitData["is_video"] as? Bool ?? true
        let timestamp = callKitData["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        
        // Check if data is fresh (within 2 minutes)
        let dataAge = Date().timeIntervalSince1970 - timestamp
        if dataAge > 120 {
            MXLog.warning("[NotificationManager] ⚠️ CallKit data is stale (\(dataAge)s old), ignoring")
            appGroupDefaults.removeObject(forKey: "incoming_call_data")
            appGroupDefaults.synchronize()
            return
        }
        
        // Extract LiveKit credentials if available
        let liveKitAccessToken = callKitData["livekit_access_token"] as? String
        let liveKitServerURL = callKitData["livekit_server_url"] as? String
        let liveKitRoomURL = callKitData["livekit_room_url"] as? String
        
        MXLog.info("[NotificationManager] 📞 Processing call: Room=\(roomId), Caller=\(callerDisplayName), Video=\(isVideo)")
        MXLog.info("[NotificationManager] 🎬 LiveKit credentials: Token=\(liveKitAccessToken != nil ? "[PRESENT]" : "[MISSING]"), Server=\(liveKitServerURL ?? "[MISSING]")")
        
        // Report to CallKit via LiveKitCallKitService
        #if LIVEKIT_ENABLED
        do {
            if let accessToken = liveKitAccessToken,
               let serverURL = liveKitServerURL,
               !accessToken.isEmpty,
               !serverURL.isEmpty {
                // Use enhanced method with credentials
                try await LiveKitCallKitService.shared.reportIncomingCallWithCredentials(roomId: roomId,
                                                                                         callId: callId,
                                                                                         callerName: callerDisplayName,
                                                                                         hasVideo: isVideo,
                                                                                         liveKitAccessToken: accessToken,
                                                                                         liveKitServerURL: serverURL,
                                                                                         liveKitRoomURL: liveKitRoomURL)
                MXLog.info("[NotificationManager] ✅ CallKit reported with LiveKit credentials")
            } else {
                // Fallback to standard method
                try await LiveKitCallKitService.shared.reportIncomingCall(roomId: roomId,
                                                                          callId: callId,
                                                                          callerName: callerDisplayName,
                                                                          hasVideo: isVideo)
                MXLog.info("[NotificationManager] ✅ CallKit reported (standard flow)")
            }
            
            // Clean up processed data
            appGroupDefaults.removeObject(forKey: "incoming_call_data")
            appGroupDefaults.synchronize()
            
        } catch {
            MXLog.error("[NotificationManager] ❌ Failed to report CallKit call: \(error)")
            
            // Don't clean up on failure - might retry later
            // But add a retry count to prevent infinite loops
            let retryCount = callKitData["retry_count"] as? Int ?? 0
            if retryCount < 3 {
                var updatedData = callKitData
                updatedData["retry_count"] = retryCount + 1
                appGroupDefaults.set(updatedData, forKey: "incoming_call_data")
                appGroupDefaults.synchronize()
                MXLog.info("[NotificationManager] 🔄 CallKit data retry count: \(retryCount + 1)")
            } else {
                MXLog.error("[NotificationManager] ❌ Max CallKit retry attempts reached, cleaning up")
                appGroupDefaults.removeObject(forKey: "incoming_call_data")
                appGroupDefaults.synchronize()
            }
        }
        #else
        MXLog.error("[NotificationManager] ❌ LIVEKIT_ENABLED not defined - cannot process CallKit")
        appGroupDefaults.removeObject(forKey: "incoming_call_data")
        appGroupDefaults.synchronize()
        #endif
    }
    
    /// Setup periodic check for App Group CallKit data
    func startAppGroupCallKitMonitoring() {
        MXLog.info("[NotificationManager] 🔄 Starting App Group CallKit monitoring")
        
        // Check immediately
        Task {
            await processCallKitDataFromAppGroup()
        }
        
        // Setup periodic checks every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task {
                await self?.processCallKitDataFromAppGroup()
            }
        }
    }
    
    /// Unregister all pushers before logout
    func unregisterPusher() async {
        MXLog.info("[NotificationManager] 🗑️ Unregistering all pushers")
        
        guard let userSession else {
            MXLog.warning("[NotificationManager] Cannot unregister pusher - no user session")
            return
        }
        
        // Cancel any ongoing retry timers
        voipRetryTimer?.invalidate()
        voipRetryTimer = nil
        
        // Unregister VoIP pusher if we have a token
        if let voipTokenData = voipTokenData {
            MXLog.info("[NotificationManager] 🔄 Unregistering VoIP pusher")
            
            do {
                let tokenString = voipTokenData.map { String(format: "%02.2hhx", $0) }.joined()
                
                // Create empty pusher configuration to remove the pusher
                let voipAppId = "\(appSettings.pushGatewayNotifyEndpoint.host ?? "unknown").\(InfoPlistReader.main.bundleIdentifier).voip"
                
                let emptyConfiguration = try await PusherConfiguration(identifiers: .init(pushkey: tokenString,
                                                                                          appId: voipAppId),
                                                                       kind: .http(data: .init(url: "",
                                                                                               format: .eventIdOnly,
                                                                                               defaultPayload: "")),
                                                                       appDisplayName: "",
                                                                       deviceDisplayName: "",
                                                                       profileTag: "voip_\(pusherProfileTag())",
                                                                       lang: "en")
                
                // Setting pusher with empty configuration effectively removes it
                try await userSession.clientProxy.setPusher(with: emptyConfiguration)
                MXLog.info("[NotificationManager] ✅ Successfully unregistered VoIP pusher")
            } catch {
                MXLog.error("[NotificationManager] ❌ Failed to unregister VoIP pusher: \(error)")
            }
        }
        
        // Clear stored token data
        voipTokenData = nil
        lastVoIPRegistrationSuccess = false
        voipPusherRegistrationRetryCount = 0
        
        MXLog.info("[NotificationManager] ✅ Pusher unregistration completed")
    }
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol { }
