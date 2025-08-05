//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct LiveKitCallRoomTimelineItem: EventBasedTimelineItemProtocol, Equatable {
    let id: TimelineItemIdentifier
    let timestamp: Date
    let isEditable: Bool
    let canBeRepliedTo: Bool
    let isOutgoing: Bool
    
    let sender: TimelineItemSender
    
    // Call-specific properties
    let callType: CallType
    let callState: CallState
    let callDuration: TimeInterval? // Duration in seconds, nil if ongoing/unknown
    
    var properties = RoomTimelineItemProperties()
    
    var body: String {
        switch callState {
        case .started:
            return callType == .video ? "Video call started" : "Voice call started"
        case .active:
            return callType == .video ? "Video call active" : "Voice call active"
        case .ended:
            return callType == .video ? "Video call ended" : "Voice call ended"
        case .declined:
            return callType == .video ? "Video call declined" : "Voice call declined"
        case .missed:
            return callType == .video ? "Missed video call" : "Missed voice call"
        }
    }
    
    
    enum CallState: Equatable {
        case started
        case active
        case ended
        case declined
        case missed
    }
}
