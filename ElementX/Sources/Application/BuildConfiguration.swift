//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Build configuration settings
struct BuildConfiguration {
    static let shared = BuildConfiguration()
    
    // MARK: - Push Gateway Configuration
    
    /// Base URL for the push gateway (without the notify path)
    var pushGatewayBaseURL: URL {
        URL(string: "https://push.aibots.kz")!
    }
    
    /// Full URL for push gateway notifications
    var pushGatewayURL: URL {
        pushGatewayBaseURL.appendingPathComponent("_matrix/push/v1/notify")
    }
    
    /// App ID for alert pushes (должен соответствовать Bundle ID)
    var alertAppId: String {
        let appId: String
        #if DEBUG
        appId = "io.sergeyshmagin.kdbchat.debug"
        #else
        appId = "io.sergeyshmagin.kdbchat"  // Соответствует Bundle ID с Automatic Signing
        #endif
        
        MXLog.info("[BuildConfiguration] 📱 Alert App ID configured as: \(appId)")
        return appId
    }
    
    /// App ID for VoIP pushes (отдельный App ID для VoIP если понадобится)
    var voipAppId: String {
        #if DEBUG
        return "io.sergeyshmagin.kdbchat.debug"  // Для debug используем обычный
        #else
        return "io.sergeyshmagin.kdbchat"  // Пока используем обычный App ID
        #endif
    }
    
    // MARK: - Server Configuration
    
    /// Matrix homeserver URL
    var matrixHomeserver: String {
        "https://matrix.aibots.kz"
    }
    
    /// LiveKit server URL
    var liveKitServerURL: String {
        "wss://video.aibots.kz"
    }
    
    /// Whether to register VoIP pushers
    var shouldRegisterVoIP: Bool {
        true
    }
}
