//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Combine

/// SOLID PRINCIPLE: Single Responsibility - Ответственен только за хранение истории звонков
@MainActor
public final class CallHistoryStorage: ObservableObject, CallHistoryStorageProtocol {
    
    // Published properties for reactive UI updates
    @Published private(set) var inAppCalls: [CallHistoryEntry] = []
    
    public init() {
        MXLog.info("[CallHistoryStorage] Initialized with thread-safe storage")
    }
    
    // MARK: - Publisher Access
    
    /// Provides access to reactive updates for UI binding
    public var inAppCallsPublisher: Published<[CallHistoryEntry]>.Publisher {
        $inAppCalls
    }
    
    // MARK: - CallHistoryStorageProtocol
    
    public func recordCall(_ callInfo: CallInfo) async {
        let entry = CallHistoryEntry(
            id: callInfo.id,
            callInfo: callInfo,
            recordedAt: Date(),
            systemCallInfo: nil
        )
        
        // Thread-safe update with background preparation
        await Task.detached(priority: .background) {
            let logMessage = "[CallHistoryStorage] ✅ Recorded call: \(callInfo.id)"
            
            await MainActor.run {
                self.inAppCalls.insert(entry, at: 0)
                MXLog.info(logMessage)
            }
        }.value
    }
    
    public func updateCallStatus(_ callId: String, status: CallStatus) async {
        await Task.detached(priority: .background) {
            let index = await MainActor.run {
                self.inAppCalls.firstIndex(where: { $0.id == callId })
            }
            
            guard let index = index else { return }
            
            let logMessage = "[CallHistoryStorage] ✅ Updated call status: \(callId) -> \(status)"
            
            await MainActor.run {
                let existingEntry = self.inAppCalls[index]
                var updatedCallInfo = existingEntry.callInfo
                updatedCallInfo.status = status
                
                let updatedEntry = CallHistoryEntry(
                    id: existingEntry.id,
                    callInfo: updatedCallInfo,
                    recordedAt: existingEntry.recordedAt,
                    systemCallInfo: existingEntry.systemCallInfo
                )
                
                self.inAppCalls[index] = updatedEntry
                MXLog.info(logMessage)
            }
        }.value
    }
    
    public func updateCallDuration(_ callId: String, duration: TimeInterval) async {
        await Task.detached(priority: .background) {
            let index = await MainActor.run {
                self.inAppCalls.firstIndex(where: { $0.id == callId })
            }
            
            guard let index = index else { return }
            
            let logMessage = "[CallHistoryStorage] ✅ Updated call duration: \(callId) -> \(Int(duration))s"
            
            await MainActor.run {
                let existingEntry = self.inAppCalls[index]
                var updatedCallInfo = existingEntry.callInfo
                updatedCallInfo.duration = duration
                updatedCallInfo.status = .ended
                
                let updatedEntry = CallHistoryEntry(
                    id: existingEntry.id,
                    callInfo: updatedCallInfo,
                    recordedAt: existingEntry.recordedAt,
                    systemCallInfo: existingEntry.systemCallInfo
                )
                
                self.inAppCalls[index] = updatedEntry
                MXLog.info(logMessage)
            }
        }.value
    }
    
    public func getCallHistory() async -> [CallHistoryEntry] {
        return inAppCalls
    }
    
    public func getCallHistory(filter: CallHistoryFilter) async -> [CallHistoryEntry] {
        await Task.detached(priority: .background) {
            let calls = await MainActor.run { self.inAppCalls }
            
            return calls.filter { entry in
                switch filter {
                case .all:
                    return true
                case .incoming:
                    return entry.callInfo.direction == .incoming
                case .outgoing:
                    return entry.callInfo.direction == .outgoing
                case .missed:
                    return entry.callInfo.status == .missed
                case .answered:
                    return entry.callInfo.status == .answered || entry.callInfo.status == .ended
                }
            }
        }.value
    }
    
    public func cleanupOldEntries(olderThan days: Int = 30) async {
        await Task.detached(priority: .background) {
            let cutoffDate = Date().addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
            
            let calls = await MainActor.run { self.inAppCalls }
            let originalCount = calls.count
            
            let filteredCalls = calls.filter { $0.callInfo.timestamp > cutoffDate }
            let removedCount = originalCount - filteredCalls.count
            
            await MainActor.run {
                self.inAppCalls = filteredCalls
                
                if removedCount > 0 {
                    MXLog.info("[CallHistoryStorage] 🧹 Cleaned up \(removedCount) old call entries")
                }
            }
        }.value
    }
}