//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// SOLID PRINCIPLE: Single Responsibility - Ответственен только за вычисление статистики звонков
public final class CallStatisticsService: CallStatisticsProtocol {
    
    private weak var storage: CallHistoryStorage?
    
    public init(storage: CallHistoryStorage) {
        self.storage = storage
    }
    
    // MARK: - CallStatisticsProtocol
    
    public func getCallStatistics() async -> CallStatistics {
        guard let storage = storage else {
            return CallStatistics(
                totalCalls: 0, incomingCalls: 0, outgoingCalls: 0,
                missedCalls: 0, answeredCalls: 0, videoCalls: 0,
                audioCalls: 0, totalDuration: 0, averageDuration: 0
            )
        }
        
        // SOLID PRINCIPLE: Open/Closed - Статистика может быть расширена без модификации существующего кода
        return await Task.detached(priority: .background) {
            let calls = await storage.getCallHistory()
            
            // Perform all calculations in background to avoid QoS priority inversion
            let totalCalls = calls.count
            let incomingCalls = calls.filter { $0.callInfo.direction == .incoming }.count
            let outgoingCalls = calls.filter { $0.callInfo.direction == .outgoing }.count
            let missedCalls = calls.filter { $0.callInfo.status == .missed }.count
            let answeredCalls = calls.filter { 
                $0.callInfo.status == .answered || $0.callInfo.status == .ended 
            }.count
            
            let videoCalls = calls.filter { $0.callInfo.type == .video }.count
            let audioCalls = calls.filter { $0.callInfo.type == .audio }.count
            
            let totalDuration = calls.compactMap { $0.callInfo.duration }.reduce(0, +)
            let averageDuration = answeredCalls > 0 ? totalDuration / Double(answeredCalls) : 0
            
            return CallStatistics(
                totalCalls: totalCalls,
                incomingCalls: incomingCalls,
                outgoingCalls: outgoingCalls,
                missedCalls: missedCalls,
                answeredCalls: answeredCalls,
                videoCalls: videoCalls,
                audioCalls: audioCalls,
                totalDuration: totalDuration,
                averageDuration: averageDuration
            )
        }.value
    }
}