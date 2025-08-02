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
                return "Звонок начат"
            case .audio:
                return "Звонок начат"
            }
        case .active:
            switch timelineItem.callType {
            case .video:
                return "Звонок активен"
            case .audio:
                return "Звонок активен"
            }
        case .ended:
            switch timelineItem.callType {
            case .video:
                return "Звонок завершен"
            case .audio:
                return "Звонок завершен"
            }
        case .declined:
            switch timelineItem.callType {
            case .video:
                return "Звонок отклонен"
            case .audio:
                return "Звонок отклонен"
            }
        case .missed:
            switch timelineItem.callType {
            case .video:
                return "Пропущенный звонок"
            case .audio:
                return "Пропущенный звонок"
            }
        }
    }
    
    private var callIcon: KeyPath<CompoundIcons, Image> {
        // Always use video call icon for LiveKit calls (as shown in screenshot)
        return \.videoCallSolid
    }
    
    private func formatCallDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "0:%02d", seconds)
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
                
                // Show ONLY duration if available, no time duplication
                if let duration = timelineItem.callDuration {
                    Text(formatCallDuration(duration))
                        .font(.compound.bodyXS)
                        .foregroundColor(.compound.textSecondary)
                }
                // Time is already shown by Timeline system, no need to duplicate
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
            LiveKitCallRoomTimelineView(timelineItem: .init(id: .randomEvent,
                                                            timestamp: .mock,
                                                            isEditable: false,
                                                            canBeRepliedTo: false,
                                                            isOutgoing: false,
                                                            sender: .init(id: "testuser2", displayName: "Test User"),
                                                            callType: .video,
                                                            callState: .started,
                                                            callDuration: nil))
            
            // Audio call started
            LiveKitCallRoomTimelineView(timelineItem: .init(id: .randomEvent,
                                                            timestamp: .mock,
                                                            isEditable: false,
                                                            canBeRepliedTo: false,
                                                            isOutgoing: false,
                                                            sender: .init(id: "testuser2", displayName: "Test User"),
                                                            callType: .audio,
                                                            callState: .started,
                                                            callDuration: nil))
            
            // Missed video call
            LiveKitCallRoomTimelineView(timelineItem: .init(id: .randomEvent,
                                                            timestamp: .mock,
                                                            isEditable: false,
                                                            canBeRepliedTo: false,
                                                            isOutgoing: false,
                                                            sender: .init(id: "testuser2", displayName: "Test User"),
                                                            callType: .video,
                                                            callState: .missed,
                                                            callDuration: nil))
        }
        .environmentObject(viewModel.context)
        .padding()
    }
}
