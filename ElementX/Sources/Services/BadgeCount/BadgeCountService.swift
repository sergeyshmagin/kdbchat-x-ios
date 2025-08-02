//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit
import UserNotifications

final class BadgeCountService: BadgeCountServiceProtocol {
    private let appSettings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    
    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        setupAppStateObservation()
    }
    
    func updateBadgeCount(to count: Int) {
        // ИСПРАВЛЕНИЕ: Убираем лишнее оборачивание в Task для предотвращения дублирования
        // Метод уже будет вызываться из MainActor контекста
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(count)
            MXLog.info("[BadgeCountService] Updated badge count to: \(count)")
        }
    }
    
    func clearBadgeCount() {
        updateBadgeCount(to: 0)
    }
    
    func updateBadgeCountFromRoomSummaries(_ summaries: [RoomSummary]) {
        // Don't update badge if user disabled unread message badges
        guard !appSettings.hideUnreadMessagesBadge else {
            clearBadgeCount()
            return
        }
        
        // Calculate total unread count across all rooms
        let totalUnreadCount = summaries.reduce(0) { total, summary in
            // Only count rooms that should show notifications
            if summary.isMuted {
                return total
            }
            
            // ИСПРАВЛЕНИЕ: Используем только unreadNotificationsCount - это основной счетчик
            // unreadMessagesCount и unreadMentionsCount могут дублировать данные
            let roomUnreadCount = Int(summary.unreadNotificationsCount)
            
            // Also count marked unread rooms
            let markedUnreadCount = summary.isMarkedUnread ? 1 : 0
            
            return total + roomUnreadCount + markedUnreadCount
        }
        
        // ИСПРАВЛЕНИЕ: Простая логика - всегда обновляем badge если значение изменилось
        let currentBadge = UIApplication.shared.applicationIconBadgeNumber
        
        if totalUnreadCount != currentBadge {
            MXLog.info("[BadgeCountService] Updating badge: current=\(currentBadge), calculated=\(totalUnreadCount)")
            updateBadgeCount(to: totalUnreadCount)
        } else {
            MXLog.debug("[BadgeCountService] Badge count already correct: \(currentBadge)")
        }
    }
    
    private func setupAppStateObservation() {
        // Listen for app state changes to update badge count
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                // When app becomes active, we could refresh badge count
                // This will be handled by the coordinator
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                // When app enters background, ensure badge count is up to date
                // This will be handled by the coordinator
            }
            .store(in: &cancellables)
        
        // Listen for changes to the hideUnreadMessagesBadge setting
        appSettings.$hideUnreadMessagesBadge
            .sink { [weak self] hideUnreadBadge in
                if hideUnreadBadge {
                    self?.clearBadgeCount()
                }
            }
            .store(in: &cancellables)
    }
}
