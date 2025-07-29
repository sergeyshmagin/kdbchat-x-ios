//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import Foundation
import SwiftUI

// MARK: - Call Log Entry

struct CallLogEntry: Identifiable, Codable, Equatable {
    let id: String
    let roomId: String
    let userId: String
    let displayName: String?
    let avatarUrl: String?
    let callType: CallType
    let direction: CallDirection
    let status: CallStatus
    let timestamp: Date
    let duration: TimeInterval? // Duration in seconds, nil if call wasn't answered
    
    init(id: String = UUID().uuidString,
         roomId: String,
         userId: String,
         displayName: String?,
         avatarUrl: String?,
         callType: CallType,
         direction: CallDirection,
         status: CallStatus,
         timestamp: Date = Date(),
         duration: TimeInterval? = nil) {
        self.id = id
        self.roomId = roomId
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.callType = callType
        self.direction = direction
        self.status = status
        self.timestamp = timestamp
        self.duration = duration
    }
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        
        let calendar = Calendar.current
        if calendar.isDateInToday(timestamp) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: timestamp)
        } else if calendar.isDateInYesterday(timestamp) {
            return "Вчера"
        } else if calendar.dateInterval(of: .weekOfYear, for: timestamp)?.contains(Date()) == true {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: timestamp)
        } else {
            formatter.dateFormat = "dd.MM.yy"
            return formatter.string(from: timestamp)
        }
    }
    
    var formattedDuration: String? {
        guard let duration = duration, duration > 0 else { return nil }
        
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "0:%02d", seconds)
        }
    }
    
    var isAnswered: Bool {
        status == .answered
    }
    
    var isMissed: Bool {
        status == .missed || (direction == .incoming && status != .answered)
    }
}

// MARK: - Contact with Call History

struct ContactWithCallHistory: Identifiable {
    let id: String
    let userId: String
    let displayName: String?
    let avatarUrl: String?
    let lastSeen: String?
    let recentCalls: [CallLogEntry]
    
    var mostRecentCall: CallLogEntry? {
        recentCalls.sorted { $0.timestamp > $1.timestamp }.first
    }
    
    var callCount: Int {
        recentCalls.count
    }
    
    var hasRecentMissedCalls: Bool {
        recentCalls.contains { $0.isMissed && Calendar.current.isDateInToday($0.timestamp) }
    }
}

// MARK: - View Actions

enum CallLogViewAction {
    case searchQueryChanged(String)
    case makeCall(roomId: String, callType: CallType)
    case showContactDetails(userId: String)
    case clearCallHistory
    case deleteCallEntry(String)
}

// MARK: - View State

struct CallLogViewState {
    var searchQuery = ""
    var isSearching = false
    var callHistory: [CallLogEntry] = []
    var contacts: [ContactWithCallHistory] = []
    var filteredContacts: [ContactWithCallHistory] = []
    var filteredCallHistory: [CallLogEntry] = []
    var isLoading = false
    var error: String?
    
    var isEmpty: Bool {
        callHistory.isEmpty && contacts.isEmpty
    }
    
    var hasSearchResults: Bool {
        !searchQuery.isEmpty && (!filteredContacts.isEmpty || !filteredCallHistory.isEmpty)
    }
}
