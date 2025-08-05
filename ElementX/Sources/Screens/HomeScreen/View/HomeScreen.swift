//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SentrySwiftUI
import SwiftUI

#if LIVEKIT_ENABLED
import LiveKit
#endif

struct HomeScreen: View {
    @ObservedObject var context: HomeScreenViewModel.Context
    let userSession: UserSessionProtocol
    
    @State private var scrollViewAdapter = ScrollViewAdapter()
    @State private var selectedTab: HomeScreenTab = .chats
    
    var body: some View {
        VStack(spacing: 0) {
            // Main content area
            switch selectedTab {
            case .chats:
                HomeScreenContent(context: context, scrollViewAdapter: scrollViewAdapter)
                    .alert(item: $context.alertInfo)
                    .alert(item: $context.leaveRoomAlertItem,
                           actions: leaveRoomAlertActions,
                           message: leaveRoomAlertMessage)
                    .navigationTitle(getNavigationTitle(for: selectedTab))
                    .toolbar(content: { toolbar })
            case .actual:
                actualContentView
                    .navigationTitle(getNavigationTitle(for: selectedTab))
                    .toolbar(content: { toolbar })
            case .calls:
                callsContentView
                    .navigationTitle(getNavigationTitle(for: selectedTab))
                    .toolbar(content: { toolbar })
            case .communities:
                communitiesContentView
                    .navigationTitle(getNavigationTitle(for: selectedTab))
                    .toolbar(content: { toolbar })
            case .settings:
                // Настройки теперь открываются напрямую через модальное окно
                EmptyView()
            }
            
            // Bottom tab bar
            tabBar
        }
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .track(screen: .Home)
        .bloom()
        .sentryTrace("\(Self.self)")
    }
    
    // MARK: - Private
    
    private func getNavigationTitle(for tab: HomeScreenTab) -> String {
        switch tab {
        case .chats:
            return "Чаты"
        case .actual:
            return "Актуальное"
        case .calls:
            return "Звонки"
        case .communities:
            return "Сообщества"
        case .settings:
            return "Настройки"
        }
    }
    
    // MARK: - Tab Content Views
    
