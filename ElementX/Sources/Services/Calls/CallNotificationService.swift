//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit
import UserNotifications

/// Service for managing call-related notifications and badges
/// КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Добавлен @MainActor для thread safety
@MainActor
public final class CallNotificationService: NSObject {
    public static let shared = CallNotificationService()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    private var scheduledMissedCallNotifications: Set<String> = []
    
    override private init() {
        super.init()
        setupNotificationCategories()
    }
    
    // MARK: - Missed Call Notifications
    
    /// Schedule a missed call notification
    public func scheduleMissedCallNotification(callId: String, callerName: String, roomId: String, timestamp: Date) async {
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Thread-safe проверка дубликатов
        guard !scheduledMissedCallNotifications.contains(callId) else {
            MXLog.info("[CallNotificationService] Missed call notification already scheduled for: \(callId)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "Пропущенный звонок"
        content.body = callerName.isEmpty ? "Неизвестный абонент" : "от \(callerName)"
        content.sound = .default
        content.categoryIdentifier = "MISSED_CALL"
        
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive // Non-critical notification
            content.relevanceScore = 0.8 // High relevance for missed calls
        }
        
        // Add custom data for handling
        content.userInfo = [
            "call_id": callId,
            "room_id": roomId,
            "caller_name": callerName,
            "timestamp": timestamp.timeIntervalSince1970,
            "notification_type": "missed_call"
        ]
        
        // Schedule notification with slight delay to avoid conflicts with CallKit
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2.0, repeats: false)
        let request = UNNotificationRequest(identifier: "missed_call_\(callId)",
                                            content: content,
                                            trigger: trigger)
        
        do {
            try await notificationCenter.add(request)
            // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Thread-safe обновление Set
            scheduledMissedCallNotifications.insert(callId)
            
            MXLog.info("[CallNotificationService] ✅ Scheduled missed call notification: \(callId) from \(callerName)")
            
            // Update badge count
            await updateCallBadgeCount()
            
        } catch {
            MXLog.error("[CallNotificationService] ❌ Failed to schedule missed call notification: \(error)")
        }
    }
    
    /// Remove missed call notification (if user returns the call or clears it)
    func removeMissedCallNotification(callId: String) async {
        let identifiers = ["missed_call_\(callId)"]
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Thread-safe удаление из Set
        scheduledMissedCallNotifications.remove(callId)
        
        MXLog.info("[CallNotificationService] 🗑️ Removed missed call notification: \(callId)")
        
        // Update badge count
        await updateCallBadgeCount()
    }
    
    /// Clear all missed call notifications
    func clearAllMissedCallNotifications() async {
        let identifiers = scheduledMissedCallNotifications.map { "missed_call_\($0)" }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Thread-safe очистка Set
        scheduledMissedCallNotifications.removeAll()
        
        MXLog.info("[CallNotificationService] 🧹 Cleared all missed call notifications")
        
        // Update badge count
        await updateCallBadgeCount()
    }
    
    // MARK: - Badge Management
    
    /// Update app badge count based on missed calls and other unread items
    func updateCallBadgeCount() async {
        let missedCallCount = scheduledMissedCallNotifications.count
        
        // Get current badge count (may include other unread items)
        let currentBadgeCount = UIApplication.shared.applicationIconBadgeNumber
        
        // For now, we'll just add missed calls to the badge
        // In a full implementation, you'd want to coordinate with other notification sources
        let newBadgeCount = max(0, currentBadgeCount + missedCallCount)
        
        UIApplication.shared.applicationIconBadgeNumber = newBadgeCount
        
        MXLog.info("[CallNotificationService] 📱 Updated badge count: \(newBadgeCount) (missed calls: \(missedCallCount))")
    }
    
    /// Clear call-related badge count
    func clearCallBadgeCount() async {
        let missedCallCount = scheduledMissedCallNotifications.count
        let currentBadgeCount = UIApplication.shared.applicationIconBadgeNumber
        let newBadgeCount = max(0, currentBadgeCount - missedCallCount)
        
        UIApplication.shared.applicationIconBadgeNumber = newBadgeCount
        
        MXLog.info("[CallNotificationService] 🧹 Cleared call badge count: \(newBadgeCount)")
    }
    
    // MARK: - Call Status Notifications
    
    /// Show notification when call is answered on another device
    func scheduleCallAnsweredElsewhereNotification(callerName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Звонок принят на другом устройстве"
        content.body = callerName.isEmpty ? "Неизвестный абонент" : "от \(callerName)"
        content.sound = .default
        
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
        }
        
        let request = UNNotificationRequest(identifier: "call_answered_elsewhere_\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil // Immediate
        )
        
