//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit
import SwiftUI
import Compound

// MARK: - Call Type

enum CallType: String, CaseIterable, Codable, Equatable {
    case audio = "audio"
    case video = "video"
    
    var icon: KeyPath<CompoundIcons, Image> {
        switch self {
        case .audio:
            return \.voiceCall
        case .video:
            return \.videoCall
        }
    }
    
    var iconSolid: KeyPath<CompoundIcons, Image> {
        switch self {
        case .audio:
            return \.voiceCallSolid
        case .video:
            return \.videoCallSolid
        }
    }
}

// MARK: - Call Direction

enum CallDirection: String, CaseIterable, Codable {
    case incoming = "incoming"
    case outgoing = "outgoing"
    case missed = "missed"
    
    var displayName: String {
        switch self {
        case .incoming:
            return "Входящий"
        case .outgoing:
            return "Исходящий"
        case .missed:
            return "Пропущенный"
        }
    }
}

// MARK: - Call Status

enum CallStatus: String, CaseIterable, Codable {
    case answered = "answered"
    case declined = "declined"
    case missed = "missed"
    case cancelled = "cancelled"
    case busy = "busy"
    case failed = "failed"
    
    var displayName: String {
        switch self {
        case .answered:
            return "Отвечен"
        case .declined:
            return "Отклонен"
        case .missed:
            return "Пропущен"
        case .cancelled:
            return "Отменен"
        case .busy:
            return "Занято"
        case .failed:
            return "Не удался"
        }
    }
}

// MARK: - Tab Navigation

enum HomeScreenTab: String, CaseIterable, Identifiable {
    case actual = "actual"
    case calls = "calls"
    case communities = "communities"
    case chats = "chats"
    case settings = "settings"
    
    var id: String {
        rawValue
    }
    
    var title: String {
        switch self {
        case .actual:
            return "Актуальное"
        case .calls:
            return "Звонки"
        case .communities:
            return "Сообщества"
        case .chats:
            return "Чаты"
        case .settings:
            return "Настройки"
        }
    }
    
    var icon: KeyPath<CompoundIcons, Image> {
        switch self {
        case .actual:
            return \.threads
        case .calls:
            return \.voiceCall
        case .communities:
            return \.public
        case .chats:
            return \.chat
        case .settings:
            return \.settings
        }
    }
}

enum HomeScreenViewModelAction: Equatable {
    case presentRoom(roomIdentifier: String)
    case presentRoomDetails(roomIdentifier: String)
    case presentReportRoom(roomIdentifier: String)
    case presentDeclineAndBlock(userID: String, roomID: String)
    case roomLeft(roomIdentifier: String)
    case presentSecureBackupSettings
    case presentRecoveryKeyScreen
    case presentEncryptionResetScreen
    case presentSettingsScreen
    case presentFeedbackScreen
    case presentStartChatScreen
    case presentGlobalSearch
    case logoutWithoutConfirmation
    case logout
}

enum HomeScreenViewAction {
    case selectRoom(roomIdentifier: String)
    case showRoomDetails(roomIdentifier: String)
    case leaveRoom(roomIdentifier: String)
    case confirmLeaveRoom(roomIdentifier: String)
    case reportRoom(roomIdentifier: String)
    case showSettings
    case startChat
    case setupRecovery
    case confirmRecoveryKey
    case resetEncryption
    case skipRecoveryKeyConfirmation
    case updateVisibleItemRange(Range<Int>)
    case globalSearch
    case markRoomAsUnread(roomIdentifier: String)
    case markRoomAsRead(roomIdentifier: String)
    case markRoomAsFavourite(roomIdentifier: String, isFavourite: Bool)
    
    case acceptInvite(roomIdentifier: String)
    case declineInvite(roomIdentifier: String)
}

enum HomeScreenRoomListMode: CustomStringConvertible {
    case skeletons
    case empty
    case rooms
    
    var description: String {
        switch self {
        case .skeletons:
            return "Showing placeholders"
        case .empty:
            return "Showing empty state"
        case .rooms:
            return "Showing rooms"
        }
    }
}

enum HomeScreenSecurityBannerMode: Equatable {
    case none
    case dismissed
    case show(HomeScreenRecoveryKeyConfirmationBanner.State)
    
    var isDismissed: Bool {
        switch self {
        case .dismissed: true
        default: false
        }
    }
    
    var isShown: Bool {
        switch self {
        case .show: true
        default: false
        }
    }
}

struct HomeScreenViewState: BindableState {
    let userID: String
    var userDisplayName: String?
    var userAvatarURL: URL?
    
    var securityBannerMode = HomeScreenSecurityBannerMode.none
    
    var requiresExtraAccountSetup = false
        
    var rooms: [HomeScreenRoom] = []
    var roomListMode: HomeScreenRoomListMode = .skeletons
    
    var hasPendingInvitations = false
        
    var selectedRoomID: String?
    
    var hideInviteAvatars = false
    
    var reportRoomEnabled = false
    