    @ViewBuilder
    private var actualContentView: some View {
        VStack {
            Spacer()
            Text("Актуальное")
                .font(.title2)
                .foregroundColor(.compound.textSecondary)
            Text("Здесь будут отображаться актуальные обновления")
                .font(.body)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }
    
    @ViewBuilder
    private var callsContentView: some View {
        CallLogView(userSession: userSession)
    }
    
    @ViewBuilder
    private var communitiesContentView: some View {
        VStack {
            Spacer()
            Text("Сообщества")
                .font(.title2)
                .foregroundColor(.compound.textSecondary)
            Text("Доступные сообщества появятся здесь")
                .font(.body)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }
    
    @ViewBuilder
    private var tabBar: some View {
        VStack(spacing: 0) {
            // Tab bar content
            HStack(spacing: 0) {
                ForEach(HomeScreenTab.allCases) { tab in
                    tabButton(for: tab)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Color.compound.bgCanvasDefault)
        }
    }
    
    @ViewBuilder
    private func tabButton(for tab: HomeScreenTab) -> some View {
        Button {
            if tab == .settings {
                // Открываем настройки напрямую
                context.send(viewAction: .showSettings)
            } else {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    CompoundIcon(tab.icon, size: .medium, relativeTo: .body)
                        .foregroundColor(selectedTab == tab ? .compound.iconPrimary : .compound.iconSecondary)
                        .scaleEffect(1.15)
                    
                    // Badge for chats tab
                    if tab == .chats, context.viewState.totalUnreadCount > 0 {
                        Text("\(context.viewState.totalUnreadCount)")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 12, y: -8)
                    }
                    
                    // Green dot for settings tab (notifications indicator)
                    if tab == .settings, context.viewState.requiresExtraAccountSetup {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .offset(x: 12, y: -8)
                    }
                }
                
                Text(tab.title)
                    .font(.caption)
                    .foregroundColor(selectedTab == tab ? .compound.textPrimary : .compound.textSecondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
        
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                // Функционал создания конференции будет добавлен в следующих релизах
            } label: {
                CompoundIcon(\.videoCall, size: .medium, relativeTo: .body)
                    .foregroundColor(.compound.iconSecondary)
            }
            .accessibilityLabel("Создать конференцию")
        }
        
        ToolbarItem(placement: .primaryAction) {
            newRoomButton
        }
    }
    
    @ViewBuilder
    private var newRoomButton: some View {
        switch context.viewState.roomListMode {
        case .empty, .rooms:
            Button {
                context.send(viewAction: .startChat)
            } label: {
                CompoundIcon(\.plus)
            }
            .buttonStyle(.compound(.super, size: .toolbarIcon))
            .accessibilityLabel(L10n.actionStartChat)
            .accessibilityIdentifier(A11yIdentifiers.homeScreen.startChat)
        default:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func leaveRoomAlertActions(_ item: LeaveRoomAlertItem) -> some View {
        Button(item.cancelTitle, role: .cancel) { }
        Button(item.confirmationTitle, role: .destructive) {
            context.send(viewAction: .confirmLeaveRoom(roomIdentifier: item.roomID))
        }
    }
    
    private func leaveRoomAlertMessage(_ item: LeaveRoomAlertItem) -> some View {
        Text(item.subtitle)
    }
}

// MARK: - CallLogView (Embedded)

// MARK: - Shared Utilities

private extension HomeScreen {
    /// Utility function to extract initials from a display name
    /// Used across multiple components to maintain consistency
    static func getInitials(from name: String) -> String {
        let components = name.split(separator: " ")
        let initials = components.prefix(2).compactMap(\.first).map { String($0) }
        return initials.joined().uppercased()
    }
    
    /// Utility function to format timestamp with Russian locale
    /// Used across multiple components to maintain consistency
    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Вчера"
        } else if calendar.dateInterval(of: .weekOfYear, for: date)?.contains(Date()) == true {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            formatter.dateFormat = "dd.MM.yy"
            return formatter.string(from: date)
        }
    }
}

struct CallLogView: View {
    let userSession: UserSessionProtocol
    @StateObject private var viewModel: CallLogViewModel
    @State private var searchQuery = ""
    
    init(userSession: UserSessionProtocol) {
        self.userSession = userSession
        _viewModel = StateObject(wrappedValue: CallLogViewModel(userSession: userSession))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack {
                CompoundIcon(\.search, size: .small, relativeTo: .body)
                    .foregroundColor(.compound.iconTertiary)
                
                TextField("Поиск", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.compound.bodyMD)
                    .onChange(of: searchQuery) { _, newValue in
                        viewModel.updateSearchQuery(newValue)
                    }
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        CompoundIcon(\.close, size: .small, relativeTo: .body)
                            .foregroundColor(.compound.iconTertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.compound.bgSubtleSecondary)
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            // Content
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Contacts Section
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Контакты")
                                .font(.compound.headingSM)
                                .foregroundColor(.compound.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                        
                        ForEach(viewModel.filteredContacts, id: \.id) { contact in
                            contactRow(contact)
                        }
                    }
                    
                    // Recent Calls Section
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Недавние")
                                .font(.compound.headingSM)
                                .foregroundColor(.compound.textPrimary)
                            Spacer()
                            Button("Очистить") {
                                viewModel.showClearHistoryConfirmation()
                            }
                            .font(.compound.bodyMD)
                            .foregroundColor(.compound.textActionPrimary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                        
                        ForEach(viewModel.recentCalls, id: \.id) { call in
                            callHistoryRow(call)
                        }
                    }
                }
            }
        }
        .background(Color.compound.bgCanvasDefault)
        .alert("Ошибка звонка", isPresented: .constant(viewModel.callError != nil)) {
            Button("OK") {
                viewModel.callError = nil
            }
        } message: {
            if let error = viewModel.callError {
                Text(error)
            }
        }
        .sheet(isPresented: $viewModel.showingContactDetails) {
            if let contact = viewModel.selectedContact {
                ContactDetailsView(contact: contact, viewModel: viewModel)
            }
        }
        .alert("Очистить историю звонков", isPresented: $viewModel.showingClearHistoryConfirmation) {
            Button("Отмена", role: .cancel) { }
            Button("Очистить", role: .destructive) {
                viewModel.clearCallHistory()
            }
        } message: {
            Text("Вся история звонков будет удалена. Это действие нельзя отменить.")
        }
    }
    