        do {
            try await notificationCenter.add(request)
            MXLog.info("[CallNotificationService] ✅ Scheduled 'answered elsewhere' notification")
        } catch {
            MXLog.error("[CallNotificationService] ❌ Failed to schedule 'answered elsewhere' notification: \(error)")
        }
    }
    
    /// Show notification when call ends normally
    func scheduleCallEndedNotification(participantName: String, duration: TimeInterval) async {
        // Only show for short calls that might indicate issues
        guard duration < 10 else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Звонок завершен"
        content.body = participantName.isEmpty ? "Звонок длился \(Int(duration)) сек." : "Звонок с \(participantName) длился \(Int(duration)) сек."
        content.sound = .default
        
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
        }
        
        let request = UNNotificationRequest(identifier: "call_ended_\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil // Immediate
        )
        
        do {
            try await notificationCenter.add(request)
            MXLog.info("[CallNotificationService] ✅ Scheduled call ended notification")
        } catch {
            MXLog.error("[CallNotificationService] ❌ Failed to schedule call ended notification: \(error)")
        }
    }
    
    // MARK: - Setup
    
    private func setupNotificationCategories() {
        // Missed call category with actions
        let callBackAction = UNNotificationAction(identifier: "CALL_BACK",
                                                  title: "Перезвонить",
                                                  options: [.foreground])
        
        let messageAction = UNNotificationAction(identifier: "SEND_MESSAGE",
                                                 title: "Сообщение",
                                                 options: [.foreground])
        
        let missedCallCategory = UNNotificationCategory(identifier: "MISSED_CALL",
                                                        actions: [callBackAction, messageAction],
                                                        intentIdentifiers: [],
                                                        options: [.customDismissAction])
        
        // Register categories
        notificationCenter.setNotificationCategories([missedCallCategory])
        
        MXLog.info("[CallNotificationService] ✅ Notification categories configured")
    }
    
    // MARK: - Analytics and Statistics
    
    /// Get missed call statistics
    func getMissedCallStatistics() -> MissedCallStatistics {
        let pendingCount = scheduledMissedCallNotifications.count
        
        return MissedCallStatistics(pendingMissedCalls: pendingCount,
                                    totalScheduledToday: 0, // Would need persistent storage to track
                                    averageResponseTime: 0 // Would need to track user interactions
        )
    }
    
    /// Handle missed call notification interaction
    func handleMissedCallNotificationAction(action: String, callId: String, roomId: String, callerName: String) async {
        MXLog.info("[CallNotificationService] Handling missed call action: \(action) for call: \(callId)")
        
        switch action {
        case "CALL_BACK":
            // Would integrate with call initiation logic
            MXLog.info("[CallNotificationService] User wants to call back: \(callerName)")
            await removeMissedCallNotification(callId: callId)
            
        case "SEND_MESSAGE":
            // Would integrate with messaging logic
            MXLog.info("[CallNotificationService] User wants to message: \(callerName)")
            await removeMissedCallNotification(callId: callId)
            
        case UNNotificationDismissActionIdentifier:
            // User dismissed the notification
            MXLog.info("[CallNotificationService] User dismissed missed call notification")
            await removeMissedCallNotification(callId: callId)
            
        default:
            MXLog.info("[CallNotificationService] Unknown action: \(action)")
        }
    }
    
    // MARK: - Integration with CallHistoryManager
    
    /// Sync with call history to detect missed calls
    func syncWithCallHistory() async {
        let callHistory = await CallHistoryManager.shared.getCallHistory(filter: .missed)
        
        // Check for missed calls that don't have notifications yet
        for entry in callHistory.prefix(5) { // Check recent missed calls
            if !scheduledMissedCallNotifications.contains(entry.id) {
                let callerName = entry.callInfo.caller.displayName ?? "Неизвестный абонент"
                await scheduleMissedCallNotification(callId: entry.id,
                                                     callerName: callerName,
                                                     roomId: entry.callInfo.roomId,
                                                     timestamp: entry.callInfo.timestamp)
            }
        }
    }
    
    // MARK: - Cleanup
    
    /// Clean up old notifications and data
    func performCleanup() async {
        // Remove notifications older than 24 hours
        let cutoffTime = Date().addingTimeInterval(-24 * 60 * 60)
        
        let deliveredNotifications = await notificationCenter.deliveredNotifications()
        let oldNotificationIds = deliveredNotifications.compactMap { notification -> String? in
            guard notification.request.identifier.hasPrefix("missed_call_"),
                  notification.date < cutoffTime else {
                return nil
            }
            return notification.request.identifier
        }
        
        if !oldNotificationIds.isEmpty {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: oldNotificationIds)
            
            // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Thread-safe очистка внутреннего состояния
            for id in oldNotificationIds {
                if id.hasPrefix("missed_call_") {
                    let callId = String(id.dropFirst("missed_call_".count))
                    scheduledMissedCallNotifications.remove(callId)
                }
            }
            
            MXLog.info("[CallNotificationService] 🧹 Cleaned up \(oldNotificationIds.count) old notifications")
        }
        
        await updateCallBadgeCount()
    }
}

// MARK: - Data Models

/// Statistics for missed call notifications
public struct MissedCallStatistics {
    public let pendingMissedCalls: Int
    public let totalScheduledToday: Int
    public let averageResponseTime: TimeInterval
    
    public init(pendingMissedCalls: Int, totalScheduledToday: Int, averageResponseTime: TimeInterval) {
        self.pendingMissedCalls = pendingMissedCalls
        self.totalScheduledToday = totalScheduledToday
        self.averageResponseTime = averageResponseTime
    }
}