    var totalUnreadCount: Int = 0
    
    var visibleRooms: [HomeScreenRoom] {
        if roomListMode == .skeletons {
            return placeholderRooms
        }
        
        return rooms
    }
        
    var bindings = HomeScreenViewStateBindings()
    
    var placeholderRooms: [HomeScreenRoom] {
        (1...10).map { _ in
            HomeScreenRoom.placeholder()
        }
    }
    
    // Used to hide all the rooms when the search field is focused and the query is empty
    var shouldHideRoomList: Bool {
        bindings.isSearchFieldFocused && bindings.searchQuery.isEmpty
    }
    
    var shouldShowEmptyFilterState: Bool {
        !bindings.isSearchFieldFocused && bindings.filtersState.isFiltering && visibleRooms.isEmpty
    }
    
    var shouldShowFilters: Bool {
        !bindings.isSearchFieldFocused && roomListMode == .rooms
    }
}

struct HomeScreenViewStateBindings {
    var filtersState = RoomListFiltersState()
    var searchQuery = ""
    var isSearchFieldFocused = false
    
    var alertInfo: AlertInfo<UUID>?
    var leaveRoomAlertItem: LeaveRoomAlertItem?
}

struct HomeScreenRoom: Identifiable, Equatable {
    enum RoomType: Equatable {
        case placeholder
        case room
        case invite(inviterDetails: RoomInviterDetails?)
        case knock
    }
    
    static let placeholderLastMessage = AttributedString("Hidden last message")
        
    /// The list item identifier is it's room identifier.
    let id: String
    
    /// The real room identifier this item points to
    let roomID: String?
    
    let type: RoomType
    
    var inviter: RoomInviterDetails? {
        if case .invite(let inviter) = type {
            return inviter
        }
        return nil
    }
    
    let badges: Badges
    struct Badges: Equatable {
        let isDotShown: Bool
        let isMentionShown: Bool
        let isMuteShown: Bool
        let isCallShown: Bool
    }
    
    let name: String
    
    let isDirect: Bool
    
    let isHighlighted: Bool
    
    let isFavourite: Bool
    
    let timestamp: String?
    
    let lastMessage: AttributedString?
    
    let avatar: RoomAvatar
        
    let canonicalAlias: String?
    
    let isTombstoned: Bool
    
    var displayedLastMessage: AttributedString? {
        // If the room is tombstoned, show a specific message, regardless of any last message.
        guard !isTombstoned else {
            return AttributedString(L10n.screenRoomlistTombstonedRoomDescription)
        }
        return lastMessage
    }
    
    static func placeholder() -> HomeScreenRoom {
        HomeScreenRoom(id: UUID().uuidString,
                       roomID: nil,
                       type: .placeholder,
                       badges: .init(isDotShown: false, isMentionShown: false, isMuteShown: false, isCallShown: false),
                       name: "Placeholder room name",
                       isDirect: false,
                       isHighlighted: false,
                       isFavourite: false,
                       timestamp: "Now",
                       lastMessage: placeholderLastMessage,
                       avatar: .room(id: "", name: "", avatarURL: nil),
                       canonicalAlias: nil,
                       isTombstoned: false)
    }
}

extension HomeScreenRoom {
    init(summary: RoomSummary, hideUnreadMessagesBadge: Bool, seenInvites: Set<String> = []) {
        let roomID = summary.id
        
        let hasUnreadMessages = hideUnreadMessagesBadge ? false : summary.hasUnreadMessages
        let isUnseenInvite = summary.joinRequestType?.isInvite == true && !seenInvites.contains(roomID)

        let isDotShown = hasUnreadMessages || summary.hasUnreadMentions || summary.hasUnreadNotifications || summary.isMarkedUnread || isUnseenInvite
        let isMentionShown = summary.hasUnreadMentions && !summary.isMuted
        let isMuteShown = summary.isMuted
        let isCallShown = summary.hasOngoingCall
        let isHighlighted = summary.isMarkedUnread || (!summary.isMuted && (summary.hasUnreadNotifications || summary.hasUnreadMentions)) || isUnseenInvite
        
        let type: HomeScreenRoom.RoomType = switch summary.joinRequestType {
        case .invite(let inviter): .invite(inviterDetails: inviter.map(RoomInviterDetails.init))
        case .knock: .knock
        case .none: .room
        }
        
        self.init(id: roomID,
                  roomID: summary.id,
                  type: type,
                  badges: .init(isDotShown: isDotShown,
                                isMentionShown: isMentionShown,
                                isMuteShown: isMuteShown,
                                isCallShown: isCallShown),
                  name: summary.name,
                  isDirect: summary.isDirect,
                  isHighlighted: isHighlighted,
                  isFavourite: summary.isFavourite,
                  timestamp: summary.lastMessageDate?.formattedMinimal(),
                  lastMessage: summary.lastMessage,
                  avatar: summary.avatar,
                  canonicalAlias: summary.canonicalAlias,
                  isTombstoned: summary.isTombstoned)
    }
}