    @ViewBuilder
    private func contactRow(_ contact: RealContact) -> some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(Color.compound.bgActionSecondaryRest)
                .frame(width: 40, height: 40)
                .overlay {
                    Text(HomeScreen.getInitials(from: contact.displayName ?? contact.userId))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.compound.textPrimary)
                }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName ?? contact.userId)
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textPrimary)
                    .lineLimit(1)
                
                if let lastCall = contact.lastCall {
                    HStack(spacing: 4) {
                        CompoundIcon(lastCall.icon, size: .xSmall, relativeTo: .caption)
                            .foregroundColor(contact.isMissed ? .red : .compound.iconSecondary)
                        
                        Text(contact.formattedCallTime)
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }
                } else {
                    Text("Нет звонков")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                }
            }
            
            Spacer()
            
            // Call buttons
            HStack(spacing: 12) {
                Button {
                    viewModel.makeCall(to: contact, callType: .audio)
                } label: {
                    if viewModel.isCallingInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(8)
                            .background(Circle().fill(Color.compound.bgSubtleSecondary))
                    } else {
                        CompoundIcon(\.voiceCall, size: .medium, relativeTo: .body)
                            .foregroundColor(.compound.iconSecondary)
                            .padding(8)
                            .background(Circle().fill(Color.compound.bgSubtleSecondary))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCallingInProgress)
                
                Button {
                    viewModel.makeCall(to: contact, callType: .video)
                } label: {
                    if viewModel.isCallingInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(8)
                            .background(Circle().fill(Color.compound.bgSubtleSecondary))
                    } else {
                        CompoundIcon(\.videoCall, size: .medium, relativeTo: .body)
                            .foregroundColor(.compound.iconSecondary)
                            .padding(8)
                            .background(Circle().fill(Color.compound.bgSubtleSecondary))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCallingInProgress)
                
                Button {
                    viewModel.showContactDetails(for: contact)
                } label: {
                    CompoundIcon(\.info, size: .medium, relativeTo: .body)
                        .foregroundColor(.compound.iconSecondary)
                        .padding(8)
                        .background(Circle().fill(Color.compound.bgSubtleSecondary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.compound.bgCanvasDefault)
    }
    
    @ViewBuilder
    private func callHistoryRow(_ call: RealCallEntry) -> some View {
        HStack(spacing: 12) {
            // Call type icon with direction
            ZStack {
                Circle()
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 40, height: 40)
                    .overlay {
                        CompoundIcon(call.callType.icon, size: .medium, relativeTo: .body)
                            .foregroundColor(.compound.iconSecondary)
                    }
                
                // Missed call indicator
                if call.isMissed {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Circle()
                                .fill(.red)
                                .frame(width: 14, height: 14)
                                .overlay {
                                    Image(systemName: "phone.down.fill")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(.white)
                                }
                        }
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(call.displayName ?? call.userId)
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textPrimary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Image(systemName: call.isMissed ? "phone.down.fill" : "phone.arrow.down.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(call.isMissed ? .red : .compound.iconSecondary)
                    
                    Text(call.isMissed ? "Пропущенный" : call.direction.displayName)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                    
                    if let duration = call.formattedDuration {
                        Text("• \(duration)")
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(call.formattedTimestamp)
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                
                Button {
                    viewModel.makeCall(roomId: call.roomId, callType: call.callType)
                } label: {
                    if viewModel.isCallingInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        CompoundIcon(call.callType.icon, size: .medium, relativeTo: .body)
                            .foregroundColor(.compound.iconSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCallingInProgress)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.compound.bgCanvasDefault)
    }
}

// MARK: - ContactDetailsView

struct ContactDetailsView: View {
    let contact: RealContact
    let viewModel: CallLogViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                contactHeader
                callButtons
                recentCallsSection
                Spacer()
            }
            .navigationTitle("Контакт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
        .background(Color.compound.bgCanvasDefault)
    }
    
    @ViewBuilder
    private var contactHeader: some View {
        VStack(spacing: 16) {
            // Avatar
            Circle()
                .fill(Color.compound.bgActionSecondaryRest)
                .frame(width: 80, height: 80)
                .overlay {
                    Text(HomeScreen.getInitials(from: contact.displayName ?? contact.userId))
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.compound.textPrimary)
                }
            
            // Contact info
            VStack(spacing: 4) {
                Text(contact.displayName ?? contact.userId)
                    .font(.compound.headingLG)
                    .foregroundColor(.compound.textPrimary)
                
                Text(contact.userId)
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
                
                if let lastCall = contact.lastCall {
                    HStack(spacing: 6) {
                        CompoundIcon(lastCall.icon, size: .small, relativeTo: .caption)
                            .foregroundColor(contact.isMissed ? .red : .compound.iconSecondary)
                        
                        Text("Последний звонок: \(contact.formattedCallTime)")
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }
                }
            }
        }
        .padding(.top, 32)
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder
    private var callButtons: some View {
        HStack(spacing: 24) {
            // Audio call button
            Button {
                viewModel.makeCall(to: contact, callType: .audio)
                dismiss()
            } label: {
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color.compound.bgActionPrimaryRest)
                        .frame(width: 56, height: 56)
                        .overlay {
                            if viewModel.isCallingInProgress {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                CompoundIcon(\.voiceCall, size: .medium, relativeTo: .body)
                                    .foregroundColor(.white)
                            }
                        }
                    
                    Text("Аудио")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCallingInProgress)
            
            // Video call button
            Button {
                viewModel.makeCall(to: contact, callType: .video)
                dismiss()
            } label: {
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color.compound.bgActionPrimaryRest)
                        .frame(width: 56, height: 56)
                        .overlay {
                            if viewModel.isCallingInProgress {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                CompoundIcon(\.videoCall, size: .medium, relativeTo: .body)
                                    .foregroundColor(.white)
                            }
                        }
                    
                    Text("Видео")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCallingInProgress)
        }
        .padding(.top, 24)
    }
    
    @ViewBuilder
    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Недавние звонки")
                    .font(.compound.headingSM)
                    .foregroundColor(.compound.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 32)
            .padding(.bottom, 16)
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    let contactCalls = viewModel.recentCalls.filter { $0.roomId == contact.roomId }
                    
                    ForEach(contactCalls, id: \.id) { call in
                        ContactCallHistoryRow(call: call, viewModel: viewModel)
                    }
                    
                    if contactCalls.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "phone")
                                .font(.system(size: 32, weight: .light))
                                .foregroundColor(.compound.iconTertiary)
                            
                            Text("Нет истории звонков")
                                .font(.compound.bodyMD)
                                .foregroundColor(.compound.textSecondary)
                        }
                        .padding(.top, 32)
                    }
                }
            }
        }
    }
}

