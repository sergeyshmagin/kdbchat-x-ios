//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// SOLID PRINCIPLE: Interface Segregation - Разделяем функциональность на отдельные протоколы

/// Protocol for managing call history data
public protocol CallHistoryStorageProtocol {
    func recordCall(_ callInfo: CallInfo) async
    func updateCallStatus(_ callId: String, status: CallStatus) async
    func updateCallDuration(_ callId: String, duration: TimeInterval) async
    func getCallHistory() async -> [CallHistoryEntry]
    func getCallHistory(filter: CallHistoryFilter) async -> [CallHistoryEntry]
    func cleanupOldEntries(olderThan days: Int) async
}

/// Protocol for CallKit system integration
public protocol CallKitIntegrationProtocol {
    func syncWithSystemCallLog() async
}

/// Protocol for call statistics
public protocol CallStatisticsProtocol {
    func getCallStatistics() async -> CallStatistics
}

/// SOLID PRINCIPLE: Dependency Inversion - Высокоуровневые модули зависят от абстракций
public protocol CallHistoryManagerProtocol: CallHistoryStorageProtocol, CallKitIntegrationProtocol, CallStatisticsProtocol {
    func getInAppCalls() async -> [CallHistoryEntry]
}