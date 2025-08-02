//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CallKit
import MatrixRustSDK
import UserNotifications

class NotificationHandler {
    private let userSession: NSEUserSession
    private let settings: CommonSettingsProtocol
    private let contentHandler: (UNNotificationContent) -> Void
    private var notificationContent: UNMutableNotificationContent
    private let tag: String
    
    private let notificationContentBuilder: NotificationContentBuilder
    
    // periphery:ignore - required for instance retention in the rust codebase
    private var roomInfoObservationToken: TaskHandle?
    
    init(userSession: NSEUserSession,
         settings: CommonSettingsProtocol,
         contentHandler: @escaping (UNNotificationContent) -> Void,
         notificationContent: UNMutableNotificationContent,
         tag: String) {
        self.userSession = userSession
        self.settings = settings
        self.contentHandler = contentHandler
        self.notificationContent = notificationContent
        self.tag = tag
        
        let eventStringBuilder = RoomMessageEventStringBuilder(attributedStringBuilder: AttributedStringBuilder(mentionBuilder: PlainMentionBuilder()),
                                                               destination: .notification)
        
        notificationContentBuilder = NotificationContentBuilder(messageEventStringBuilder: eventStringBuilder,
                                                                userSession: userSession)
    }
    
    func processEvent(_ eventID: String, roomID: String) async {
        MXLog.info("\(tag) Processing event: \(eventID) in room: \(roomID)")
        MXLog.info("\(tag) Notification userInfo: \(notificationContent.userInfo)")
        
        // ИСПРАВЛЕНИЕ ДУБЛИРОВАНИЯ BADGE: Не переопределяем badge из push service
        // Push service уже установил правильный badge count
        MXLog.info("[NotificationHandler] Original badge from push: \(notificationContent.badge?.intValue ?? -1)")
        MXLog.info("[NotificationHandler] UnreadCount from notification: \(notificationContent.unreadCount)")
        
        // Позволяем push service управлять badge count вместо NSE
        // notificationContent.badge остается как установлен в push payload
        
        guard let notificationItemProxy = await userSession.notificationItemProxy(roomID: roomID, eventID: eventID) else {
            MXLog.error("\(tag) Failed retrieving notification item")
            discardNotification()
            return
        }
        
        let processingResult = await preprocessNotification(notificationItemProxy)
        MXLog.info("\(tag) 📊 PROCESSING RESULT: \(processingResult)")
        
        switch processingResult {
        case .processedShouldDiscard:
            MXLog.info("\(tag) 🚫 DISCARDING notification: processedShouldDiscard")
            discardNotification()
        case .unsupportedShouldDiscard:
            MXLog.info("\(tag) 🚫 DISCARDING notification: unsupportedShouldDiscard")
            discardNotification()
        case .shouldDisplay:
            MXLog.info("\(tag) ✅ DISPLAYING notification")
            await notificationContentBuilder.process(notificationContent: &notificationContent,
                                                     notificationItem: notificationItemProxy,
                                                     mediaProvider: userSession.mediaProvider)
            
            deliverNotification()
        }
    }
    