// MARK: - ContactCallHistoryRow

struct ContactCallHistoryRow: View {
    let call: RealCallEntry
    let viewModel: CallLogViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            // Call type icon with direction
            Circle()
                .fill(Color.compound.bgSubtleSecondary)
                .frame(width: 40, height: 40)
                .overlay {
                    CompoundIcon(call.callType.icon, size: .medium, relativeTo: .body)
                        .foregroundColor(.compound.iconSecondary)
                }
                .overlay(alignment: .bottomTrailing) {
                    if call.isMissed {
                        Circle()
                            .fill(.red)
                            .frame(width: 14, height: 14)
                            .overlay {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.white)
                            }
                    }
                }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: call.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(call.isMissed ? .red : .compound.iconSecondary)
                    
                    Text(call.isMissed ? "Пропущенный" : call.direction.displayName)
                        .font(.compound.bodyMD)
                        .foregroundColor(.compound.textPrimary)
                }
                
                HStack(spacing: 4) {
                    Text(call.formattedTimestamp)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                    
                    if let duration = call.formattedDuration {
                        Text("• \(duration)")
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }
                }
            }
            
            Spacer()
            
            Button {
                viewModel.makeCall(roomId: call.roomId, callType: call.callType)
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
    }
}

// MARK: - Real Models

struct RealContact: Identifiable {
    let id: String
    let userId: String
    let displayName: String?
    let avatarURL: URL?
    let roomId: String
    let lastCall: CallType?
    let lastCallTime: Date?
    let isMissed: Bool
    
    var formattedCallTime: String {
        guard let lastCallTime = lastCallTime else { return "" }
        return HomeScreen.formatTimestamp(lastCallTime)
    }
}

struct RealCallEntry: Identifiable {
    let id: String
    let roomId: String
    let userId: String
    let displayName: String?
    let avatarURL: URL?
    let callType: CallType
    let direction: CallDirection
    let status: CallStatus
    let timestamp: Date
    let duration: TimeInterval?
    
    var formattedTimestamp: String {
        HomeScreen.formatTimestamp(timestamp)
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
    
    var isMissed: Bool {
        status == .missed || (direction == .incoming && status != .answered)
    }
}

// MARK: - CallLogViewModel

@MainActor
class CallLogViewModel: ObservableObject {
    @Published var filteredContacts: [RealContact] = []
    @Published var recentCalls: [RealCallEntry] = []
    @Published var isLoading = false
    @Published var searchQuery = ""
    @Published var isCallingInProgress = false
    @Published var callError: String?
    @Published var selectedContact: RealContact?
    @Published var showingContactDetails = false
    @Published var showingClearHistoryConfirmation = false
    
    private let userSession: UserSessionProtocol
    private var allContacts: [RealContact] = []
    private var allCalls: [RealCallEntry] = []
    private var cancellables = Set<AnyCancellable>()
    
    // LiveKit integration
    #if LIVEKIT_ENABLED
    private var liveKitService: LiveKitCallService?
    private var liveKitAuthService: LiveKitAuthService?
    private var callKitService: LiveKitCallKitService?
    #endif
    
    init(userSession: UserSessionProtocol) {
        self.userSession = userSession
        setupLiveKitServices()
        loadData()
    }
    
    private func setupLiveKitServices() {
        #if LIVEKIT_ENABLED
        // Initialize auth service
        liveKitAuthService = LiveKitAuthService(clientProxy: userSession.clientProxy)
        liveKitAuthService?.configure(userSession: userSession)
        
        // Initialize CallKit service first
        callKitService = LiveKitCallKitService()
        callKitService?.configureWithClientProxy(userSession.clientProxy)
        
        // Initialize call service with CallKit integration
        if let authService = liveKitAuthService {
            liveKitService = LiveKitCallService(authService: authService, clientProxy: userSession.clientProxy, callKitService: callKitService)
        }
        
        // Connect CallKit to LiveKit service
        if let liveKit = liveKitService, let callKit = callKitService {
            callKit.setLiveKitCallService(liveKit)
            // Configure CallKit integration for incoming calls
            liveKit.configureCallKitService(callKit)
            
            // Ensure Matrix call service is ready for VoIP events
            Task { [weak self] in
                guard let self = self else { return }
                await Task.detached {
                    // Give some time for user session to fully initialize
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    await MainActor.run {
                        // Update client proxy to ensure it's current
                        liveKit.updateClientProxy(self.userSession.clientProxy)
                        liveKit.ensureMatrixCallServiceReady()
                    }
                }.value
            }
        }
        
        MXLog.info("LiveKit and CallKit services initialized for CallLog")
        #else
        MXLog.warning("LiveKit is not enabled - calls will be logged only")
        #endif
    }
    
    func updateSearchQuery(_ query: String) {
        searchQuery = query
        filterData()
    }
    
    private func loadData() {
        isLoading = true
        
        Task {
            await loadDirectMessageRooms()
            await loadCallHistory()
            filterData()
            isLoading = false
        }
    }
    
    private func loadDirectMessageRooms() async {
        // Получаем список прямых сообщений из RoomSummaryProvider
        let roomSummaryProvider = userSession.clientProxy.roomSummaryProvider
        let roomSummaries = roomSummaryProvider.roomListPublisher.value
        let directMessageRooms = roomSummaries.filter(\.isDirect)
        
        allContacts = directMessageRooms.compactMap { summary in
            // Для DM комнат берем первого героя как контакт
            guard let hero = summary.heroes.first else { return nil }
            
            return RealContact(id: summary.id,
                               userId: hero.userID,
                               displayName: hero.displayName ?? hero.userID,
                               avatarURL: hero.avatarURL,
                               roomId: summary.id,
                               lastCall: nil, // Будет заполнено из истории звонков
                               lastCallTime: nil,
                               isMissed: false)
        }
    }
    
