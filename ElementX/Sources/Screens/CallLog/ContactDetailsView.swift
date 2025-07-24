//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import Compound

struct ContactDetailsView: View {
    let contact: ContactWithCallHistory
    let onCallAction: (CallType) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with avatar and name
                headerView
                    .padding(.top, 20)
                    .padding(.bottom, 30)
                
                // Call buttons
                callButtonsSection
                    .padding(.bottom, 30)
                
                // Recent calls history
                if !contact.recentCalls.isEmpty {
                    recentCallsSection
                }
                
                Spacer()
            }
            .background(Color.compound.bgCanvasDefault)
            .navigationTitle("Контакт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") {
                        onDismiss()
                    }
                    .foregroundColor(.compound.textActionPrimary)
                }
            }
        }
    }
    
    // MARK: - Header
    
    @ViewBuilder
    private var headerView: some View {
        VStack(spacing: 16) {
            // Avatar
            Circle()
                .fill(Color.compound.bgActionSecondaryRest)
                .frame(width: 80, height: 80)
                .overlay {
                    if let avatarUrl = contact.avatarUrl, !avatarUrl.isEmpty {
                        AsyncImage(url: URL(string: avatarUrl)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Text(getInitials(from: contact.displayName))
                                .font(.system(size: 32, weight: .medium))
                                .foregroundColor(.compound.textPrimary)
                        }
                        .clipShape(Circle())
                    } else {
                        Text(getInitials(from: contact.displayName))
                            .font(.system(size: 32, weight: .medium))
                            .foregroundColor(.compound.textPrimary)
                    }
                }
            
            // Name and status
            VStack(spacing: 4) {
                Text(contact.displayName ?? "Unknown")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.compound.textPrimary)
                
                Text(contact.lastSeen ?? "")
                    .font(.body)
                    .foregroundColor(.compound.textSecondary)
            }
        }
    }
    
    // MARK: - Call Buttons
    
    @ViewBuilder
    private var callButtonsSection: some View {
        HStack(spacing: 40) {
            // Audio call button
            VStack(spacing: 8) {
                Button {
                    onCallAction(.audio)
                } label: {
                    Circle()
                        .fill(Color.compound.bgActionPrimaryRest)
                        .frame(width: 60, height: 60)
                        .overlay {
                            CompoundIcon(\.voiceCall, size: .large, relativeTo: .title)
                                .foregroundColor(.white)
                        }
                }
                .buttonStyle(.plain)
                
                Text("Аудио")
                    .font(.caption)
                    .foregroundColor(.compound.textSecondary)
            }
            
            // Video call button
            VStack(spacing: 8) {
                Button {
                    onCallAction(.video)
                } label: {
                    Circle()
                        .fill(Color.compound.bgActionPrimaryRest)
                        .frame(width: 60, height: 60)
                        .overlay {
                            CompoundIcon(\.videoCall, size: .large, relativeTo: .title)
                                .foregroundColor(.white)
                        }
                }
                .buttonStyle(.plain)
                
                Text("Видео")
                    .font(.caption)
                    .foregroundColor(.compound.textSecondary)
            }
        }
    }
    
    // MARK: - Recent Calls
    
    @ViewBuilder
    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text("Недавние")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.compound.textPrimary)
                
                Spacer()
                
                if contact.recentCalls.count > 3 {
                    Button("Все") {
                        // Show all calls - could navigate to full call history
                    }
                    .font(.body)
                    .foregroundColor(.compound.textActionPrimary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            
            // Recent calls list
            ForEach(contact.recentCalls.prefix(3), id: \.id) { call in
                recentCallRow(call)
            }
        }
    }
    
    @ViewBuilder
    private func recentCallRow(_ call: CallLogEntry) -> some View {
        HStack(spacing: 12) {
            // Call type icon with direction indicator
            ZStack {
                Circle()
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 40, height: 40)
                    .overlay {
                        CompoundIcon(call.callType.icon, size: .medium, relativeTo: .body)
                            .foregroundColor(.compound.iconSecondary)
                    }
                
                // Direction indicator
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(getCallDirectionColor(call.direction, call.status))
                            .frame(width: 14, height: 14)
                            .overlay {
                                CompoundIcon(getCallDirectionIcon(call.direction), size: .xSmall, relativeTo: .caption2)
                                    .foregroundColor(.white)
                            }
                    }
                }
            }
            
            // Call info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(getCallTypeDisplayName(call.callType))
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.compound.textPrimary)
                    
                    Spacer()
                    
                    Text(call.formattedTimestamp)
                        .font(.caption)
                        .foregroundColor(.compound.textSecondary)
                }
                
                HStack {
                    HStack(spacing: 4) {
                        CompoundIcon(getCallDirectionIcon(call.direction), size: .xSmall, relativeTo: .caption)
                            .foregroundColor(getCallDirectionColor(call.direction, call.status))
                        
                        Text(getCallDirectionText(call.direction, call.status))
                            .font(.caption)
                            .foregroundColor(.compound.textSecondary)
                    }
                    
                    if let duration = call.formattedDuration {
                        Text("• \(duration)")
                            .font(.caption)
                            .foregroundColor(.compound.textSecondary)
                    }
                    
                    Spacer()
                }
            }
            
            // Call button
            Button {
                onCallAction(call.callType)
            } label: {
                CompoundIcon(call.callType.icon, size: .medium, relativeTo: .body)
                    .foregroundColor(.compound.iconSecondary)
                    .padding(8)
                    .background(Circle().fill(Color.compound.bgSubtleSecondary))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.compound.bgCanvasDefault)
    }
    
    // MARK: - Helper Methods
    
    private func getInitials(from name: String?) -> String {
        guard let name = name, !name.isEmpty else { return "?" }
        let components = name.split(separator: " ")
        let initials = components.prefix(2).compactMap { $0.first }.map { String($0) }
        return initials.joined().uppercased()
    }
    
    private func getCallTypeDisplayName(_ callType: CallType) -> String {
        switch callType {
        case .audio:
            return "Аудиозвонок"
        case .video:
            return "Видеозвонок"
        }
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
}

// MARK: - Previews

struct ContactDetailsView_Previews: PreviewProvider {
    static var previews: some View {
        ContactDetailsView(
            contact: ContactWithCallHistory(
                id: "@bolat:example.com",
                userId: "@bolat:example.com",
                displayName: "Болат Нач Упр Закупки",
                avatarUrl: nil,
                lastSeen: "Онлайн",
                recentCalls: [
                    CallLogEntry(
                        roomId: "!room1:example.com",
                        userId: "@bolat:example.com",
                        displayName: "Болат Нач Упр Закупки",
                        avatarUrl: nil,
                        callType: .video,
                        direction: .outgoing,
                        status: .answered,
                        timestamp: Date().addingTimeInterval(-3600),
                        duration: 125
                    ),
                    CallLogEntry(
                        roomId: "!room1:example.com",
                        userId: "@bolat:example.com",
                        displayName: "Болат Нач Упр Закупки",
                        avatarUrl: nil,
                        callType: .audio,
                        direction: .incoming,
                        status: .answered,
                        timestamp: Date().addingTimeInterval(-7200),
                        duration: 67
                    )
                ]
            ),
            onCallAction: { _ in },
            onDismiss: { }
        )
    }
}