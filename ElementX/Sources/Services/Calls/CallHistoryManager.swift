//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Combine

/// SOLID PRINCIPLE: Composition over Inheritance - Объединяет отдельные сервисы
/// SOLID PRINCIPLE: Dependency Inversion - Зависит от абстракций, а не от конкретных классов
/// SOLID PRINCIPLE: Single Responsibility - Координирует работу компонентов, не выполняет их задачи
@MainActor
public final class CallHistoryManager: NSObject, CallHistoryManagerProtocol {
    public static let shared = CallHistoryManager()
    
    private let storage: CallHistoryStorage
    private let callKitIntegration: CallKitIntegrationService
    private let statisticsService: CallStatisticsService
    private var cancellables = Set<AnyCancellable>()
    
    // SOLID PRINCIPLE: Delegation - Асинхронный доступ к данным через публичный интерфейс
    public func getInAppCalls() async -> [CallHistoryEntry] {
        return await storage.getCallHistory()
    }
    
    private override init() {
        // SOLID PRINCIPLE: Dependency Injection через композицию
        storage = CallHistoryStorage()
        callKitIntegration = CallKitIntegrationService(storage: storage)
        statisticsService = CallStatisticsService(storage: storage)
        
        super.init()
        
        MXLog.info("[CallHistoryManager] ✅ Initialized with SOLID architecture")
    }
    
    // MARK: - CallHistoryStorageProtocol Delegation
    
    /// SOLID PRINCIPLE: Delegation - Делегируем запись звонков специализированному сервису
    public func recordCall(_ callInfo: CallInfo) async {
        await storage.recordCall(callInfo)
    }
    
    /// SOLID PRINCIPLE: Delegation - Обновление статуса через специализированный сервис
    public func updateCallStatus(_ callId: String, status: CallStatus) async {
        await storage.updateCallStatus(callId, status: status)
    }
    
    /// SOLID PRINCIPLE: Delegation - Обновление длительности через специализированный сервис
    public func updateCallDuration(_ callId: String, duration: TimeInterval) async {
        await storage.updateCallDuration(callId, duration: duration)
    }
    
    // MARK: - Call History Access Delegation
    
    /// SOLID PRINCIPLE: Delegation - Получение истории через специализированный сервис
    public func getCallHistory() async -> [CallHistoryEntry] {
        return await storage.getCallHistory()
    }
    
    /// SOLID PRINCIPLE: Delegation - Фильтрация через специализированный сервис
    public func getCallHistory(filter: CallHistoryFilter) async -> [CallHistoryEntry] {
        return await storage.getCallHistory(filter: filter)
    }
    
    // MARK: - CallKitIntegrationProtocol Delegation
    
    /// SOLID PRINCIPLE: Delegation - Синхронизация с CallKit через специализированный сервис
    public func syncWithSystemCallLog() async {
        await callKitIntegration.syncWithSystemCallLog()
    }
    
    // MARK: - CallStatisticsProtocol Delegation
    
    /// SOLID PRINCIPLE: Delegation - Статистика через специализированный сервис
    public func getCallStatistics() async -> CallStatistics {
        return await statisticsService.getCallStatistics()
    }
    
    // MARK: - Cleanup Delegation
    
    /// SOLID PRINCIPLE: Delegation - Очистка через специализированный сервис
    public func cleanupOldEntries(olderThan days: Int = 30) async {
        await storage.cleanupOldEntries(olderThan: days)
    }
    
    
    // MARK: - Published Properties for UI Binding
    
    /// SOLID PRINCIPLE: Observer Pattern - Предоставляем реактивные свойства для UI
    var storagePublisher: Published<[CallHistoryEntry]>.Publisher {
        storage.inAppCallsPublisher
    }
}

// MARK: - Data Models

// MARK: - Additional CallHistoryEntry components (specific to CallHistoryManager)

/// Extended CallHistoryEntry with additional metadata for CallHistoryManager
extension CallHistoryEntry {
    var systemCallLogId: String? {
        systemCallInfo?.uuid.uuidString
    }
    
    var notifications: [CallNotification] {
        // Return computed notifications based on call status
        var notifications: [CallNotification] = []
        
        switch callInfo.status {
        case .ringing:
            notifications.append(CallNotification(type: .incoming, timestamp: callInfo.timestamp, delivered: true))
        case .answered:
            notifications.append(CallNotification(type: .answered, timestamp: callInfo.timestamp, delivered: true))
        case .missed:
            notifications.append(CallNotification(type: .missed, timestamp: callInfo.timestamp, delivered: true))
        case .ended:
            notifications.append(CallNotification(type: .ended, timestamp: callInfo.timestamp, delivered: true))
        default:
            break
        }
        
        return notifications
    }
    
    var metadata: [String: Any] {
        var metadata: [String: Any] = [:]
        metadata["duration"] = callInfo.duration
        metadata["type"] = callInfo.type
        metadata["direction"] = callInfo.direction
        metadata["status"] = callInfo.status
        if let liveKit = callInfo.liveKitConfig {
            metadata["livekit_server"] = liveKit.serverURL
        }
        return metadata
    }
}

// MARK: - Additional Types Reference  
// CallNotification и CallNotificationType определены в Application.swift

// MARK: - Data Types Reference
// CallHistoryFilter и CallStatistics определены в Application.swift