    private func loadCallHistory() async {
        // ИНТЕГРАЦИЯ С CALL HISTORY MANAGER: Загружаем реальную историю звонков
        let callHistoryEntries = await CallHistoryManager.shared.getCallHistory()
        
        // Используем реальную историю звонков
        // let callHistoryEntries: [Any] = [] // Больше не нужен stub
        
        // Конвертируем CallHistoryEntry в RealCallEntry для UI
        allCalls = callHistoryEntries.map { entry in
            let participantName: String
            let participantUserId: String
            let isIncoming: Bool
            
            if entry.callInfo.direction == .incoming {
                participantName = entry.callInfo.caller.displayName ?? entry.callInfo.caller.userId
                participantUserId = entry.callInfo.caller.userId
                isIncoming = true
            } else {
                participantName = entry.callInfo.callee.displayName ?? entry.callInfo.callee.userId
                participantUserId = entry.callInfo.callee.userId
                isIncoming = false
            }
            
            return RealCallEntry(id: entry.id,
                                 roomId: entry.callInfo.roomId,
                                 userId: participantUserId,
                                 displayName: participantName,
                                 avatarURL: entry.callInfo.direction == .incoming ?
                                     entry.callInfo.caller.avatarURL : entry.callInfo.callee.avatarURL,
                                 callType: entry.callInfo.type,
                                 direction: entry.callInfo.direction,
                                 status: entry.callInfo.status,
                                 timestamp: entry.callInfo.timestamp,
                                 duration: entry.callInfo.duration)
        }
        
        // Сортируем по времени (новые сверху)
        allCalls.sort { $0.timestamp > $1.timestamp }
        
        MXLog.info("[CallLogViewModel] ✅ Loaded \(allCalls.count) call history entries")
        
        // Обновляем контакты с информацией о последних звонках
        updateContactsWithCallHistory()
    }
    
    private func updateContactsWithCallHistory() {
        // Для каждого контакта находим последний звонок
        for i in allContacts.indices {
            let contact = allContacts[i]
            
            // Ищем последний звонок с этим контактом
            let contactCalls = allCalls.filter { call in
                call.roomId == contact.roomId || call.userId == contact.userId
            }
            
            if let lastCall = contactCalls.first {
                allContacts[i] = RealContact(id: contact.id,
                                             userId: contact.userId,
                                             displayName: contact.displayName,
                                             avatarURL: contact.avatarURL,
                                             roomId: contact.roomId,
                                             lastCall: lastCall.callType,
                                             lastCallTime: lastCall.timestamp,
                                             isMissed: lastCall.status == .missed)
            }
        }
    }
    
    /// Refresh call history from CallHistoryManager
    func refreshCallHistory() {
        Task {
            await loadCallHistory()
            filterData()
        }
    }
    
