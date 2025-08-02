//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK
import UIKit
import UserNotifications
import PushKit

#if LIVEKIT_ENABLED
// LiveKitCallKitService is only available when LIVEKIT_ENABLED
#endif

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
            
        // VoIP Push через обычные push уведомления (без специального entitlement)
        // PKPushRegistry не используем - будем получать VoIP через обычный token с .voip topic
        MXLog.info("[NotificationManager] VoIP calls will use regular push notifications with .voip topic")
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
        
        // Регистрируем VoIP pusher с тем же токеном, но с .voip topic
        let voipSuccess = await registerVoIPPusherWithRegularToken(with: deviceToken, clientProxy: userSession.clientProxy)
        
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
        if let voipTokenData = self.voipTokenData, userSession != nil {
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
    
    private func registerVoIPPusherWithRegularToken(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        let appId = appSettings.pusherAppID
        let voipAppId = appSettings.voipAppId + ".voip"  // Добавляем .voip к app ID
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
            self.voipTokenData = tokenData
            lastVoIPRegistrationSuccess = false
            return false
        }
        
        self.voipTokenData = tokenData
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
        return voipTokenData != nil
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
        MXLog.info("[NotificationManager] 🔄 Setting up VoIP Push Registry")
        
        pushRegistry = PKPushRegistry(queue: nil)
        pushRegistry?.delegate = self
        pushRegistry?.desiredPushTypes = [.voIP]
        
        MXLog.info("[NotificationManager] ✅ VoIP Push Registry configured")
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
        let voipAppId = appSettings.voipAppId  // Используем правильный VoIP app ID
        let voipProfileTag = "voip_calls_only_\(String(appSettings.pusherProfileTag?.suffix(8) ?? "default"))"
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: VoIP токен также должен быть в hex формате!
        let pushKeyHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let pushKeyBase64 = deviceToken.base64EncodedString() // для сравнения в логах
        let pushGatewayURL = appSettings.pushGatewayNotifyEndpoint.absoluteString
        
        // Step 3: CRITICAL VALIDATION - ensure configuration matches server expectations
        // После исправления app_id больше нет специального .voip суффикса
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
            let voipConfiguration = try await PusherConfiguration(
                identifiers: .init(
                    pushkey: pushKeyHex,
                    appId: voipAppId
                ),
                kind: .http(data: .init(
                    url: pushGatewayURL,
                    format: .eventIdOnly,
                    defaultPayload: nil
                )),
                appDisplayName: "KDB Chat",
                deviceDisplayName: UIDevice.current.name,
                profileTag: voipProfileTag,
                lang: Bundle.app.preferredLocalizations.first ?? "en"
            )
            
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
            } else if self.voipTokenData != nil && !self.lastVoIPRegistrationSuccess {
                MXLog.warning("[NotificationManager] ⚠️ HEALTH CHECK: VoIP pusher registration failed")
                MXLog.warning("[NotificationManager] ⚠️ Retry count: \(self.voipPusherRegistrationRetryCount)")
            } else if self.lastVoIPRegistrationSuccess {
                MXLog.info("[NotificationManager] ✅ HEALTH CHECK: VoIP pusher registered successfully")
            }
            
            // Check 3: Automatic re-registration if needed
            if self.userSession != nil && self.voipTokenData != nil && !self.lastVoIPRegistrationSuccess {
                MXLog.info("[NotificationManager] 🔄 HEALTH CHECK: Triggering automatic VoIP pusher registration")
                Task {
                    _ = await self.registerVoIPPusher(with: self.voipTokenData!)
                }
            }
        }
    }
    
    // MARK: - Diagnostic Methods
    
    func getVoIPPusherDiagnostics() -> VoIPPusherDiagnostics {
        return VoIPPusherDiagnostics(
            hasToken: voipTokenData != nil,
            tokenPrefix: voipTokenData.map { String($0.base64EncodedString().prefix(20)) },
            lastRegistrationAttempt: lastVoIPRegistrationAttempt,
            registrationSuccess: lastVoIPRegistrationSuccess,
            retryCount: voipPusherRegistrationRetryCount,
            userSessionAvailable: userSession != nil
        )
    }
    
    func testVoIPPusherRegistration() async -> VoIPPusherTestResult {
        MXLog.info("[NotificationManager] 🧪 Starting VoIP pusher test")
        
        // Check if we have a token
        guard let tokenData = voipTokenData else {
            return VoIPPusherTestResult(
                success: false,
                message: "No VoIP token available. PushKit may not be properly configured.",
                tokenReceived: false,
                pusherRegistered: false,
                errorDetails: "PKPushRegistry did not provide a token"
            )
        }
        
        // Check if we have a user session
        guard userSession != nil else {
            return VoIPPusherTestResult(
                success: false,
                message: "No user session available. Please log in first.",
                tokenReceived: true,
                pusherRegistered: false,
                errorDetails: "User session is nil"
            )
        }
        
        // Try to register the pusher
        let registrationSuccess = await registerVoIPPusher(with: tokenData)
        
        return VoIPPusherTestResult(
            success: registrationSuccess,
            message: registrationSuccess ? "VoIP pusher registered successfully!" : "VoIP pusher registration failed.",
            tokenReceived: true,
            pusherRegistered: registrationSuccess,
            errorDetails: registrationSuccess ? nil : "Check logs for detailed error"
        )
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
        self.voipTokenData = pushCredentials.token
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
        
        MXLog.info("[NotificationManager] 📥 Received VoIP push notification")
        MXLog.debug("[NotificationManager] VoIP payload: \(payload.dictionaryPayload)")
        
        // CRITICAL: According to Apple's requirements since iOS 13, we MUST report 
        // incoming VoIP push notifications to CallKit immediately within this method
        handleVoIPPushNotification(payload: payload.dictionaryPayload, completion: completion)
    }
    
    private func handleVoIPPushNotification(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        // Extract call information from push payload
        guard let roomId = extractRoomId(from: payload),
              let callId = extractCallId(from: payload) else {
            MXLog.error("[NotificationManager] ❌ Invalid VoIP push payload - missing room/call ID")
            completion()
            return
        }
        
        let callerName = extractCallerName(from: payload) ?? "Unknown Caller"
        let hasVideo = extractHasVideo(from: payload)
        
        MXLog.info("[NotificationManager] 📞 Processing VoIP call: Room=\(roomId), Caller=\(callerName), Video=\(hasVideo)")
        
        // CRITICAL: Report to CallKit immediately (synchronously required by Apple)
        // Apple requires that we report the call to CallKit before this method returns
        // otherwise the app will be terminated
        
        guard let delegate = delegate else {
            MXLog.error("[NotificationManager] ❌ No delegate available to handle VoIP push")
            completion()
            return
        }
        
        // Use a semaphore to make the async call synchronous as required by Apple
        let semaphore = DispatchSemaphore(value: 0)
        
        Task {
            await delegate.handleVoIPPushNotification(
                roomId: roomId,
                callId: callId,
                callerName: callerName,
                hasVideo: hasVideo
            )
            MXLog.info("[NotificationManager] ✅ VoIP call reported to CallKit via delegate")
            semaphore.signal()
        }
        
        // Wait for CallKit registration to complete (with timeout)
        let result = semaphore.wait(timeout: .now() + 5.0)
        
        if result == .timedOut {
            MXLog.error("[NotificationManager] ❌ CallKit registration timed out!")
        }
        
        completion()
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
        self.voipTokenData = nil
    }
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol { }
