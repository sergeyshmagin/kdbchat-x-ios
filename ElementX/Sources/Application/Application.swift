//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import Compound

// MARK: - Global Call Types
/// ElementX call type enumeration - Global definition for entire app
public enum ElementXCallType: String, CaseIterable {
    case audio
    case video
    
    public var icon: KeyPath<CompoundIcons, Image> {
        switch self {
        case .audio:
            return \.voiceCall
        case .video:
            return \.videoCall
        }
    }
}

// MARK: - Type Alias for Convenience
/// Convenience alias to avoid conflicts with MatrixRustSDK.CallType
public typealias CallType = ElementXCallType

/// Call direction enumeration
public enum CallDirection: String, CaseIterable {
    case incoming
    case outgoing
    
    public var displayName: String {
        switch self {
        case .incoming:
            return "Входящий"
        case .outgoing:
            return "Исходящий"
        }
    }
}

/// Call status enumeration
public enum CallStatus: String, CaseIterable {
    case connecting
    case ringing
    case connected
    case answered
    case ended
    case declined
    case failed
    case missed
}

// MARK: - Call Data Structures
/// Call participant information
public struct CallParticipant {
    public let userId: String
    public let displayName: String?
    public let avatarURL: URL?
    public let handle: String // Used for CallKit
    
    public init(userId: String, displayName: String?, avatarURL: URL?, handle: String) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.handle = handle
    }
}

/// LiveKit configuration
public struct LiveKitConfig {
    public let accessToken: String
    public let serverURL: String
    public let roomURL: String?
    
    public init(accessToken: String, serverURL: String, roomURL: String?) {
        self.accessToken = accessToken
        self.serverURL = serverURL
        self.roomURL = roomURL
    }
}

/// Call information structure
public struct CallInfo {
    public let id: String
    public let roomId: String
    public let caller: CallParticipant
    public let callee: CallParticipant
    public let type: CallType
    public let direction: CallDirection
    public let timestamp: Date
    public var duration: TimeInterval?
    public var status: CallStatus
    public let liveKitConfig: LiveKitConfig?
    
    public init(id: String, roomId: String, caller: CallParticipant, callee: CallParticipant, type: CallType, direction: CallDirection, timestamp: Date, duration: TimeInterval?, status: CallStatus, liveKitConfig: LiveKitConfig?) {
        self.id = id
        self.roomId = roomId
        self.caller = caller
        self.callee = callee
        self.type = type
        self.direction = direction
        self.timestamp = timestamp
        self.duration = duration
        self.status = status
        self.liveKitConfig = liveKitConfig
    }
}

/// Call history entry
public struct CallHistoryEntry {
    public let id: String
    public let callInfo: CallInfo
    public let recordedAt: Date
    public let systemCallInfo: SystemCallInfo?
    
    public init(id: String = UUID().uuidString, callInfo: CallInfo, recordedAt: Date = Date(), systemCallInfo: SystemCallInfo? = nil) {
        self.id = id
        self.callInfo = callInfo
        self.recordedAt = recordedAt
        self.systemCallInfo = systemCallInfo
    }
}

/// System call information for CallKit integration
public struct SystemCallInfo {
    public let uuid: UUID
    public let handle: String
    public let startTime: Date
    public let endTime: Date?
    public let connected: Bool
    
    public init(uuid: UUID, handle: String, startTime: Date, endTime: Date?, connected: Bool) {
        self.uuid = uuid
        self.handle = handle
        self.startTime = startTime
        self.endTime = endTime
        self.connected = connected
    }
}

/// Call notification information
public struct CallNotification {
    public let type: CallNotificationType
    public let timestamp: Date
    public let delivered: Bool
    
    public init(type: CallNotificationType, timestamp: Date, delivered: Bool) {
        self.type = type
        self.timestamp = timestamp
        self.delivered = delivered
    }
}