    private func filterData() {
        if searchQuery.isEmpty {
            filteredContacts = allContacts
            recentCalls = allCalls
        } else {
            filteredContacts = allContacts.filter { contact in
                (contact.displayName?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
                    contact.userId.localizedCaseInsensitiveContains(searchQuery)
            }
            
            recentCalls = allCalls.filter { call in
                (call.displayName?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
                    call.userId.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }
    
    func makeCall(to contact: RealContact, callType: CallType) {
        Task {
            await startCall(roomId: contact.roomId, callType: callType, displayName: contact.displayName ?? contact.userId)
        }
    }
    
    func makeCall(roomId: String, callType: CallType) {
        Task {
            await startCall(roomId: roomId, callType: callType, displayName: "Unknown")
        }
    }
    
    private func startCall(roomId: String, callType: CallType, displayName: String) async {
        #if LIVEKIT_ENABLED
        guard let callKitService = callKitService else {
            MXLog.error("CallKit service not available")
            await MainActor.run {
                callError = "Сервис звонков недоступен"
            }
            return
        }
        
        await MainActor.run {
            isCallingInProgress = true
            callError = nil
        }
        
        do {
            MXLog.info("Starting \(callType.rawValue) call to \(displayName) in room: \(roomId) through CallKit")
            
            let callId = UUID().uuidString
            let isVideo = (callType == .video)
            
            // Start call through CallKit - this will show native iOS call UI
            try await callKitService.startOutgoingCall(roomId: roomId,
                                                       callId: callId,
                                                       participantName: displayName,
                                                       isVideo: isVideo)
            
            MXLog.info("CallKit outgoing call initiated successfully")
            
            await MainActor.run {
                isCallingInProgress = false
            }
            
            // CallKit will handle the UI and call lifecycle from here
            
        } catch {
            MXLog.error("Failed to start CallKit call: \(error)")
            
            await MainActor.run {
                isCallingInProgress = false
                
                if let callKitError = error as? LiveKitCallKitError {
                    callError = callKitError.localizedDescription
                } else {
                    callError = "Не удалось начать звонок: \(error.localizedDescription)"
                }
            }
        }
        #else
        MXLog.info("LiveKit not enabled - would start \(callType.rawValue) call to \(displayName)")
        await MainActor.run {
            callError = "LiveKit не включен в этой сборке"
        }
        #endif
    }
    
    func showContactDetails(for contact: RealContact) {
        selectedContact = contact
        showingContactDetails = true
    }
    
    func showClearHistoryConfirmation() {
        showingClearHistoryConfirmation = true
    }
    
    func clearCallHistory() {
        allCalls.removeAll()
        filterData()
        showingClearHistoryConfirmation = false
        
        // В реальной реализации здесь бы была очистка истории в Matrix
        MXLog.info("Call history cleared from local storage")
        
        // ПРИМЕЧАНИЕ: Очистка истории звонков в Matrix SDK
        // будет реализована при интеграции с Matrix SDK API для событий звонков
    }
}

// MARK: - Previews

struct HomeScreen_Previews: PreviewProvider, TestablePreview {
    static let loadingViewModel = viewModel(.skeletons)
    static let emptyViewModel = viewModel(.empty)
    static let loadedViewModel = viewModel(.rooms)
    
    static var previews: some View {
        NavigationStack {
            HomeScreen(context: loadingViewModel.context, userSession: UserSessionMock(.init(clientProxy: ClientProxyMock(.init()))))
        }
        .snapshotPreferences(expect: loadedViewModel.context.$viewState.map { state in
            state.roomListMode == .skeletons
        })
        .previewDisplayName("Loading")
        
        NavigationStack {
            HomeScreen(context: emptyViewModel.context, userSession: UserSessionMock(.init(clientProxy: ClientProxyMock(.init()))))
        }
        .snapshotPreferences(expect: emptyViewModel.context.$viewState.map { state in
            state.roomListMode == .empty
        })
        .previewDisplayName("Empty")
        
        NavigationStack {
            HomeScreen(context: loadedViewModel.context, userSession: UserSessionMock(.init(clientProxy: ClientProxyMock(.init()))))
        }
        .snapshotPreferences(expect: loadedViewModel.context.$viewState.map { state in
            state.roomListMode == .rooms
        })
        .previewDisplayName("Loaded")
    }
    
    static func viewModel(_ mode: HomeScreenRoomListMode) -> HomeScreenViewModel {
        let userID = "@alice:example.com"
        
        let roomSummaryProviderState: RoomSummaryProviderMockConfigurationState = switch mode {
        case .skeletons:
            .loading
        case .empty:
            .loaded([])
        case .rooms:
            .loaded(.mockRooms)
        }
        
        let clientProxy = ClientProxyMock(.init(userID: userID,
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: roomSummaryProviderState))))
        
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        
        return HomeScreenViewModel(userSession: userSession,
                                   selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                   appSettings: ServiceLocator.shared.settings,
                                   analyticsService: ServiceLocator.shared.analytics,
                                   notificationManager: NotificationManagerMock(),
                                   badgeCountService: BadgeCountService(appSettings: ServiceLocator.shared.settings),
                                   userIndicatorController: ServiceLocator.shared.userIndicatorController)
    }
}
