//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct CallLogView: View {
    @StateObject private var viewModel: CallLogViewModel
    @State private var isSearchFieldFocused = false
    
    init(userSession: UserSessionProtocol) {
        _viewModel = StateObject(wrappedValue: CallLogViewModel(userSession: userSession))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
            
            if viewModel.viewState.isLoading {
                // Loading state
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Загрузка...")
                        .font(.body)
                        .foregroundColor(.compound.textSecondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if viewModel.viewState.isEmpty {
                // Empty state
                emptyStateView
            } else {
                // Content
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !viewModel.viewState.isSearching {
                            // Show contacts section when not searching
                            if !viewModel.viewState.filteredContacts.isEmpty {
                                contactsSection
                            }
                            
                            // Show call history section
                            if !viewModel.viewState.filteredCallHistory.isEmpty {
                                callHistorySection
                            }
                        } else {
                            // Show search results
                            searchResultsView
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .background(Color.compound.bgCanvasDefault)
    }
    
    // MARK: - Search Bar
    
    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                CompoundIcon(\.search, size: .medium, relativeTo: .body)
                    .foregroundColor(.compound.iconSecondary)
                
                TextField("Болат", text: Binding(
                    get: { viewModel.viewState.searchQuery },
                    set: { viewModel.handleAction(.searchQueryChanged($0)) }
                ))
                .font(.body)
                .onTapGesture {
                    isSearchFieldFocused = true
                }
                
                if !viewModel.viewState.searchQuery.isEmpty {
                    Button {
                        viewModel.handleAction(.searchQueryChanged(""))
                        isSearchFieldFocused = false
                    } label: {
                        CompoundIcon(\.close, size: .small, relativeTo: .body)
                            .foregroundColor(.compound.iconSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.compound.bgSubtleSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            if isSearchFieldFocused {
                Button("Отмена") {
                    viewModel.handleAction(.searchQueryChanged(""))
                    isSearchFieldFocused = false
                    hideKeyboard()
                }
                .font(.body)
                .foregroundColor(.compound.textActionPrimary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSearchFieldFocused)
    }
    
    // MARK: - Contacts Section
    
    @ViewBuilder
    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Контакты")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.compound.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            
            ForEach(viewModel.viewState.filteredContacts) { contact in
                contactRow(contact)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Handle contact tap - could show contact details
                        viewModel.handleAction(.showContactDetails(contact.userId))
                    }
            }
        }
    }
    
    @ViewBuilder
    private func contactRow(_ contact: ContactWithCallHistory) -> some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(Color.compound.bgActionSecondaryRest)
                .frame(width: 40, height: 40)
                .overlay {
                    if let avatarUrl = contact.avatarUrl, !avatarUrl.isEmpty {
                        AsyncImage(url: URL(string: avatarUrl)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Text(getInitials(from: contact.displayName))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.compound.textPrimary)
                        }
                        .clipShape(Circle())
                    } else {
                        Text(getInitials(from: contact.displayName))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.compound.textPrimary)
                    }
                }
            
            // Contact info
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName ?? "Unknown")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.compound.textPrimary)
                    .lineLimit(1)
                
                Text(contact.lastSeen ?? "")
                    .font(.caption)
                    .foregroundColor(.compound.textSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Call buttons
            HStack(spacing: 16) {
                // Audio call button
                Button {
                    if let roomId = contact.recentCalls.first?.roomId {
                        viewModel.handleAction(.makeCall(roomId: roomId, callType: .audio))
                    }
                } label: {
                    CompoundIcon(\.voiceCall, size: .medium, relativeTo: .body)
                        .foregroundColor(.compound.iconSecondary)
                }
                .buttonStyle(.plain)
                
                // Video call button
                Button {
                    if let roomId = contact.recentCalls.first?.roomId {
                        viewModel.handleAction(.makeCall(roomId: roomId, callType: .video))
                    }
                } label: {
                    CompoundIcon(\.videoCall, size: .medium, relativeTo: .body)
                        .foregroundColor(.compound.iconSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.compound.bgCanvasDefault)
    }
    
    // MARK: - Call History Section
    
    @ViewBuilder
    private var callHistorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Звонки")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.compound.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            
            ForEach(viewModel.viewState.filteredCallHistory) { entry in
                callHistoryRow(entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Make call with same type as previous call
                        viewModel.handleAction(.makeCall(roomId: entry.roomId, callType: entry.callType))
                    }
            }
        }
    }
    
    @ViewBuilder
    private func callHistoryRow(_ entry: CallLogEntry) -> some View {
        HStack(spacing: 12) {
            // Avatar with call type indicator
            ZStack {
                Circle()
                    .fill(Color.compound.bgActionSecondaryRest)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if let avatarUrl = entry.avatarUrl, !avatarUrl.isEmpty {
                            AsyncImage(url: URL(string: avatarUrl)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Text(getInitials(from: entry.displayName))
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.compound.textPrimary)
                            }
                            .clipShape(Circle())
                        } else {
                            Text(getInitials(from: entry.displayName))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.compound.textPrimary)
                        }
                    }
                
                // Call type indicator
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(getCallDirectionColor(entry.direction, entry.status))
                            .frame(width: 16, height: 16)
                            .overlay {
                                CompoundIcon(entry.callType.icon, size: .xSmall, relativeTo: .caption2)
                                    .foregroundColor(.white)
                            }
                    }
                }
            }
            
            // Call info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.displayName ?? "Unknown")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.compound.textPrimary)
                        .lineLimit(1)
                    
                    if entry.callCount > 1 {
                        Text("(\(entry.callCount))")
                            .font(.body)
                            .foregroundColor(.compound.textSecondary)
                    }
                }
                
                HStack(spacing: 4) {
                    CompoundIcon(getCallDirectionIcon(entry.direction), size: .xSmall, relativeTo: .caption)
                        .foregroundColor(getCallDirectionColor(entry.direction, entry.status))
                    
                    Text(getCallDirectionText(entry.direction, entry.status))
                        .font(.caption)
                        .foregroundColor(.compound.textSecondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Time and info button
            VStack(alignment: .trailing, spacing: 8) {
                Text(entry.formattedTimestamp)
                    .font(.caption)
                    .foregroundColor(.compound.textSecondary)
                
                Button {
                    viewModel.handleAction(.showContactDetails(entry.userId))
                } label: {
                    CompoundIcon(\.info, size: .small, relativeTo: .caption)
                        .foregroundColor(.compound.iconSecondary)
                        .padding(4)
                        .background(Circle().fill(Color.compound.bgSubtleSecondary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.compound.bgCanvasDefault)
    }
    
    // MARK: - Search Results
    
    @ViewBuilder
    private var searchResultsView: some View {
        VStack(spacing: 0) {
            if !viewModel.viewState.filteredContacts.isEmpty {
                ForEach(viewModel.viewState.filteredContacts) { contact in
                    contactRow(contact)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.handleAction(.showContactDetails(contact.userId))
                        }
                }
                
                if !viewModel.viewState.filteredCallHistory.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            
            if !viewModel.viewState.filteredCallHistory.isEmpty {
                ForEach(viewModel.viewState.filteredCallHistory) { entry in
                    callHistoryRow(entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.handleAction(.makeCall(roomId: entry.roomId, callType: entry.callType))
                        }
                }
            }
            
            if viewModel.viewState.filteredContacts.isEmpty, viewModel.viewState.filteredCallHistory.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    CompoundIcon(\.search, size: .large, relativeTo: .title)
                        .foregroundColor(.compound.iconSecondary)
                    Text("Ничего не найдено")
                        .font(.body)
                        .foregroundColor(.compound.textSecondary)
                    Spacer()
                }
                .frame(minHeight: 200)
            }
        }
    }
    
    // MARK: - Empty State
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            CompoundIcon(\.voiceCall, size: .large, relativeTo: .title)
                .foregroundColor(.compound.iconSecondary)
            Text("Звонки")
                .font(.title2)
                .foregroundColor(.compound.textPrimary)
            Text("История звонков будет отображаться здесь")
                .font(.body)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }
    
    // MARK: - Helper Methods
    
    private func getInitials(from name: String?) -> String {
        guard let name = name, !name.isEmpty else { return "?" }
        let components = name.split(separator: " ")
        let initials = components.prefix(2).compactMap(\.first).map { String($0) }
        return initials.joined().uppercased()
    }
    
    private func getCallDirectionIcon(_ direction: CallDirection) -> KeyPath<CompoundIcons, Image> {
        switch direction {
        case .incoming:
            return \.callIncoming
        case .outgoing:
            return \.callOutgoing
        case .missed:
            return \.callMissed
        }
    }
    
    private func getCallDirectionColor(_ direction: CallDirection, _ status: CallStatus) -> Color {
        if status == .missed || direction == .missed {
            return .red
        } else {
            return .compound.iconSecondary
        }
    }
    
    private func getCallDirectionText(_ direction: CallDirection, _ status: CallStatus) -> String {
        if status == .missed {
            return "Пропущенный"
        }
        return direction.displayName
    }
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Extensions

private extension CallLogEntry {
    var callCount: Int {
        // This would be calculated based on grouped calls in real implementation
        1
    }
}

// MARK: - Previews

struct CallLogView_Previews: PreviewProvider {
    static var previews: some View {
        CallLogView(userSession: UserSessionMock(.init()))
    }
}
