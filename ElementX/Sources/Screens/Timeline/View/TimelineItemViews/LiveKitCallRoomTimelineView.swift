//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct LiveKitCallRoomTimelineView: View {
    @Environment(\.timelineContext) private var context
    
    let timelineItem: LiveKitCallRoomTimelineItem
    
    private var callMessage: String {
        switch timelineItem.callState {
        case .started:
            switch timelineItem.callType {
            case .video:
                return "📹 Видеовызов начат"
            case .audio:
                return "📞 Аудиовызов начат"
            }
        case .ended:
            switch timelineItem.callType {
            case .video:
                return "📹 Видеовызов завершен"
            case .audio:
                return "📞 Аудиовызов завершен"
            }
        case .declined:
            switch timelineItem.callType {
            case .video:
                return "📹 Видеовызов отклонен"
            case .audio:
                return "📞 Аудиовызов отклонен"
            }
        case .missed:
            switch timelineItem.callType {
            case .video:
                return "📹 Пропущенный видеовызов"
            case .audio:
                return "📞 Пропущенный аудиовызов"
            }
        }
    }
    
    private var callIcon: KeyPath<CompoundIcons, Image> {
        switch timelineItem.callType {
        case .video:
            return \.videoCallSolid
        case .audio:
            return \.voiceCallSolid
        }
    }
    
    var body: some View {
        TimelineStyler(timelineItem: timelineItem) {
            HStack(spacing: 8) {
                CompoundIcon(callIcon, size: .medium, relativeTo: .compound.bodyMD)
                    .foregroundColor(.compound.iconSecondary)
                
                Text(callMessage)
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textPrimary)
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                Text(timelineItem.timestamp.formattedTime())
                    .font(.compound.bodyXS)
                    .foregroundColor(.compound.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.compound.bgSubtlePrimary.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.compound.borderInteractiveSecondary, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Previews

struct LiveKitCallRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    
    static var previews: some View {
        VStack(spacing: 16) {
            // Video call started
            LiveKitCallRoomTimelineView(timelineItem: .init(
                id: .randomEvent,
                timestamp: .mock,
                isEditable: false,
                canBeRepliedTo: false,
                isOutgoing: false,
                sender: .init(id: "testuser2", displayName: "Test User"),
                callType: .video,
                callState: .started
            ))
            
            // Audio call started
            LiveKitCallRoomTimelineView(timelineItem: .init(
                id: .randomEvent,
                timestamp: .mock,
                isEditable: false,
                canBeRepliedTo: false,
                isOutgoing: false,
                sender: .init(id: "testuser2", displayName: "Test User"),
                callType: .audio,
                callState: .started
            ))
            
            // Missed video call
            LiveKitCallRoomTimelineView(timelineItem: .init(
                id: .randomEvent,
                timestamp: .mock,
                isEditable: false,
                canBeRepliedTo: false,
                isOutgoing: false,
                sender: .init(id: "testuser2", displayName: "Test User"),
                callType: .video,
                callState: .missed
            ))
        }
        .environmentObject(viewModel.context)
        .padding()
    }
}