    func handleTimeExpiration() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content
        MXLog.info("\(tag) Extension time will expire")
        deliverNotification()
    }
    
    // MARK: - Private
    
    private func deliverNotification() {
        MXLog.info("\(tag) 📤 DELIVERING notification:")
        MXLog.info("\(tag) - Title: '\(notificationContent.title)'")
        MXLog.info("\(tag) - Body: '\(notificationContent.body)'")
        MXLog.info("\(tag) - Badge: \(notificationContent.badge ?? 0)")
        MXLog.info("\(tag) - Sound: \(String(describing: notificationContent.sound))")
        MXLog.info("\(tag) - User Info: \(notificationContent.userInfo)")
        contentHandler(notificationContent)
    }

    private func discardNotification() {
        MXLog.info("\(tag) 🗑️ DISCARDING notification (but preserving badge)")
        
        let content = UNMutableNotificationContent()
        // ИСПРАВЛЕНИЕ: При отмене уведомления не изменяем badge
        // content.badge = notificationContent.badge // Сохраняем оригинальный badge
        MXLog.info("\(tag) - Original badge preserved: \(notificationContent.badge ?? 0)")
        
        contentHandler(content)
    }
    
    private func preprocessNotification(_ itemProxy: NotificationItemProxyProtocol) async -> NotificationProcessingResult {
        MXLog.info("\(tag) 🔍 PREPROCESSING NOTIFICATION:")
        MXLog.info("\(tag) - hideQuietNotificationAlerts: \(settings.hideQuietNotificationAlerts)")
        MXLog.info("\(tag) - itemProxy.isNoisy: \(itemProxy.isNoisy)")
        MXLog.info("\(tag) - Room ID: \(itemProxy.roomID)")
        MXLog.info("\(tag) - Event type: \(String(describing: itemProxy.event))")
        
        if settings.hideQuietNotificationAlerts, !itemProxy.isNoisy {
            MXLog.info("\(tag) ❌ DISCARDING: Hide quiet alerts is ON and notification is not noisy")
            return .processedShouldDiscard
        }
        
        guard case let .timeline(event) = itemProxy.event else {
            MXLog.info("\(tag) ✅ Non-timeline event, should display")
            return .shouldDisplay
        }
        
        switch try? event.eventType() {
        case .messageLike(let content):
            switch content {
            case .poll,
                 .roomEncrypted,
                 .sticker:
                return .shouldDisplay
            case .roomMessage(let messageType, _):
                MXLog.info("\(tag) 💬 Room message type: \(messageType)")
                switch messageType {
                case .emote, .image, .audio, .video, .file, .notice, .text, .location, .gallery:
                    MXLog.info("\(tag) ✅ Supported message type, should display")
                    return .shouldDisplay
                case .other:
                    MXLog.info("\(tag) ❌ Unsupported message type, discarding")
                    return .unsupportedShouldDiscard
                }
            case .roomRedaction(let redactedEventID, _):
                guard let redactedEventID else {
                    MXLog.error("Unable to handle redact notification due to missing event ID")
                    return .processedShouldDiscard
                }
                
                let deliveredNotifications = await UNUserNotificationCenter.current().deliveredNotifications()
                
                if let targetNotification = deliveredNotifications.first(where: { $0.request.content.eventID == redactedEventID }) {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [targetNotification.request.identifier])
                }
                
                return .processedShouldDiscard
            case .callNotify(let notifyType):
                // Always trigger VoIP push for incoming calls
                if notifyType == .ring {
                    MXLog.info("Received ring notification, triggering VoIP push")
                    return await handleCallNotification(notifyType: notifyType,
                                                        timestamp: event.timestamp(),
                                                        roomID: itemProxy.roomID,
                                                        roomDisplayName: itemProxy.roomDisplayName,
                                                        notificationItemProxy: itemProxy)
                } else {
                    // For other call notifications, show as regular push
                    return .shouldDisplay
                }
            case .callAnswer,
                 .callHangup,
                 .callCandidates:
                // These are VoIP-related events that should not show regular notifications
                MXLog.info("Received VoIP call event: \(content), discarding regular notification")
                
                // Передаем событие в основное приложение через App Group
                sendVoIPEventToMainApp(eventType: "\(content)",
                                       roomId: itemProxy.roomID,
                                       eventId: event.eventId())
                
                return .processedShouldDiscard
            case .callInvite:
                // m.call.invite should trigger VoIP push, not regular notification
                MXLog.info("Received m.call.invite, should be handled by VoIP push")
                return await handleVoIPCallEvent(eventId: event.eventId(),
                                                 timestamp: event.timestamp(),
                                                 roomID: itemProxy.roomID,
                                                 roomDisplayName: itemProxy.roomDisplayName,
                                                 notificationItemProxy: itemProxy)
            case .keyVerificationReady,
                 .keyVerificationStart,
                 .keyVerificationCancel,
                 .keyVerificationAccept,
                 .keyVerificationKey,
                 .keyVerificationMac,
                 .keyVerificationDone,
                 .reactionContent:
                return .unsupportedShouldDiscard
            }
        case .state:
            return .unsupportedShouldDiscard
        case .none:
            return .unsupportedShouldDiscard
        }
    }
    
    /// Handle incoming call notifications.
    /// - Returns: A boolean indicating whether the notification was handled and should now be discarded.
    private func handleCallNotification(notifyType: NotifyType,
                                        timestamp: Timestamp,
                                        roomID: String,
                                        roomDisplayName: String,
                                        notificationItemProxy: NotificationItemProxyProtocol) async -> NotificationProcessingResult {
        // Handle incoming VoIP calls, show the native OS call screen
        // https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls
        //
        // The way this works is the following:
        // - the NSE receives the notification and decrypts it
        // - checks if it's still time relevant (max 10 seconds old) and whether it should ring
        // - otherwise it goes on to show it as a normal notification
        // - if it should ring then it discards the notification but invokes `reportNewIncomingVoIPPushPayload`
        // so that the main app can handle it
        // - the main app picks this up in `PKPushRegistry.didReceiveIncomingPushWith` and
        // `CXProvider.reportNewIncomingCall` to show the system UI and handle actions on it.
        // N.B. this flow works properly only when background processing capabilities are enabled
        guard notifyType == .ring else {
            MXLog.info("Non-ringing call notification, handling as push notification")
            return .shouldDisplay
        }
        
        // Check to see if a call is still ongoing
        if let room = userSession.roomForIdentifier(roomID) { // Try to get call details from the room info
            if !room.hasActiveRoomCall() { // If I don't have an active call wait a bit and make sure
                let expiringTask = ExpiringTaskRunner {
                    await withCheckedContinuation { [weak self] continuation in
                        self?.roomInfoObservationToken = room.subscribeToRoomInfoUpdates(listener: SDKListener { info in
                            if info.hasRoomCall {
                                MXLog.info("Received room info update and the room has an active call now.")
                                continuation.resume()
                            } else {
                                MXLog.info("Received a room info update but the room still doesn't have an ongoing call.")
                            }
                        })
                    }
                }
                
                try? await expiringTask.run(timeout: .seconds(5)) // Wait 5 seconds or just use whatever is available
                
                guard room.hasActiveRoomCall() else {
                    MXLog.info("The room no longer has an ongoing call, handling as push notification")
                    return .shouldDisplay
                }
            }
        } else { // Otherwise fallback to the old timeout mechanism
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestamp / 1000))
            
            guard abs(timestamp.timeIntervalSinceNow) < ElementCallServiceNotificationDiscardDelta else {
                MXLog.info("Call notification is too old, handling as push notification")
                return .shouldDisplay
            }
        }
        
        // Create enhanced payload with LiveKit credentials for auto-connect
        var payload = [ElementCallServiceNotificationKey.roomID.rawValue: roomID,
                       ElementCallServiceNotificationKey.roomDisplayName.rawValue: roomDisplayName]
        
        // Add LiveKit credentials to payload if available
        let liveKitCredentials = await extractLiveKitCredentialsFromMatrixEvent(notificationItemProxy)
        if let accessToken = liveKitCredentials.accessToken, !accessToken.isEmpty {
            payload["livekit_access_token"] = accessToken
            MXLog.info("[NSE-CREDENTIALS] Added LiveKit access token to CallKit payload")
        }
        if let serverURL = liveKitCredentials.serverURL, !serverURL.isEmpty {
            payload["livekit_server_url"] = serverURL
            MXLog.info("[NSE-CREDENTIALS] Added LiveKit server URL to CallKit payload: \(serverURL)")
        }
        if let roomURL = liveKitCredentials.roomURL, !roomURL.isEmpty {
            payload["livekit_room_url"] = roomURL
            MXLog.info("[NSE-CREDENTIALS] Added LiveKit room URL to CallKit payload")
        }
        
        do {
            try await CXProvider.reportNewIncomingVoIPPushPayload(payload)
            MXLog.info("Call notification delegated to CallKit successfully")
            
            // Additionally ensure the main app is awakened
            // This is critical for LiveKit calls
            NotificationCenter.default.post(name: Notification.Name("io.element.call.incoming"),
                                            object: nil,
                                            userInfo: payload)
        } catch let error as NSError {
            MXLog.error("Failed reporting voip call with error: \(error.localizedDescription) (domain: \(error.domain), code: \(error.code))")
            
            // Fallback: Show notification with custom actions for calls
            if #available(iOS 15.0, *) {
                notificationContent.interruptionLevel = .timeSensitive
            }
            notificationContent.categoryIdentifier = "INCOMING_CALL"
            notificationContent.title = "Входящий вызов от \(roomDisplayName.isEmpty ? "Unknown" : roomDisplayName)"
            notificationContent.body = "Коснитесь для ответа"
            notificationContent.sound = UNNotificationSound(named: UNNotificationSoundName("ringtone.caf"))
            
            return .shouldDisplay
        } catch {
            MXLog.error("Failed reporting voip call with unknown error: \(error)")
            return .shouldDisplay
        }
        
        return .processedShouldDiscard
    }
    
    /// Handle VoIP call events (m.call.invite, etc.) with improved error handling
    private func handleVoIPCallEvent(eventId: String,
                                     timestamp: Timestamp,
                                     roomID: String,
                                     roomDisplayName: String,
                                     notificationItemProxy: NotificationItemProxyProtocol) async -> NotificationProcessingResult {
        MXLog.info("[NSE-RESILIENT] Handling VoIP call event in room: \(roomID)")
        
        // Check if this is a recent call invite (within 30 seconds)
        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestamp / 1000))
        let maxAge: TimeInterval = 30.0 // 30 seconds
        
        if abs(eventDate.timeIntervalSinceNow) > maxAge {
            MXLog.info("[NSE-RESILIENT] VoIP call event is too old (\(abs(eventDate.timeIntervalSinceNow))s), showing as regular notification")
            return .shouldDisplay
        }
        
        // Robust payload creation with error handling
        guard !eventId.isEmpty, !roomID.isEmpty else {
            MXLog.error("[NSE-RESILIENT] Invalid VoIP event data - eventId: '\(eventId)', roomID: '\(roomID)'")
            return .shouldDisplay // Fallback to regular notification
        }
        
        // Extract LiveKit credentials from Matrix event
        let liveKitCredentials = await extractLiveKitCredentialsFromMatrixEvent(notificationItemProxy)
        
        let payload = [
            "event_id": eventId,
            "room_id": roomID,
            "sender_display_name": roomDisplayName.isEmpty ? "Unknown Caller" : roomDisplayName,
            "is_video": true, // Default to video call
            "event_type": "m.call.invite",
            // Include LiveKit credentials if available
            "livekit_access_token": liveKitCredentials.accessToken ?? "",
            "livekit_server_url": liveKitCredentials.serverURL ?? "",
            "livekit_room_url": liveKitCredentials.roomURL ?? ""
        ] as [String: Any]
        
        // Robust App Group communication with fallback
        let success = storeVoIPEventSafely(eventId: eventId,
                                           roomID: roomID,
                                           roomDisplayName: roomDisplayName,
                                           timestamp: timestamp,
                                           liveKitCredentials: liveKitCredentials)
        
        if !success {
            MXLog.error("[NSE-RESILIENT] Failed to store VoIP event, falling back to regular notification")
            return .shouldDisplay
        }
        
        // Try to wake up main app with local notification (with error handling)
        do {
            try await sendWakeupNotification(payload: payload, roomDisplayName: roomDisplayName)
        } catch {
            MXLog.error("[NSE-RESILIENT] Failed to send wakeup notification: \(error)")
            // Continue anyway - the stored event should still work
        }
        
        MXLog.info("[NSE-RESILIENT] VoIP call event processed successfully, discarding NSE notification")
        return .processedShouldDiscard
    }
    
    /// LiveKit credentials structure
    private struct LiveKitCredentials {
        let accessToken: String?
        let serverURL: String?
        let roomURL: String?
    }
    
    /// Extract LiveKit credentials from Matrix event via NotificationItemProxy
    /// CRITICAL FIX: ElementX NSE doesn't provide direct access to raw Matrix JSON,
    /// so we need to extract from the push notification payload instead
    private func extractLiveKitCredentialsFromMatrixEvent(_ itemProxy: NotificationItemProxyProtocol) async -> LiveKitCredentials {
        MXLog.info("[NSE-MATRIX-PARSE] CRITICAL: ElementX NSE has limited access to Matrix event data")
        MXLog.info("[NSE-MATRIX-PARSE] Using push notification payload as primary source")
        
        // The primary and most reliable source is the push notification payload itself
        // Matrix homeserver/Sygnal should include application_data in the push payload
        let credentialsFromPush = extractLiveKitCredentialsFromPushPayload(notificationContent.userInfo)
        
        if credentialsFromPush.accessToken != nil {
            MXLog.info("[NSE-MATRIX-PARSE] Successfully extracted credentials from push payload")
            return credentialsFromPush
        }
        
        // Secondary approach: Try to infer from event properties
        guard case let .timeline(event) = itemProxy.event else {
            MXLog.warning("[NSE-MATRIX-PARSE] Not a timeline event, falling back to push payload only")
            return credentialsFromPush
        }
        
        // Log event information for debugging
        let eventId = event.eventId()
        let timestamp = event.timestamp()
        MXLog.info("[NSE-MATRIX-PARSE] Event ID: \(eventId), Timestamp: \(timestamp)")
        
        // Since ElementX doesn't expose raw event content in NSE,
        // we rely on the homeserver/Sygnal to include application_data in push payload
        MXLog.warning("[NSE-MATRIX-PARSE] ElementX limitation: Cannot access application_data directly from event")
        MXLog.info("[NSE-MATRIX-PARSE] Ensure your Matrix homeserver/Sygnal includes application_data in push notifications")
        
        return credentialsFromPush
    }
    
    /// Extract LiveKit credentials from notification userInfo (enhanced version)
    private func extractLiveKitCredentialsFromNotificationUserInfo() -> LiveKitCredentials {
        // Get userInfo from the current notification content
        let userInfo = notificationContent.userInfo
        
        MXLog.info("[NSE-MATRIX-PARSE] Using enhanced push payload extraction")
        
        // Use the enhanced extraction method
        return extractLiveKitCredentialsFromPushPayload(userInfo)
    }
    
    /// Extract value from nested application_data JSON (enhanced version)
    private func extractFromApplicationData(_ userInfo: [AnyHashable: Any], key: String) -> String? {
        MXLog.info("[NSE-APPLICATION-DATA] Searching for key '\(key)' in application_data")
        
        // Method 1: Try to parse application_data if it exists as a JSON string
        if let applicationDataString = userInfo["application_data"] as? String {
            MXLog.info("[NSE-APPLICATION-DATA] Found application_data as string, parsing JSON")
            if let data = applicationDataString.data(using: .utf8),
               let applicationData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let value = applicationData[key] as? String
                MXLog.info("[NSE-APPLICATION-DATA] Extracted '\(key)' from JSON string: \(value != nil ? "[FOUND]" : "[NOT FOUND]")")
                return value
            }
        }
        
        // Method 2: Try to access application_data as a dictionary
        if let applicationData = userInfo["application_data"] as? [String: Any] {
            MXLog.info("[NSE-APPLICATION-DATA] Found application_data as dictionary")
            let value = applicationData[key] as? String
            MXLog.info("[NSE-APPLICATION-DATA] Extracted '\(key)' from dictionary: \(value != nil ? "[FOUND]" : "[NOT FOUND]")")
            return value
        }
        
        // Method 3: Look for Matrix event structure
        if let content = userInfo["content"] as? [String: Any],
           let applicationData = content["application_data"] as? [String: Any] {
            MXLog.info("[NSE-APPLICATION-DATA] Found application_data in content structure")
            let value = applicationData[key] as? String
            MXLog.info("[NSE-APPLICATION-DATA] Extracted '\(key)' from content.application_data: \(value != nil ? "[FOUND]" : "[NOT FOUND]")")
            return value
        }
        
        // Method 4: Deep search in nested structures
        if let eventContent = userInfo["event"] as? [String: Any],
           let content = eventContent["content"] as? [String: Any],
           let applicationData = content["application_data"] as? [String: Any] {
            MXLog.info("[NSE-APPLICATION-DATA] Found application_data in event.content structure")
            let value = applicationData[key] as? String
            MXLog.info("[NSE-APPLICATION-DATA] Extracted '\(key)' from event.content.application_data: \(value != nil ? "[FOUND]" : "[NOT FOUND]")")
            return value
        }
        
        MXLog.warning("[NSE-APPLICATION-DATA] Key '\(key)' not found in any application_data structure")
        return nil
    }
    
    /// Enhanced method to extract LiveKit credentials from Matrix push payload
    private func extractLiveKitCredentialsFromPushPayload(_ userInfo: [AnyHashable: Any]) -> LiveKitCredentials {
        MXLog.info("[NSE-PUSH-EXTRACT] Starting enhanced extraction from push payload")
        MXLog.info("[NSE-PUSH-EXTRACT] Available keys: \(userInfo.keys.map { String(describing: $0) }.joined(separator: ", "))")
        
        // Look for LiveKit data patterns
        let liveKitKeys = ["lk_token", "livekit_access_token", "access_token"]
        let serverKeys = ["lk_url", "livekit_server_url", "server_url", "url"]
        let roomKeys = ["lk_room", "livekit_room_url", "room_url"]
        
        var accessToken: String?
        var serverURL: String?
        var roomURL: String?
        
        // Try different key patterns
        for key in liveKitKeys {
            if let token = userInfo[key] as? String ?? extractFromApplicationData(userInfo, key: key) {
                accessToken = token
                MXLog.info("[NSE-PUSH-EXTRACT] Found access token with key '\(key)'")
                break
            }
        }
        
        for key in serverKeys {
            if let url = userInfo[key] as? String ?? extractFromApplicationData(userInfo, key: key) {
                serverURL = url
                MXLog.info("[NSE-PUSH-EXTRACT] Found server URL with key '\(key)': \(url)")
                break
            }
        }
        
        for key in roomKeys {
            if let url = userInfo[key] as? String ?? extractFromApplicationData(userInfo, key: key) {
                roomURL = url
                MXLog.info("[NSE-PUSH-EXTRACT] Found room URL with key '\(key)'")
                break
            }
        }
        
        // Default server URL if none found
        if serverURL == nil || serverURL?.isEmpty == true {
            serverURL = "wss://video.aibots.kz"
            MXLog.info("[NSE-PUSH-EXTRACT] Using default server URL: \(serverURL!)")
        }
        
        MXLog.info("[NSE-PUSH-EXTRACT] Final extraction result - Token: \(accessToken != nil ? "[PRESENT]" : "[MISSING]"), Server: \(serverURL ?? "[MISSING]"), Room: \(roomURL ?? "[MISSING]")")
        
        return LiveKitCredentials(accessToken: accessToken,
                                  serverURL: serverURL,
                                  roomURL: roomURL)
    }
    
    /// Safely store VoIP event data with error handling
    private func storeVoIPEventSafely(eventId: String, roomID: String, roomDisplayName: String, timestamp: Timestamp, liveKitCredentials: LiveKitCredentials) -> Bool {
        guard let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") else {
            MXLog.error("[NSE-RESILIENT] Failed to access App Group UserDefaults")
            return false
        }
        
        let voipEventData: [String: Any] = [
            "event_id": eventId,
            "room_id": roomID,
            "sender_display_name": roomDisplayName.isEmpty ? "Unknown Caller" : roomDisplayName,
            "is_video": true,
            "event_type": "m.call.invite",
            "timestamp": timestamp,
            "processed_at": Date().timeIntervalSince1970,
            "nse_version": "1.0", // For debugging
            "processing_attempt": 1,
            // Include LiveKit credentials
            "livekit_access_token": liveKitCredentials.accessToken ?? "",
            "livekit_server_url": liveKitCredentials.serverURL ?? "",
            "livekit_room_url": liveKitCredentials.roomURL ?? ""
        ]
        
        appGroupDefaults.set(voipEventData, forKey: "pending_voip_event")
        
        // Multiple synchronization attempts for reliability
        var syncSuccess = false
        for attempt in 1...3 {
            if appGroupDefaults.synchronize() {
                syncSuccess = true
                break
            } else {
                MXLog.warning("[NSE-RESILIENT] App Group sync attempt \(attempt) failed")
                usleep(10000) // 10ms delay
            }
        }
        
        if syncSuccess {
            MXLog.info("[NSE-RESILIENT] VoIP event stored successfully")
            return true
        } else {
            MXLog.error("[NSE-RESILIENT] All App Group sync attempts failed")
            return false
        }
    }
    
    /// Send wakeup notification with error handling
    private func sendWakeupNotification(payload: [String: Any], roomDisplayName: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Входящий вызов от \(roomDisplayName.isEmpty ? "Unknown" : roomDisplayName)"
        content.body = "Коснитесь для ответа"
        content.categoryIdentifier = "VOIP_CALL"
        content.userInfo = payload
        
        // Use time-sensitive notification (iOS 15+)
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        
        // Set custom sound for call notifications
        content.sound = UNNotificationSound.defaultCritical
        
        // Schedule notification with unique identifier
        let request = UNNotificationRequest(identifier: "voip_wakeup_\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil // Immediate delivery
        )
        
        try await UNUserNotificationCenter.current().add(request)
        MXLog.info("[NSE-RESILIENT] Wakeup notification scheduled")
    }
    
    /// Отправка VoIP событий в основное приложение через App Group (с улучшенной обработкой ошибок)
    private func sendVoIPEventToMainApp(eventType: String, roomId: String, eventId: String) {
        MXLog.info("[NSE-RESILIENT] Sending VoIP event '\(eventType)' for room: \(roomId)")
        
        guard let appGroupDefaults = UserDefaults(suiteName: "group.io.kdbchat") else {
            MXLog.error("[NSE-RESILIENT] Failed to access App Group for VoIP event")
            return
        }
        
        // Создаём надёжные данные события
        let voipEventData: [String: Any] = [
            "event_type": eventType.isEmpty ? "unknown" : eventType,
            "event_id": eventId.isEmpty ? UUID().uuidString : eventId,
            "room_id": roomId.isEmpty ? "unknown_room" : roomId,
            "timestamp": Date().timeIntervalSince1970,
            "source": "nse",
            "nse_version": "1.0",
            "retry_count": 0
        ]
        
        // Попытка сохранения с повторными попытками
        var saveSuccess = false
        for attempt in 1...3 {
            appGroupDefaults.set(voipEventData, forKey: "latest_voip_event")
            
            if appGroupDefaults.synchronize() {
                saveSuccess = true
                MXLog.info("[NSE-RESILIENT] VoIP event saved successfully on attempt \(attempt)")
                break
            } else {
                MXLog.warning("[NSE-RESILIENT] App Group sync failed on attempt \(attempt)")
            }
            
            if attempt < 3 {
                usleep(20000) // 20ms delay between attempts
            }
        }
        
        if !saveSuccess {
            MXLog.error("[NSE-RESILIENT] All attempts to save VoIP event failed")
            return
        }
        
        // Дополнительная отправка для macOS (если доступно)
        #if os(macOS)
        do {
            let notificationName = Notification.Name("VoIPEventFromNSE")
            DistributedNotificationCenter.default().postNotificationName(notificationName,
                                                                         object: nil,
                                                                         userInfo: voipEventData,
                                                                         deliverImmediately: true)
            MXLog.info("[NSE-RESILIENT] DistributedNotificationCenter message sent")
        } catch {
            MXLog.error("[NSE-RESILIENT] Failed to send DistributedNotificationCenter message: \(error)")
        }
        #endif
        
        MXLog.info("[NSE-RESILIENT] 📞 VoIP event '\(eventType)' successfully sent to main app for room: \(roomId)")
    }
    
    private enum NotificationProcessingResult {
        case shouldDisplay
        case processedShouldDiscard
        case unsupportedShouldDiscard
    }
}