/// Call notification types
public enum CallNotificationType: String, CaseIterable {
    case incoming
    case answered
    case missed
    case ended
    case declined
}

/// Call history filter
public enum CallHistoryFilter {
    case all
    case incoming
    case outgoing
    case missed
    case answered
}

/// Call statistics
public struct CallStatistics {
    public let totalCalls: Int
    public let incomingCalls: Int
    public let outgoingCalls: Int
    public let missedCalls: Int
    public let answeredCalls: Int
    public let videoCalls: Int
    public let audioCalls: Int
    public let totalDuration: TimeInterval
    public let averageDuration: TimeInterval
    
    public init(totalCalls: Int, incomingCalls: Int, outgoingCalls: Int, missedCalls: Int, answeredCalls: Int, videoCalls: Int, audioCalls: Int, totalDuration: TimeInterval, averageDuration: TimeInterval) {
        self.totalCalls = totalCalls
        self.incomingCalls = incomingCalls
        self.outgoingCalls = outgoingCalls
        self.missedCalls = missedCalls
        self.answeredCalls = answeredCalls
        self.videoCalls = videoCalls
        self.audioCalls = audioCalls
        self.totalDuration = totalDuration
        self.averageDuration = averageDuration
    }
}

@main
struct Application: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openURL) private var openURL
    
    private var appCoordinator: AppCoordinatorProtocol!

    init() {
        if ProcessInfo.isRunningUITests {
            appCoordinator = UITestsAppCoordinator(appDelegate: appDelegate)
        } else if ProcessInfo.isRunningUnitTests {
            appCoordinator = UnitTestsAppCoordinator(appDelegate: appDelegate)
        } else {
            appCoordinator = AppCoordinator(appDelegate: appDelegate)
        }
        
        SceneDelegate.windowManager = appCoordinator.windowManager
    }

    var body: some Scene {
        WindowGroup {
            appCoordinator.toPresentable()
                .statusBarHidden(shouldHideStatusBar)
                .environment(\.openURL, OpenURLAction { url in
                    if appCoordinator.handleDeepLink(url, isExternalURL: false) {
                        return .handled
                    }
                    
                    if appCoordinator.handlePotentialPhishingAttempt(url: url, openURLAction: { url in
                        openURL(url, isExternalURL: false)
                    }) {
                        return .handled
                    }

                    return .systemAction
                })
                .onOpenURL { url in
                    openURL(url, isExternalURL: true)
                }
                .onContinueUserActivity("INStartVideoCallIntent") { userActivity in
                    // `INStartVideoCallIntent` is to be replaced with `INStartCallIntent`
                    // but calls from Recents still send it ¯\_(ツ)_/¯
                    appCoordinator.handleUserActivity(userActivity)
                }
                .task {
                    appCoordinator.start()
                }
        }
    }
    
    // MARK: - Private
    
    private func openURL(_ url: URL, isExternalURL: Bool) {
        if !appCoordinator.handleDeepLink(url, isExternalURL: isExternalURL) {
            openURLInSystemBrowser(url)
        }
    }

    /// Hide the status bar so it doesn't interfere with the screenshot tests
    private var shouldHideStatusBar: Bool {
        ProcessInfo.isRunningUITests
    }
    
    /// https://github.com/element-hq/element-x-ios/issues/1824
    /// Avoid opening universal links in other app variants and infinite loops between them
    private func openURLInSystemBrowser(_ originalURL: URL) {
        guard var urlComponents = URLComponents(url: originalURL, resolvingAgainstBaseURL: true) else {
            openURL(originalURL)
            return
        }
        
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(.init(name: "no_universal_links", value: "true"))
        
        urlComponents.queryItems = queryItems
        
        guard let url = urlComponents.url else {
            openURL(originalURL)
            return
        }
        
        openURL(url)
    }
}

// MARK: - Call Services Reference
// Ссылки на сервисы будут использовать оригинальные реализации из Services/Calls/

