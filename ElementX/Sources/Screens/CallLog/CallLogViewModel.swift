//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import SwiftUI

@MainActor
class CallLogViewModel: ObservableObject {
    @Published var viewState = CallLogViewState()
    
    private let userSession: UserSessionProtocol
    private var cancellables = Set<AnyCancellable>()
    
    // Mock data for development - in real app this would come from Matrix SDK
    private let mockCallHistory: [CallLogEntry] = [
        CallLogEntry(roomId: "!room1:example.com",
                     userId: "@bolat:example.com",
                     displayName: "Болат Нач Упр Закупки",
                     avatarUrl: "https://example.com/avatar1.jpg",
                     callType: .video,
                     direction: .outgoing,
                     status: .answered,
                     timestamp: Date().addingTimeInterval(-3600), // 1 hour ago
                     duration: 125 // 2 minutes 5 seconds
        ),
        CallLogEntry(roomId: "!room2:example.com",
                     userId: "@bolat2:example.com",
                     displayName: "Болат",
                     avatarUrl: nil,
                     callType: .audio,
                     direction: .incoming,
                     status: .answered,
                     timestamp: Date().addingTimeInterval(-7200), // 2 hours ago
                     duration: 67 // 1 minute 7 seconds
        ),
        CallLogEntry(roomId: "!room3:example.com",
                     userId: "@rayimbek:example.com",
                     displayName: "Райимбек Болатбекулы",
                     avatarUrl: nil,
                     callType: .audio,
                     direction: .incoming,
                     status: .missed,
                     timestamp: Date().addingTimeInterval(-86400), // Yesterday
                     duration: nil),
        CallLogEntry(roomId: "!room4:example.com",
                     userId: "@bolat3:example.com",
                     displayName: "Болат Бедахметович Жамишев",
                     avatarUrl: nil,
                     callType: .video,
                     direction: .incoming,
                     status: .answered,
                     timestamp: Date().addingTimeInterval(-172_800), // 2 days ago
                     duration: 98 // 1 minute 38 seconds
        ),
        CallLogEntry(roomId: "!room5:example.com",
                     userId: "@aset:example.com",
                     displayName: "Асет Болатович Шарипов",
                     avatarUrl: nil,
                     callType: .audio,
                     direction: .outgoing,
                     status: .answered,
                     timestamp: Date().addingTimeInterval(-259_200), // 3 days ago
                     duration: 234 // 3 minutes 54 seconds
        )
    ]
    
    init(userSession: UserSessionProtocol) {
        self.userSession = userSession
        setupSearchBinding()
        loadCallHistory()
    }
    
    private func setupSearchBinding() {
        $viewState
            .map(\.searchQuery)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.filterContent(query: query)
            }
            .store(in: &cancellables)
    }
    
    private func loadCallHistory() {
        viewState.isLoading = true
        
        // Simulate loading delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            self.viewState.callHistory = self.mockCallHistory
            self.viewState.contacts = self.generateContactsFromCallHistory()
            self.viewState.isLoading = false
            
            // Apply current search filter
            self.filterContent(query: self.viewState.searchQuery)
        }
    }
    
    private func generateContactsFromCallHistory() -> [ContactWithCallHistory] {
        let groupedCalls = Dictionary(grouping: mockCallHistory) { $0.userId }
        
        return groupedCalls.compactMap { userId, calls in
            guard let firstCall = calls.first else { return nil }
            
            let sortedCalls = calls.sorted { $0.timestamp > $1.timestamp }
            let recentCalls = Array(sortedCalls.prefix(3)) // Last 3 calls
            
            return ContactWithCallHistory(id: userId,
                                          userId: userId,
                                          displayName: firstCall.displayName,
                                          avatarUrl: firstCall.avatarUrl,
                                          lastSeen: getLastSeenStatus(for: userId),
                                          recentCalls: recentCalls)
        }.sorted { contact1, contact2 in
            // Sort by most recent call
            let timestamp1 = contact1.mostRecentCall?.timestamp ?? Date.distantPast
            let timestamp2 = contact2.mostRecentCall?.timestamp ?? Date.distantPast
            return timestamp1 > timestamp2
        }
    }
    
    private func getLastSeenStatus(for userId: String) -> String {
        // Mock last seen status - in real app this would come from Matrix presence
        let statuses = ["Онлайн", "Занят", "Занят(-а)", "Доступен", "Не в сети"]
        return statuses.randomElement() ?? "Не в сети"
    }
    
    private func filterContent(query: String) {
        if query.isEmpty {
            viewState.filteredContacts = viewState.contacts
            viewState.filteredCallHistory = viewState.callHistory
            viewState.isSearching = false
        } else {
            viewState.isSearching = true
            
            // Filter contacts by name
            viewState.filteredContacts = viewState.contacts.filter { contact in
                let displayName = contact.displayName?.lowercased() ?? ""
                return displayName.contains(query.lowercased())
            }
            
            // Filter call history by name
            viewState.filteredCallHistory = viewState.callHistory.filter { entry in
                let displayName = entry.displayName?.lowercased() ?? ""
                return displayName.contains(query.lowercased())
            }
        }
    }
    
    func handleAction(_ action: CallLogViewAction) {
        switch action {
        case .searchQueryChanged(let query):
            viewState.searchQuery = query
            
        case .makeCall(let roomId, let callType):
            Task {
                await makeCall(roomId: roomId, callType: callType)
            }
            
        case .showContactDetails(let userId):
            // Handle showing contact details
            print("Show contact details for: \(userId)")
            
        case .clearCallHistory:
            clearCallHistory()
            
        case .deleteCallEntry(let entryId):
            deleteCallEntry(entryId)
        }
    }
    
    private func makeCall(roomId: String, callType: CallType) async {
        // Here we would integrate with the existing LiveKit call system
        // For now, just log the call attempt
        print("Making \(callType.rawValue) call to room: \(roomId)")
        
        // TODO: Integrate with LiveKitCallService
        // This should start a call with the specified type (audio/video)
        // and add an entry to the call history
        
        // Add a new entry to call history to simulate outgoing call
        let newEntry = CallLogEntry(roomId: roomId,
                                    userId: extractUserIdFromRoomId(roomId),
                                    displayName: getDisplayNameForRoomId(roomId),
                                    avatarUrl: nil,
                                    callType: callType,
                                    direction: .outgoing,
                                    status: .answered, // Simulate successful call
                                    timestamp: Date(),
                                    duration: 45 // Simulate 45 second call
        )
        
        // Update call history
        viewState.callHistory.insert(newEntry, at: 0)
        viewState.contacts = generateContactsFromCallHistory()
        filterContent(query: viewState.searchQuery)
    }
    
    private func extractUserIdFromRoomId(_ roomId: String) -> String {
        // Mock implementation - in real app this would be proper room to user mapping
        roomId.replacingOccurrences(of: "!room", with: "@user")
            .replacingOccurrences(of: ":example.com", with: "@example.com")
    }
    
    private func getDisplayNameForRoomId(_ roomId: String) -> String? {
        // Mock implementation - in real app this would come from room members
        let names = ["Болат", "Райимбек", "Асет", "Жамишев"]
        return names.randomElement()
    }
    
    private func clearCallHistory() {
        viewState.callHistory.removeAll()
        viewState.contacts = []
        viewState.filteredContacts = []
        viewState.filteredCallHistory = []
    }
    
    private func deleteCallEntry(_ entryId: String) {
        viewState.callHistory.removeAll { $0.id == entryId }
        viewState.contacts = generateContactsFromCallHistory()
        filterContent(query: viewState.searchQuery)
    }
}
