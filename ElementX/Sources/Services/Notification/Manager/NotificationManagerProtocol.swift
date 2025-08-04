//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import PushKit
import UserNotifications

protocol NotificationManagerDelegate: AnyObject {
    func shouldDisplayInAppNotification(content: UNNotificationContent) -> Bool
    func notificationTapped(content: UNNotificationContent) async
    func handleInlineReply(_ service: NotificationManagerProtocol,
                           content: UNNotificationContent,
                           replyText: String) async
    func registerForRemoteNotifications()
    func unregisterForRemoteNotifications()
    func registerForVoIPNotifications()
    func voIPTokenUpdated(_ tokenData: Data)
    func handleVoIPPushNotification(roomId: String, callId: String, callerName: String, hasVideo: Bool) async
}

// MARK: - NotificationManagerProtocol

// sourcery: AutoMockable
protocol NotificationManagerProtocol: AnyObject {
    var delegate: NotificationManagerDelegate? { get set }

    func start()
    func register(with deviceToken: Data) async -> Bool
    func registrationFailed(with error: Error)
    func showLocalNotification(with title: String, subtitle: String?) async
    func setUserSession(_ userSession: UserSessionProtocol?)
    
    func requestAuthorization()
    
    func removeDeliveredMessageNotifications(for roomID: String) async
    
    func removeDeliveredNotificationsForFullyReadRooms(_ rooms: [RoomSummary]) async
    
    func forceReRegisterPushers() async
    
    // VoIP Push Support
    func registerVoIPPusher(with tokenData: Data) async -> Bool
    func hasVoIPToken() -> Bool
    func getVoIPPusherDiagnostics() -> VoIPPusherDiagnostics
    func testVoIPPusherRegistration() async -> VoIPPusherTestResult
}

// MARK: - Diagnostic Types

struct VoIPPusherDiagnostics {
    let hasToken: Bool
    let tokenPrefix: String?
    let lastRegistrationAttempt: Date?
    let registrationSuccess: Bool
    let retryCount: Int
    let userSessionAvailable: Bool
}

struct VoIPPusherTestResult {
    let success: Bool
    let message: String
    let tokenReceived: Bool
    let pusherRegistered: Bool
    let errorDetails: String?
}
