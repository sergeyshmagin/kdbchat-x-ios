//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CallKit
import Foundation

/// SOLID PRINCIPLE: Single Responsibility - Ответственен только за интеграцию с CallKit
@MainActor
public final class CallKitIntegrationService: NSObject, CallKitIntegrationProtocol {
    private let callObserver = CXCallObserver()
    private weak var storage: CallHistoryStorage?
    
    public init(storage: CallHistoryStorage) {
        self.storage = storage
        super.init()
        setupCallObserver()
    }
    
    // MARK: - CallKitIntegrationProtocol
    
    public func syncWithSystemCallLog() async {
        await Task.detached(priority: .background) {
            let systemCalls = self.callObserver.calls
            let logMessage = "[CallKitIntegration] 📊 System has \(systemCalls.count) active calls"
            
            await MainActor.run {
                MXLog.info(logMessage)
            }
            
            guard let storage = await MainActor.run(body: { self.storage }) else { return }
            
            // Process system calls in background
            for systemCall in systemCalls {
                let callId = systemCall.uuid.uuidString
                
                // Check if already tracked using systemCallInfo
                let calls = await storage.getCallHistory()
                let alreadyTracked = calls.contains(where: {
                    $0.systemCallInfo?.uuid.uuidString == callId
                })
                
                if alreadyTracked {
                    continue
                }
                
                // Find matching call in background
                let recentCalls = Array(calls.prefix(10))
                
                for entry in recentCalls {
                    let timeDiff = abs(entry.callInfo.timestamp.timeIntervalSinceNow)
                    if timeDiff < 300, entry.systemCallInfo == nil {
                        // Create system call info for linking
                        let systemCallInfo = SystemCallInfo(uuid: systemCall.uuid,
                                                            handle: systemCall.uuid.uuidString, // CXCall doesn't have handle property
                                                            startTime: Date(), // CXCall doesn't provide start time directly
                                                            endTime: systemCall.hasEnded ? Date() : nil, // Approximate end time
                                                            connected: systemCall.hasConnected)
                        
                        // Create updated entry with system call info
                        let updatedEntry = CallHistoryEntry(id: entry.id,
                                                            callInfo: entry.callInfo,
                                                            recordedAt: entry.recordedAt,
                                                            systemCallInfo: systemCallInfo)
                        
                        // Record the updated entry (storage will handle deduplication)
                        await storage.recordCall(updatedEntry.callInfo)
                        
                        await MainActor.run {
                            MXLog.info("[CallKitIntegration] 🔗 Linked call to system: \(entry.id)")
                        }
                        break
                    }
                }
            }
        }.value
    }
    
    // MARK: - Private
    
    private func setupCallObserver() {
        callObserver.setDelegate(self, queue: nil)
        MXLog.info("[CallKitIntegration] 👁️ CallKit observer configured")
    }
}

// MARK: - CXCallObserverDelegate

extension CallKitIntegrationService: CXCallObserverDelegate {
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MXLog.info("[CallKitIntegration] 📞 System call changed: \(call.uuid) - Connected: \(call.hasConnected), Ended: \(call.hasEnded)")
        
        Task {
            await syncWithSystemCallLog()
        }
    }
}
