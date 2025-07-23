//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

@MainActor
enum Target: String {
    case mainApp = "elementx"
    case nse
    case shareExtension = "shareextension"
    case tests
    
    private static var isConfigured = false
    private static let configurationLock = NSLock()
    
    func configure(logLevel: LogLevel, traceLogPacks: Set<TraceLogPack>, sentryURL: URL?) {
        Self.configurationLock.lock()
        defer { Self.configurationLock.unlock() }
        
        guard !Self.isConfigured else {
            // Use print instead of MXLog in case MXLog is not configured yet
            print("INFO: Target \(self) already configured, skipping")
            return
        }
        
        do {
            switch self {
            case .mainApp:
                let tracingConfiguration = Tracing.buildConfiguration(logLevel: logLevel,
                                                                      traceLogPacks: traceLogPacks,
                                                                      currentTarget: rawValue,
                                                                      filePrefix: nil,
                                                                      sentryURL: sentryURL)
                try initPlatform(config: tracingConfiguration, useLightweightTokioRuntime: false)
            case .nse:
                let tracingConfiguration = Tracing.buildConfiguration(logLevel: logLevel,
                                                                      traceLogPacks: traceLogPacks,
                                                                      currentTarget: rawValue,
                                                                      filePrefix: rawValue,
                                                                      sentryURL: sentryURL)
                try initPlatform(config: tracingConfiguration, useLightweightTokioRuntime: true)
            case .shareExtension:
                let tracingConfiguration = Tracing.buildConfiguration(logLevel: logLevel,
                                                                      traceLogPacks: traceLogPacks,
                                                                      currentTarget: rawValue,
                                                                      filePrefix: rawValue,
                                                                      sentryURL: sentryURL)
                try initPlatform(config: tracingConfiguration, useLightweightTokioRuntime: true)
            case .tests:
                let tracingConfiguration = Tracing.buildConfiguration(logLevel: logLevel,
                                                                      traceLogPacks: traceLogPacks,
                                                                      currentTarget: rawValue,
                                                                      filePrefix: rawValue,
                                                                      sentryURL: sentryURL)
                try initPlatform(config: tracingConfiguration, useLightweightTokioRuntime: false)
            }
        } catch {
            // Use print instead of MXLog since MXLog might not be configured yet
            print("ERROR: Failed configuring target \(self) with error: \(error)")
            // Don't crash - just log the error and continue with fallback configuration
            // Even in DEBUG mode, we want to continue running when logging fails
            // The app can still function without file logging
            Self.isConfigured = true
            return
        }
        
        // Setup sentry above but disable it by default. It will be started
        // later together with the analytics service if the user consents.
        enableSentryLogging(enabled: false)
        
        MXLog.configure(currentTarget: rawValue)
        
        Self.isConfigured = true
    }
}
