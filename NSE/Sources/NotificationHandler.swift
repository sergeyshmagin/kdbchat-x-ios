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
        
        // Copy over the unread information to the notification badge
        notificationContent.badge = notificationContent.unreadCount as NSNumber?
        
        guard let notificationItemProxy = await userSession.notificationItemProxy(roomID: roomID, eventID: eventID) else {
            MXLog.error("\(tag) Failed retrieving notification item")
            discardNotification()
            return
        }
        
        switch await preprocessNotification(notificationItemProxy) {
        case .processedShouldDiscard, .unsupportedShouldDiscard:
            discardNotification()
        case .shouldDisplay:
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
        MXLog.info("\(tag) Delivering notification")
        contentHandler(notificationContent)
    }

    private func discardNotification() {
        MXLog.info("\(tag) Discarding notification")
        
        let content = UNMutableNotificationContent()
        content.badge = notificationContent.unreadCount as NSNumber?
        
        contentHandler(content)
    }
    
    private func preprocessNotification(_ itemProxy: NotificationItemProxyProtocol) async -> NotificationProcessingResult {
        if settings.hideQuietNotificationAlerts, !itemProxy.isNoisy {
            return .processedShouldDiscard
        }
        
        guard case let .timeline(event) = itemProxy.event else {
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
                switch messageType {
                case .emote, .image, .audio, .video, .file, .notice, .text, .location, .gallery:
                    return .shouldDisplay
                case .other:
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
                                                        roomDisplayName: itemProxy.roomDisplayName)
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
                                               roomDisplayName: itemProxy.roomDisplayName)
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
                                        roomDisplayName: String) async -> NotificationProcessingResult {
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
        
        let payload = [ElementCallServiceNotificationKey.roomID.rawValue: roomID,
                       ElementCallServiceNotificationKey.roomDisplayName.rawValue: roomDisplayName]
        
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
            notificationContent.title = "Incoming Call"
            notificationContent.body = "Call from \(roomDisplayName)"
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
                                   roomDisplayName: String) async -> NotificationProcessingResult {
        MXLog.info("[NSE-RESILIENT] Handling VoIP call event in room: \(roomID)")
        
        do {
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
            
            let payload = [
                "event_id": eventId,
                "room_id": roomID,
                "sender_display_name": roomDisplayName.isEmpty ? "Unknown Caller" : roomDisplayName,
                "is_video": true, // Default to video call
                "event_type": "m.call.invite"
            ] as [String: Any]
            
            // Robust App Group communication with fallback
            let success = storeVoIPEventSafely(eventId: eventId, 
                                             roomID: roomID, 
                                             roomDisplayName: roomDisplayName, 
                                             timestamp: timestamp)
            
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
            
        } catch {
            MXLog.error("[NSE-RESILIENT] Unexpected error handling VoIP event: \(error)")
            // Ultimate fallback - show as regular notification
            return .shouldDisplay
        }
    }
    
    /// Safely store VoIP event data with error handling
    private func storeVoIPEventSafely(eventId: String, roomID: String, roomDisplayName: String, timestamp: Timestamp) -> Bool {
        do {
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
                "processing_attempt": 1
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
            
        } catch {
            MXLog.error("[NSE-RESILIENT] Exception storing VoIP event: \(error)")
            return false
        }
    }
    
    /// Send wakeup notification with error handling
    private func sendWakeupNotification(payload: [String: Any], roomDisplayName: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Incoming Call"
        content.body = "Call from \(roomDisplayName.isEmpty ? "Unknown" : roomDisplayName)"
        content.categoryIdentifier = "VOIP_CALL"
        content.userInfo = payload
        
        // Use time-sensitive notification (iOS 15+)
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        
        // Set custom sound for call notifications
        content.sound = UNNotificationSound.defaultCritical
        
        // Schedule notification with unique identifier
        let request = UNNotificationRequest(
            identifier: "voip_wakeup_\(UUID().uuidString)",
            content: content,
            trigger: nil // Immediate delivery
        )
        
        try await UNUserNotificationCenter.current().add(request)
        MXLog.info("[NSE-RESILIENT] Wakeup notification scheduled")
    }
    
    /// Отправка VoIP событий в основное приложение через App Group (с улучшенной обработкой ошибок)
    private func sendVoIPEventToMainApp(eventType: String, roomId: String, eventId: String) {
        MXLog.info("[NSE-RESILIENT] Sending VoIP event '\(eventType)' for room: \(roomId)")
        
        do {
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
                do {
                    appGroupDefaults.set(voipEventData, forKey: "latest_voip_event")
                    
                    if appGroupDefaults.synchronize() {
                        saveSuccess = true
                        MXLog.info("[NSE-RESILIENT] VoIP event saved successfully on attempt \(attempt)")
                        break
                    } else {
                        MXLog.warning("[NSE-RESILIENT] App Group sync failed on attempt \(attempt)")
                    }
                } catch {
                    MXLog.error("[NSE-RESILIENT] Exception saving VoIP event on attempt \(attempt): \(error)")
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
            
        } catch {
            MXLog.error("[NSE-RESILIENT] Unexpected error sending VoIP event: \(error)")
        }
    }
    
    private enum NotificationProcessingResult {
        case shouldDisplay
        case processedShouldDiscard
        case unsupportedShouldDiscard
    }
}
