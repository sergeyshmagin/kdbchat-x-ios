//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

enum AppDelegateCallback {
    case registeredNotifications(deviceToken: Data)
    case failedToRegisteredNotifications(error: Error)
    case registeredVoIPNotifications(tokenData: Data)
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let callbacks = PassthroughSubject<AppDelegateCallback, Never>()
    var orientationLock = UIInterfaceOrientationMask.all
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Add a SceneDelegate to the SwiftUI scene so that we can connect up the WindowManager.
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NSTextAttachment.registerViewProviderClass(PillAttachmentViewProvider.self, forFileType: InfoPlistReader.main.pillsUTType)
        
        // PushNotificationManager removed - functionality integrated into NotificationManager
        
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: APNS требует hex формат, не base64!
        let tokenHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let tokenBase64 = deviceToken.base64EncodedString() // для сравнения в логах
        let bundleId = Bundle.main.bundleIdentifier ?? "Unknown"
        
        MXLog.info("[AppDelegate] 🎯 ===== DEVICE TOKEN RECEIVED =====")
        MXLog.info("[AppDelegate] 📦 Bundle ID: \(bundleId)")
        MXLog.info("[AppDelegate] 🔑 Device Token (HEX): \(tokenHex)")
        MXLog.info("[AppDelegate] 🔑 Device Token (Base64): \(tokenBase64)")
        MXLog.info("[AppDelegate] 🔑 Token Length (HEX): \(tokenHex.count) chars")
        MXLog.info("[AppDelegate] 🔑 Token Length (Base64): \(tokenBase64.count) chars")
        MXLog.info("[AppDelegate] 📱 Device: \(UIDevice.current.model) (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion))")
        MXLog.info("[AppDelegate] 🏗️ Build Config: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")")
        MXLog.info("[AppDelegate] ==========================================")
        
        callbacks.send(.registeredNotifications(deviceToken: deviceToken))
        
        // PushNotificationManager removed - push registration now handled by NotificationManager
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        callbacks.send(.failedToRegisteredNotifications(error: error))
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        orientationLock
    }
}
