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
    
    /// Base URL for the push gateway
    var pushGatewayURL: URL {
        URL(string: "https://sygnal.aibots.kz/_matrix/push/v1/notify")!
    }
    
    /// App ID for alert pushes
    var alertAppId: String {
        #if DEBUG
        return "io.sergeyshmagin.kdbchat.ios.debug"
        #else
        return "io.sergeyshmagin.kdbchat.ios"
        #endif
    }
    
    /// App ID for VoIP pushes
    var voipAppId: String {
        #if DEBUG
        return "io.sergeyshmagin.kdbchat.ios.voip.debug"
        #else
        return "io.sergeyshmagin.kdbchat.ios.voip"
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