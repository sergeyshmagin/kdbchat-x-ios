//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import AnalyticsEvents
import AVKit
import Combine
import MatrixRustSDK
import SwiftUI

#if LIVEKIT_ENABLED
import CallKit
import LiveKit
#endif

/// Результат валидации существующего ключа восстановления
enum RecoveryKeyValidationResult {
    case valid      // Ключ валиден и может быть переиспользован
    case invalid    // Ключ невалиден и должен быть заменен
    case unknown    // Не удалось определить валидность ключа
}

enum UserSessionFlowCoordinatorAction {
    case logout
    case clearCache
    case refreshVoIPToken
    case clearAllVoIPTokens
    case showPusherInfo
    case forceReregisterVoIPPusher
    case forceReregisterPushers
    /// Logout without a confirmation. The user forgot their PIN.
    case forceLogout
}

class UserSessionFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private let navigationRootCoordinator: NavigationRootCoordinator
    private let navigationSplitCoordinator: NavigationSplitCoordinator
    private let bugReportService: BugReportServiceProtocol
    #if LIVEKIT_ENABLED
    // LiveKit services are passed to initializer
    #else
    private let elementCallService: ElementCallServiceProtocol
    #endif
    private let appMediator: AppMediatorProtocol
    
    #if LIVEKIT_ENABLED
    private let liveKitCallKitService: LiveKitCallKitService
    #endif
    private let appSettings: AppSettings
    private let appHooks: AppHooks
    private let analytics: AnalyticsService
    private let notificationManager: NotificationManagerProtocol
    private let badgeCountService: BadgeCountServiceProtocol
    
    private let stateMachine: UserSessionFlowCoordinatorStateMachine
    
    // periphery:ignore - retaining purpose
    private var roomFlowCoordinator: RoomFlowCoordinator?
    private let timelineControllerFactory: TimelineControllerFactoryProtocol
    
    private let settingsFlowCoordinator: SettingsFlowCoordinator
    
    private let onboardingFlowCoordinator: OnboardingFlowCoordinator
    
    // periphery:ignore - retaining purpose
    private var bugReportFlowCoordinator: BugReportFlowCoordinator?
    
    // periphery:ignore - retaining purpose
    private var encryptionResetFlowCoordinator: EncryptionResetFlowCoordinator?
    
    // periphery:ignore - retaining purpose
    private var globalSearchScreenCoordinator: GlobalSearchScreenCoordinator?
    
    private var cancellables = Set<AnyCancellable>()
    
    private let sidebarNavigationStackCoordinator: NavigationStackCoordinator
    private let detailNavigationStackCoordinator: NavigationStackCoordinator

    private let selectedRoomSubject = CurrentValueSubject<String?, Never>(nil)
    
    private let actionsSubject: PassthroughSubject<UserSessionFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<UserSessionFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// For testing purposes.
    var statePublisher: AnyPublisher<UserSessionFlowCoordinatorStateMachine.State, Never> { stateMachine.statePublisher }
    
    #if LIVEKIT_ENABLED
    init(userSession: UserSessionProtocol,
         navigationRootCoordinator: NavigationRootCoordinator,
         appLockService: AppLockServiceProtocol,
         bugReportService: BugReportServiceProtocol,
         liveKitAuthService: LiveKitAuthServiceProtocol,
         liveKitCallKitService: LiveKitCallKitService,
         timelineControllerFactory: TimelineControllerFactoryProtocol,
         appMediator: AppMediatorProtocol,
         appSettings: AppSettings,
         appHooks: AppHooks,
         analytics: AnalyticsService,
         notificationManager: NotificationManagerProtocol,
         badgeCountService: BadgeCountServiceProtocol,
         isNewLogin: Bool) {
        stateMachine = UserSessionFlowCoordinatorStateMachine()
        self.userSession = userSession
        self.navigationRootCoordinator = navigationRootCoordinator
        self.bugReportService = bugReportService
        self.liveKitCallKitService = liveKitCallKitService
        self.timelineControllerFactory = timelineControllerFactory
        self.appMediator = appMediator
        self.appSettings = appSettings
        self.appHooks = appHooks
        self.analytics = analytics
        self.notificationManager = notificationManager
        self.badgeCountService = badgeCountService
        
        navigationSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator())
        
        sidebarNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        detailNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        
        navigationSplitCoordinator.setSidebarCoordinator(sidebarNavigationStackCoordinator)
                
        settingsFlowCoordinator = SettingsFlowCoordinator(parameters: .init(userSession: userSession,
                                                                            windowManager: appMediator.windowManager,
                                                                            appLockService: appLockService,
                                                                            bugReportService: bugReportService,
                                                                            notificationSettings: userSession.clientProxy.notificationSettings,
                                                                            secureBackupController: userSession.clientProxy.secureBackupController,
                                                                            appSettings: appSettings,
                                                                            navigationSplitCoordinator: navigationSplitCoordinator,
                                                                            userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                            analytics: analytics))
        
        onboardingFlowCoordinator = OnboardingFlowCoordinator(userSession: userSession,
                                                              appLockService: appLockService,
                                                              analyticsService: analytics,
                                                              appSettings: appSettings,
                                                              notificationManager: notificationManager,
                                                              navigationStackCoordinator: detailNavigationStackCoordinator,
                                                              userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                              windowManager: appMediator.windowManager,
                                                              isNewLogin: isNewLogin)
        
        setupStateMachine()
        
        setupObservers()
        
        // Reset the forced PIN unlock flag.
        if isNewLogin {
            // Note: biometricUnlockTrust property might not be available in all AppLockService implementations
            // appLockService.biometricUnlockTrust = .trusted
        }
    }
    #else
    init(userSession: UserSessionProtocol,
         navigationRootCoordinator: NavigationRootCoordinator,
         appLockService: AppLockServiceProtocol,
         bugReportService: BugReportServiceProtocol,
         elementCallService: ElementCallServiceProtocol,
         timelineControllerFactory: TimelineControllerFactoryProtocol,
         appMediator: AppMediatorProtocol,
         appSettings: AppSettings,
         appHooks: AppHooks,
         analytics: AnalyticsService,
         notificationManager: NotificationManagerProtocol,
         badgeCountService: BadgeCountServiceProtocol,
         isNewLogin: Bool) {
        stateMachine = UserSessionFlowCoordinatorStateMachine()
        self.userSession = userSession
        self.navigationRootCoordinator = navigationRootCoordinator
        self.bugReportService = bugReportService
        self.elementCallService = elementCallService
        self.timelineControllerFactory = timelineControllerFactory
        self.appMediator = appMediator
        self.appSettings = appSettings
        self.appHooks = appHooks
        self.analytics = analytics
        self.notificationManager = notificationManager
        self.badgeCountService = badgeCountService
        
        #if LIVEKIT_ENABLED
        liveKitCallKitService = LiveKitCallKitService()
        #endif
        
        navigationSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator())
        
        sidebarNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        detailNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        
        navigationSplitCoordinator.setSidebarCoordinator(sidebarNavigationStackCoordinator)
                
        settingsFlowCoordinator = SettingsFlowCoordinator(parameters: .init(userSession: userSession,
                                                                            windowManager: appMediator.windowManager,
                                                                            appLockService: appLockService,
                                                                            bugReportService: bugReportService,
                                                                            notificationSettings: userSession.clientProxy.notificationSettings,
                                                                            secureBackupController: userSession.clientProxy.secureBackupController,
                                                                            appSettings: appSettings,
                                                                            navigationSplitCoordinator: navigationSplitCoordinator,
                                                                            userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                            analytics: analytics))
        
        onboardingFlowCoordinator = OnboardingFlowCoordinator(userSession: userSession,
                                                              appLockService: appLockService,
                                                              analyticsService: analytics,
                                                              appSettings: appSettings,
                                                              notificationManager: notificationManager,
                                                              navigationStackCoordinator: detailNavigationStackCoordinator,
                                                              userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                              windowManager: appMediator.windowManager,
                                                              isNewLogin: isNewLogin)
        
        setupStateMachine()
        
        setupObservers()
    }
    #endif
    
    func start() {
        stateMachine.processEvent(.start)
    }
    
    func stop() { }

    func isDisplayingRoomScreen(withRoomID roomID: String) -> Bool {
        stateMachine.isDisplayingRoomScreen(withRoomID: roomID)
    }
    
    // MARK: - FlowCoordinatorProtocol
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        Task {
            await asyncHandleAppRoute(appRoute, animated: animated)
        }
    }
    
    func clearRoute(animated: Bool) {
        roomFlowCoordinator?.clearRoute(animated: animated)
    }

    // MARK: - Private
    
    func asyncHandleAppRoute(_ appRoute: AppRoute, animated: Bool) async {
        showLoadingIndicator(delay: .seconds(0.5))
        defer { hideLoadingIndicator() }
        
        await clearPresentedSheets(animated: animated)
        
        switch appRoute {
        case .room(let roomID, let via):
            stateMachine.processEvent(.selectRoom(roomID: roomID, via: via, entryPoint: .room), userInfo: .init(animated: animated))
        case .roomAlias(let alias):
            switch await userSession.clientProxy.resolveRoomAlias(alias) {
            case .success(let resolved): await asyncHandleAppRoute(.room(roomID: resolved.roomId, via: resolved.servers), animated: animated)
            case .failure: showFailureIndicator()
            }
        case .childRoom(let roomID, let via):
            if let roomFlowCoordinator {
                roomFlowCoordinator.handleAppRoute(appRoute, animated: animated)
            } else {
                stateMachine.processEvent(.selectRoom(roomID: roomID, via: via, entryPoint: .room), userInfo: .init(animated: animated))
            }
        case .childRoomAlias(let alias):
            switch await userSession.clientProxy.resolveRoomAlias(alias) {
            case .success(let resolved): await asyncHandleAppRoute(.childRoom(roomID: resolved.roomId, via: resolved.servers), animated: animated)
            case .failure: showFailureIndicator()
            }
            
        case .roomDetails(let roomID):
            if stateMachine.state.roomListSelectedRoomID == roomID {
                roomFlowCoordinator?.handleAppRoute(appRoute, animated: animated)
            } else {
                stateMachine.processEvent(.selectRoom(roomID: roomID, via: [], entryPoint: .roomDetails), userInfo: .init(animated: animated))
            }
        case .roomList:
            roomFlowCoordinator?.clearRoute(animated: animated)
        case .roomMemberDetails:
            roomFlowCoordinator?.handleAppRoute(appRoute, animated: animated)
        case .event(let eventID, let roomID, let via):
            stateMachine.processEvent(.selectRoom(roomID: roomID, via: via, entryPoint: .eventID(eventID)), userInfo: .init(animated: animated))
        case .eventOnRoomAlias(let eventID, let alias):
            switch await userSession.clientProxy.resolveRoomAlias(alias) {
            case .success(let resolved): await asyncHandleAppRoute(.event(eventID: eventID, roomID: resolved.roomId, via: resolved.servers), animated: animated)
            case .failure: showFailureIndicator()
            }
            
        case .childEvent:
            roomFlowCoordinator?.handleAppRoute(appRoute, animated: animated)
        case .childEventOnRoomAlias(let eventID, let alias):
            switch await userSession.clientProxy.resolveRoomAlias(alias) {
            case .success(let resolved): await asyncHandleAppRoute(.childEvent(eventID: eventID, roomID: resolved.roomId, via: resolved.servers), animated: animated)
            case .failure: showFailureIndicator()
            }
            
        case .userProfile(let userID):
            stateMachine.processEvent(.showUserProfileScreen(userID: userID), userInfo: .init(animated: animated))
        case .call(let roomID):
            Task { await presentCallScreen(roomID: roomID, notifyOtherParticipants: false) }
        case .genericCallLink(let url):
            presentCallScreen(genericCallLink: url)
        case .settings, .chatBackupSettings:
            settingsFlowCoordinator.handleAppRoute(appRoute, animated: animated)
        case .share(let payload):
            if let roomID = payload.roomID {
                stateMachine.processEvent(.selectRoom(roomID: roomID,
                                                      via: [],
                                                      entryPoint: .share(payload)),
                                          userInfo: .init(animated: animated))
            } else {
                stateMachine.processEvent(.showShareExtensionRoomList(sharePayload: payload), userInfo: .init(animated: animated))
            }
        case .accountProvisioningLink:
            break // We always ignore this flow when logged in.
        }
    }
    
    private var onboardingAttempted = false
    private var homeScreenPresented = false
    
    func attemptStartingOnboarding() {
        guard !onboardingAttempted else {
            MXLog.info("Onboarding already attempted, skipping")
            return
        }
        onboardingAttempted = true
        
        MXLog.info("Attempting to start onboarding")
        if onboardingFlowCoordinator.shouldStart {
            MXLog.info("Onboarding is required, starting...")
            clearRoute(animated: false)
            onboardingFlowCoordinator.start()
        } else {
            MXLog.info("Onboarding is not required, skipping - ensuring home screen is shown")
            if !homeScreenPresented {
                MXLog.info("Home screen not yet presented, ensuring it's shown")
                presentHomeScreen()
            } else {
                MXLog.info("Home screen already presented, no action needed")
            }
        }
    }
    
    private func clearPresentedSheets(animated: Bool) async {
        if navigationSplitCoordinator.sheetCoordinator == nil {
            return
        }
        
        navigationSplitCoordinator.setSheetCoordinator(nil, animated: animated)
        
        // Prevents system crashes when presenting a sheet if another one was already shown
        try? await Task.sleep(for: .seconds(0.25))
    }
    
    private func setupStateMachine() {
        stateMachine.addTransitionHandler { [weak self] context in
            guard let self else { return }
            let animated = (context.userInfo as? UserSessionFlowCoordinatorStateMachine.EventUserInfo)?.animated ?? true
            switch (context.fromState, context.event, context.toState) {
            case (.initial, .start, .roomList):
                MXLog.info("State machine transition: .initial -> .start -> .roomList")
                attemptStartingOnboarding()
            case(.roomList(let roomListSelectedRoomID), .selectRoom(let roomID, let via, let entryPoint), .roomList):
                if roomListSelectedRoomID == roomID,
                   !entryPoint.isEventID, // Don't reuse the existing room so the live timeline is hidden while the detached timeline is loading.
                   let roomFlowCoordinator {
                    let route: AppRoute = switch entryPoint {
                    case .room: .room(roomID: roomID, via: via)
                    case .roomDetails: .roomDetails(roomID: roomID)
                    case .eventID(let eventID): .event(eventID: eventID, roomID: roomID, via: via) // ignored.
                    case .share(let payload): .share(payload)
                    }
                    roomFlowCoordinator.handleAppRoute(route, animated: animated)
                } else {
                    Task { await self.startRoomFlow(roomID: roomID, via: via, entryPoint: entryPoint, animated: animated) }
                }
                #if !LIVEKIT_ENABLED
                hideCallScreenOverlay() // Turn any active call into a PiP so that navigation from a notification is visible to the user.
                #endif
            case(.roomList, .deselectRoom, .roomList):
                dismissRoomFlow(animated: animated)
                                
            case (.roomList, .showSettingsScreen, .settingsScreen):
                break
            case (.settingsScreen, .dismissedSettingsScreen, .roomList):
                break
                
            case (.roomList, .feedbackScreen, .feedbackScreen):
                bugReportFlowCoordinator = BugReportFlowCoordinator(parameters: .init(presentationMode: .sheet(sidebarNavigationStackCoordinator),
                                                                                      userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                                      bugReportService: bugReportService,
                                                                                      userSession: userSession))
                bugReportFlowCoordinator?.start()
            case (.feedbackScreen, .dismissedFeedbackScreen, .roomList):
                break
                
            case (.roomList, .showRecoveryKeyScreen, .recoveryKeyScreen):
                presentRecoveryKeyScreen(animated: animated)
            case (.recoveryKeyScreen, .dismissedRecoveryKeyScreen, .roomList):
                break
                
            case (.roomList, .startEncryptionResetFlow, .encryptionResetFlow):
                startEncryptionResetFlow(animated: animated)
            case (.encryptionResetFlow, .finishedEncryptionResetFlow, .roomList):
                break
                
            case (.roomList, .showStartChatScreen, .startChatScreen):
                presentStartChat(animated: animated)
            case (.startChatScreen, .dismissedStartChatScreen, .roomList):
                break
                
            case (.roomList, .showLogoutConfirmationScreen, .logoutConfirmationScreen):
                presentSecureBackupLogoutConfirmationScreen()
            case (.logoutConfirmationScreen, .dismissedLogoutConfirmationScreen, .roomList):
                break
                
            case (.roomList, .showRoomDirectorySearchScreen, .roomDirectorySearchScreen):
                presentRoomDirectorySearch()
            case (.roomDirectorySearchScreen, .dismissedRoomDirectorySearchScreen, .roomList):
                dismissRoomDirectorySearch()
            
            case (_, .showUserProfileScreen(let userID), .userProfileScreen):
                presentUserProfileScreen(userID: userID, animated: animated)
            case (.userProfileScreen, .dismissedUserProfileScreen, .roomList):
                break
                
            case (.roomList, .presentReportRoomScreen(let roomID), .reportRoomScreen):
                Task { await self.presentReportRoom(for: roomID) }
            case (.reportRoomScreen, .dismissedReportRoomScreen, .roomList):
                break
                
            case (.roomList, .presentDeclineAndBlockScreen(let userID, let roomID), .declineAndBlockUserScreen):
                presentDeclineAndBlockScreen(userID: userID, roomID: roomID)
            case (.declineAndBlockUserScreen, .dismissedDeclineAndBlockScreen, .roomList):
                break
                
            case (.roomList(let roomListSelectedRoomID), .showShareExtensionRoomList, .shareExtensionRoomList(let sharePayload)):
                Task {
                    if roomListSelectedRoomID != nil {
                        self.clearRoute(animated: animated)
                        try? await Task.sleep(for: .seconds(1.5))
                    }
                    
                    self.presentRoomSelectionScreen(sharePayload: sharePayload, animated: animated)
                }
            case (.shareExtensionRoomList, .dismissedShareExtensionRoomList, .roomList):
                dismissRoomSelectionScreen()
                
            default:
                MXLog.error("Unknown transition: \(context)")
                // Просто логируем и продолжаем
            }
        }
        
        stateMachine.addTransitionHandler { [weak self] context in
            switch context.toState {
            case .roomList(let roomListSelectedRoomID):
                self?.selectedRoomSubject.send(roomListSelectedRoomID)
            default:
                break
            }
        }
        
        stateMachine.addErrorHandler { context in
            if context.fromState == context.toState {
                MXLog.error("Failed transition from equal states: \(context.fromState)")
            } else {
                MXLog.error("Failed transition with context: \(context)")
                // Просто логируем и продолжаем
            }
        }
    }
    
    private func setupObservers() {
        userSession.sessionSecurityStatePublisher
            .map(\.verificationState)
            .filter { $0 != .unknown }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                
                attemptStartingOnboarding()
                
                setupSessionVerificationRequestsObserver()
            }
            .store(in: &cancellables)
        
        settingsFlowCoordinator.actions.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .presentedSettings:
                stateMachine.processEvent(.showSettingsScreen)
            case .dismissedSettings:
                stateMachine.processEvent(.dismissedSettingsScreen)
            case .runLogoutFlow:
                Task { await self.runLogoutFlow() }
            case .clearCache:
                actionsSubject.send(.clearCache)
            case .refreshVoIPToken:
                actionsSubject.send(.refreshVoIPToken)
            case .clearAllVoIPTokens:
                actionsSubject.send(.clearAllVoIPTokens)
            case .showPusherInfo:
                // This is handled locally in DeveloperOptionsScreenCoordinator
                break
            case .forceReregisterVoIPPusher:
                actionsSubject.send(.forceReregisterVoIPPusher)
            case .forceReregisterPushers:
                actionsSubject.send(.forceReregisterPushers)
            case .forceLogout:
                actionsSubject.send(.forceLogout)
            }
        }
        .store(in: &cancellables)
        
        userSession.clientProxy.actionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .receivedDecryptionError(let info):
                    processDecryptionError(info)
                case .receivedSyncUpdate:
                    Task {
                        let roomSummaries = self.userSession.clientProxy.staticRoomSummaryProvider.roomListPublisher.value
                        await self.notificationManager.removeDeliveredNotificationsForFullyReadRooms(roomSummaries)
                    }
                case .autoRecoveryKeySetupCompleted:
                    handleAutoRecoveryKeySetupCompleted()
                case .autoRecoveryKeySetupFailed(let error):
                    handleAutoRecoveryKeySetupFailed(error)
                case .backupRestoreCompleted:
                    handleBackupRestoreCompleted()
                case .backupRestoreFailed(let error):
                    handleBackupRestoreFailed(error)
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        #if !LIVEKIT_ENABLED
        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                switch action {
                case .endCall:
                    self?.dismissCallScreenIfNeeded()
                default:
                    break
                }
            }
            .store(in: &cancellables)
        #endif
        
        onboardingFlowCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .logout:
                    logout()
                case .complete:
                    MXLog.info("Onboarding completed, onboarding flow finished")
                    // Onboarding завершен, возвращаемся к основному экрану
                    presentHomeScreen()
                }
            }
            .store(in: &cancellables)
        
        // Настраиваем автоматические ключи восстановления при запуске
        setupAutoRecoveryKeySystem()
    }
    
    private func processDecryptionError(_ info: UnableToDecryptInfo) {
        let timeToDecryptMs: Int
        if let unsignedTimeToDecryptMs = info.timeToDecryptMs {
            timeToDecryptMs = Int(unsignedTimeToDecryptMs)
        } else {
            timeToDecryptMs = -1
        }
        
        let errorName: AnalyticsEvent.Error.Name = switch info.cause {
        case .unknown: .OlmKeysNotSentError
        case .unknownDevice, .unsignedDevice: .ExpectedSentByInsecureDevice
        case .verificationViolation: .ExpectedVerificationViolation
        case .sentBeforeWeJoined: .ExpectedDueToMembership
        case .historicalMessageAndBackupIsDisabled, .historicalMessageAndDeviceIsUnverified: .HistoricalMessage
        case .withheldForUnverifiedOrInsecureDevice: .RoomKeysWithheldForUnverifiedDevice
        case .withheldBySender: .OlmKeysNotSentError
        }
        
        analytics.trackError(context: nil,
                             domain: .E2EE,
                             name: errorName,
                             timeToDecryptMillis: timeToDecryptMs,
                             eventLocalAgeMillis: Int(truncatingIfNeeded: info.eventLocalAgeMillis),
                             isFederated: info.ownHomeserver != info.senderHomeserver,
                             isMatrixDotOrg: info.ownHomeserver == "matrix.org",
                             userTrustsOwnIdentity: info.userTrustsOwnIdentity,
                             wasVisibleToUser: nil)
    }
    
    private func setupSessionVerificationRequestsObserver() {
        userSession.clientProxy.sessionVerificationController?.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self, case .receivedVerificationRequest(let details) = action else {
                    return
                }
                
                MXLog.info("Received session verification request")
                
                if details.senderProfile.userID == userSession.clientProxy.userID {
                    presentSessionVerificationScreen(flow: .deviceResponder(requestDetails: details))
                } else {
                    presentSessionVerificationScreen(flow: .userResponder(requestDetails: details))
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Auto Recovery Key Management
    
    /// Настраивает автоматические ключи восстановления после успешного логина
    private func setupAutoRecoveryKeySystem() {
        MXLog.info("Starting auto recovery key system setup")
        
        let userID = userSession.clientProxy.userID
        
        // НОВАЯ ЛОГИКА: Проверяем есть ли уже ключ в keychain для данного пользователя
        let keychainController = KeychainController(service: .sessions, accessGroup: "")
        let hasExistingKey = keychainController.hasSSSSRecoveryKey(forUserID: userID)
        
        if hasExistingKey {
            MXLog.info("Found existing recovery key in keychain for user: \(userID)")
            
            // Проверяем валидность ключа перед использованием
            Task { @MainActor in
                let validationResult = await validateExistingRecoveryKey(userID: userID)
                
                switch validationResult {
                case .valid:
                    MXLog.info("Existing recovery key is valid, proceeding with safe setup")
                    await userSession.clientProxy.performSafeAutoRecoverySetup()
                    // Настраиваем cross-signing после успешной настройки recovery key
                    await setupCrossSigningAutomatically()
                    
                case .invalid:
                    MXLog.warning("Existing recovery key is invalid, will create new one")
                    keychainController.removeSSSSRecoveryKey(forUserID: userID)
                    await userSession.clientProxy.performSafeAutoRecoverySetup()
                    // Настраиваем cross-signing после успешной настройки recovery key
                    await setupCrossSigningAutomatically()
                    
                case .unknown:
                    MXLog.info("Cannot validate existing recovery key, proceeding with safe setup")
                    await userSession.clientProxy.performSafeAutoRecoverySetup()
                    // Настраиваем cross-signing после успешной настройки recovery key
                    await setupCrossSigningAutomatically()
                }
            }
        } else {
            MXLog.info("No existing recovery key found in keychain, creating new one")
            
            // Запускаем БЕЗОПАСНУЮ настройку и восстановление в фоновом режиме
            Task { @MainActor in
                // КРИТИЧНО: Используем новый безопасный метод, который СНАЧАЛА проверяет существующий backup
                // и НИКОГДА не перезаписывает данные без необходимости
                await userSession.clientProxy.performSafeAutoRecoverySetup()
                // Настраиваем cross-signing после успешной настройки recovery key
                await setupCrossSigningAutomatically()
            }
        }
    }
    
    /// Валидирует существующий ключ восстановления в keychain
    private func validateExistingRecoveryKey(userID: String) async -> RecoveryKeyValidationResult {
        MXLog.info("🔍 Validating existing recovery key for user: \(userID)")
        
        let keychainController = KeychainController(service: .sessions, accessGroup: "")
        
        // Пытаемся получить ключ из keychain
        guard let existingKey = keychainController.ssssRecoveryKey(forUserID: userID) else {
            MXLog.warning("Cannot retrieve recovery key from keychain for validation")
            return .unknown
        }
        
        // ИСПОЛЬЗУЕМ ЦЕНТРАЛИЗОВАННУЮ ВАЛИДАЦИЮ из AutoRecoveryKeyService для согласованности
        let validationResult = await userSession.clientProxy.autoRecoveryKeyService.validateLocalKeyReadOnly(existingKey)
        switch validationResult {
        case .success(true):
            MXLog.info("Recovery key format validation passed")
        case .success(false):
            MXLog.error("Recovery key has invalid format: \(existingKey.prefix(10))...")
            return .invalid
        case .failure(let error):
            MXLog.error("Recovery key validation failed: \(error)")
            return .invalid
        }
        
        // Пытаемся проверить ключ через clientProxy
        do {
            let result = userSession.clientProxy.exportRecoveryKeyForBackup()
            switch result {
            case .success(let currentKey):
                if currentKey == existingKey {
                    MXLog.info("✅ Existing recovery key matches current backup key")
                    return .valid
                } else {
                    MXLog.warning("⚠️ Existing recovery key differs from current backup key")
                    return .invalid
                }
            case .failure(let error):
                MXLog.warning("Cannot export current recovery key for comparison: \(error)")
                // Если не можем экспортировать текущий ключ, считаем существующий валидным
                // чтобы избежать ненужной перезаписи
                return .valid
            }
        } catch {
            MXLog.error("Error during recovery key validation: \(error)")
            return .unknown
        }
    }
    
    /// Автоматически настраивает cross-signing для улучшения безопасности шифрования
    private func setupCrossSigningAutomatically() async {
        MXLog.info("🔐 Starting automatic cross-signing setup for improved encryption")
        
        let result = await userSession.clientProxy.setupCrossSigningIfNeeded()
        
        switch result {
        case .success:
            MXLog.info("✅ Cross-signing setup completed successfully")
            
            // Показываем пользователю успешное уведомление
            ServiceLocator.shared.userIndicatorController.submitIndicator(
                UserIndicator(
                    id: "cross_signing_setup_completed",
                    type: .toast,
                    title: "Шифрование настроено",
                    iconName: "checkmark.shield"
                )
            )
            
        case .failure(let error):
            MXLog.error("❌ Cross-signing setup failed: \(error)")
            
            // Показываем предупреждение пользователю
            ServiceLocator.shared.userIndicatorController.submitIndicator(
                UserIndicator(
                    id: "cross_signing_setup_failed",
                    type: .toast,
                    title: "Настройка шифрования не завершена",
                    iconName: "exclamationmark.shield"
                )
            )
        }
    }
    
    /// Обрабатывает успешную настройку автоматических ключей восстановления
    private func handleAutoRecoveryKeySetupCompleted() {
        MXLog.info("Auto recovery key system is now active")
        
        // Можно показать тихое уведомление об успешной настройке
        ServiceLocator.shared.userIndicatorController.submitIndicator(
            UserIndicator(id: "auto_recovery_setup",
                         type: .toast,
                         title: "Recovery key configured",
                         iconName: "checkmark.shield")
        )
    }
    
    /// Обрабатывает ошибку настройки автоматических ключей восстановления
    private func handleAutoRecoveryKeySetupFailed(_ error: String) {
        MXLog.error("Auto recovery key setup failed: \(error)")
        
        // Показываем пользователю опциональное уведомление
        ServiceLocator.shared.userIndicatorController.submitIndicator(
            UserIndicator(id: "auto_recovery_setup_failed",
                         type: .toast,
                         title: "Recovery key setup failed - you can set it up manually in Settings")
        )
    }
    
    /// Обрабатывает успешное восстановление backup'а
    private func handleBackupRestoreCompleted() {
        MXLog.info("Backup restore completed successfully - encrypted messages should now be accessible")
        
        // Можно показать тихое уведомление об успешном восстановлении
        ServiceLocator.shared.userIndicatorController.submitIndicator(
            UserIndicator(id: "backup_restore_completed",
                         type: .toast,
                         title: "Message history restored",
                         iconName: "checkmark.shield")
        )
    }
    
    /// Обрабатывает ошибку восстановления backup'а
    private func handleBackupRestoreFailed(_ error: String) {
        // Логируем ошибку, но не показываем пользователю если это просто отсутствие ключа
        if error.contains("keyRetrievalFailed") {
            MXLog.info("No recovery key found - this is normal for new accounts")
        } else {
            MXLog.error("Backup restore failed: \(error)")
            
            // Показываем уведомление только для серьезных ошибок
            ServiceLocator.shared.userIndicatorController.submitIndicator(
                UserIndicator(id: "backup_restore_failed",
                             type: .toast,
                             title: "Could not restore message history")
            )
        }
    }
    
    private func presentSessionVerificationScreen(flow: SessionVerificationScreenFlow) {
        guard let sessionVerificationController = userSession.clientProxy.sessionVerificationController else {
            MXLog.error("The sessionVerificationController is not available")
            // Пропускаем верификацию сессии - просто продолжаем
            return
        }
        
        let navigationStackCoordinator = NavigationStackCoordinator()
        
        let parameters = SessionVerificationScreenCoordinatorParameters(sessionVerificationControllerProxy: sessionVerificationController,
                                                                        flow: flow,
                                                                        appSettings: appSettings,
                                                                        mediaProvider: userSession.mediaProvider)
        
        let coordinator = SessionVerificationScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .done:
                    self?.navigationSplitCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
        
        navigationSplitCoordinator.setSheetCoordinator(navigationStackCoordinator)
    }
    
    private func presentHomeScreen() {
        guard !homeScreenPresented else {
            MXLog.info("Home screen already presented, skipping duplicate call")
            return
        }
        homeScreenPresented = true
        
        MXLog.info("presentHomeScreen() called - creating HomeScreenCoordinator")
        let parameters = HomeScreenCoordinatorParameters(userSession: userSession,
                                                         bugReportService: bugReportService,
                                                         selectedRoomPublisher: selectedRoomSubject.asCurrentValuePublisher(),
                                                         appSettings: appSettings,
                                                         analyticsService: analytics,
                                                         notificationManager: notificationManager,
                                                         badgeCountService: badgeCountService,
                                                         userIndicatorController: ServiceLocator.shared.userIndicatorController)
        let coordinator = HomeScreenCoordinator(parameters: parameters)
        MXLog.info("HomeScreenCoordinator created successfully")
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .presentRoom(let roomID):
                    handleAppRoute(.room(roomID: roomID, via: []), animated: true)
                case .presentRoomDetails(let roomID):
                    handleAppRoute(.roomDetails(roomID: roomID), animated: true)
                case .presentReportRoom(let roomID):
                    stateMachine.processEvent(.presentReportRoomScreen(roomID: roomID))
                case .roomLeft(let roomID):
                    if case .roomList(roomListSelectedRoomID: let roomListSelectedRoomID) = stateMachine.state,
                       roomListSelectedRoomID == roomID {
                        clearRoute(animated: true)
                    }
                case .presentSettingsScreen:
                    settingsFlowCoordinator.handleAppRoute(.settings, animated: true)
                case .presentFeedbackScreen:
                    stateMachine.processEvent(.feedbackScreen)
                case .presentSecureBackupSettings:
                    settingsFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                case .presentRecoveryKeyScreen:
                    stateMachine.processEvent(.showRecoveryKeyScreen)
                case .presentEncryptionResetScreen:
                    stateMachine.processEvent(.startEncryptionResetFlow)
                case .presentStartChatScreen:
                    stateMachine.processEvent(.showStartChatScreen)
                case .presentGlobalSearch:
                    presentGlobalSearch()
                case .logoutWithoutConfirmation:
                    self.actionsSubject.send(.logout)
                case .logout:
                    Task { await self.runLogoutFlow() }
                case .presentDeclineAndBlock(let userID, let roomID):
                    stateMachine.processEvent(.presentDeclineAndBlockScreen(userID: userID, roomID: roomID))
                }
            }
            .store(in: &cancellables)
        
        MXLog.info("Setting HomeScreenCoordinator as root coordinator")
        sidebarNavigationStackCoordinator.setRootCoordinator(coordinator)
        
        MXLog.info("Setting navigationSplitCoordinator as root coordinator in navigationRootCoordinator")
        navigationRootCoordinator.setRootCoordinator(navigationSplitCoordinator)
        MXLog.info("Home screen setup completed successfully")
    }
    
    private func presentReportRoom(for roomID: String) async {
        guard let roomProxyType = await userSession.clientProxy.roomForIdentifier(roomID),
              case let .joined(roomProxy) = roomProxyType else {
            MXLog.error("Failed to get room proxy for room: \(roomID)")
            return
        }
        
        let navigationStackCoordinator = NavigationStackCoordinator()
        let coordinator = ReportRoomScreenCoordinator(parameters: .init(roomProxy: roomProxy,
                                                                        userIndicatorController: ServiceLocator.shared.userIndicatorController))
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss(let shouldLeaveRoom):
                if shouldLeaveRoom,
                   case .roomList(let roomListSelectedRoomID) = stateMachine.state,
                   roomListSelectedRoomID == roomID {
                    clearRoute(animated: true)
                }
                navigationSplitCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        navigationStackCoordinator.setRootCoordinator(coordinator)
        navigationSplitCoordinator.setSheetCoordinator(navigationStackCoordinator) { [weak self] in
            self?.stateMachine.processEvent(.dismissedReportRoomScreen)
        }
    }
    
    private func presentDeclineAndBlockScreen(userID: String, roomID: String) {
        let stackCoordinator = NavigationStackCoordinator()
        let coordinator = DeclineAndBlockScreenCoordinator(parameters: .init(userID: userID,
                                                                             roomID: roomID,
                                                                             clientProxy: userSession.clientProxy,
                                                                             userIndicatorController: ServiceLocator.shared.userIndicatorController))
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .dismiss:
                navigationSplitCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        
        stackCoordinator.setRootCoordinator(coordinator)
        navigationSplitCoordinator.setSheetCoordinator(stackCoordinator) { [weak self] in
            self?.stateMachine.processEvent(.dismissedDeclineAndBlockScreen)
        }
    }
    
    private func runLogoutFlow() async {
        let secureBackupController = userSession.clientProxy.secureBackupController
        
        guard case let .success(isLastDevice) = await userSession.clientProxy.isOnlyDeviceLeft() else {
            ServiceLocator.shared.userIndicatorController.alertInfo = .init(id: .init())
            return
        }
        
        guard isLastDevice else {
            logout()
            return
        }
        
        guard secureBackupController.recoveryState.value == .enabled else {
            ServiceLocator.shared.userIndicatorController.alertInfo = .init(id: .init(),
                                                                            title: L10n.screenSignoutRecoveryDisabledTitle,
                                                                            message: L10n.screenSignoutRecoveryDisabledSubtitle,
                                                                            primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                                self?.actionsSubject.send(.logout)
                                                                            }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                                                self?.settingsFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                                            })
            return
        }
        
        guard secureBackupController.keyBackupState.value == .enabled else {
            ServiceLocator.shared.userIndicatorController.alertInfo = .init(id: .init(),
                                                                            title: L10n.screenSignoutKeyBackupDisabledTitle,
                                                                            message: L10n.screenSignoutKeyBackupDisabledSubtitle,
                                                                            primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                                self?.actionsSubject.send(.logout)
                                                                            }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                                                self?.settingsFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                                            })
            return
        }
        
        presentSecureBackupLogoutConfirmationScreen()
    }
    
    private func logout() {
        ServiceLocator.shared.userIndicatorController.alertInfo = .init(id: .init(),
                                                                        title: L10n.screenSignoutConfirmationDialogTitle,
                                                                        message: L10n.screenSignoutConfirmationDialogContent,
                                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                            self?.actionsSubject.send(.logout)
                                                                        })
    }
    
    // MARK: Room Flow
    
    private func startRoomFlow(roomID: String,
                               via: [String],
                               entryPoint: RoomFlowCoordinatorEntryPoint,
                               animated: Bool) async {
        #if LIVEKIT_ENABLED
        let ongoingCallRoomIDPublisher = CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher()
        #else
        let ongoingCallRoomIDPublisher = elementCallService.ongoingCallRoomIDPublisher
        #endif
        
        let coordinator = await RoomFlowCoordinator(roomID: roomID,
                                                    userSession: userSession,
                                                    isChildFlow: false,
                                                    timelineControllerFactory: timelineControllerFactory,
                                                    navigationStackCoordinator: detailNavigationStackCoordinator,
                                                    emojiProvider: EmojiProvider(appSettings: appSettings),
                                                    ongoingCallRoomIDPublisher: ongoingCallRoomIDPublisher,
                                                    appMediator: appMediator,
                                                    appSettings: appSettings,
                                                    appHooks: appHooks,
                                                    analytics: analytics,
                                                    userIndicatorController: ServiceLocator.shared.userIndicatorController)
        
        coordinator.actions.sink { [weak self] (action: RoomFlowCoordinatorAction) in
            guard let self else { return }
            
            switch action {
            case .presentCallScreen(let roomProxy, let callType):
                // Here we assume that the app is running and the call state is already up to date
                presentCallScreen(roomProxy: roomProxy, callType: callType, notifyOtherParticipants: !roomProxy.infoPublisher.value.hasRoomCall)
            case .verifyUser(let userID):
                presentSessionVerificationScreen(flow: .userIntiator(userID: userID))
            case .finished:
                stateMachine.processEvent(.deselectRoom)
            }
        }
        .store(in: &cancellables)
        
        roomFlowCoordinator = coordinator
        
        if navigationSplitCoordinator.detailCoordinator !== detailNavigationStackCoordinator {
            navigationSplitCoordinator.setDetailCoordinator(detailNavigationStackCoordinator, animated: animated)
        }
        
        switch entryPoint {
        case .room:
            coordinator.handleAppRoute(AppRoute.room(roomID: roomID, via: via), animated: animated)
        case .eventID(let eventID):
            coordinator.handleAppRoute(AppRoute.event(eventID: eventID, roomID: roomID, via: via), animated: animated)
        case .roomDetails:
            coordinator.handleAppRoute(AppRoute.roomDetails(roomID: roomID), animated: animated)
        case .share(let payload):
            coordinator.handleAppRoute(AppRoute.share(payload), animated: animated)
        }
                
        Task {
            let _ = await userSession.clientProxy.trackRecentlyVisitedRoom(roomID)
            
            await notificationManager.removeDeliveredMessageNotifications(for: roomID)
        }
    }
    
    private func dismissRoomFlow(animated: Bool) {
        // THIS MUST BE CALLED *AFTER* THE FLOW HAS TIDIED UP THE STACK OR IT CAN CAUSE A CRASH.
        navigationSplitCoordinator.setDetailCoordinator(nil, animated: animated)
        roomFlowCoordinator = nil
    }
    
    // MARK: Start Chat
    
    private func presentStartChat(animated: Bool) {
        let startChatNavigationStackCoordinator = NavigationStackCoordinator()

        let userDiscoveryService = UserDiscoveryService(clientProxy: userSession.clientProxy)
        let parameters = StartChatScreenCoordinatorParameters(orientationManager: appMediator.windowManager,
                                                              userSession: userSession,
                                                              userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                              navigationStackCoordinator: startChatNavigationStackCoordinator,
                                                              userDiscoveryService: userDiscoveryService,
                                                              mediaUploadingPreprocessor: MediaUploadingPreprocessor(appSettings: appSettings))
        
        let coordinator = StartChatScreenCoordinator(parameters: parameters)
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .close:
                navigationSplitCoordinator.setSheetCoordinator(nil)
            case .openRoom(let roomID):
                navigationSplitCoordinator.setSheetCoordinator(nil)
                stateMachine.processEvent(.selectRoom(roomID: roomID, via: [], entryPoint: .room))
            case .openRoomDirectorySearch:
                navigationSplitCoordinator.setSheetCoordinator(nil)
                stateMachine.processEvent(.showRoomDirectorySearchScreen)
            }
        }
        .store(in: &cancellables)

        startChatNavigationStackCoordinator.setRootCoordinator(coordinator)

        navigationSplitCoordinator.setSheetCoordinator(startChatNavigationStackCoordinator, animated: animated) { [weak self] in
            self?.stateMachine.processEvent(.dismissedStartChatScreen)
        }
    }
        
    // MARK: Calls
    
    private func presentCallScreen(genericCallLink url: URL) {
        #if LIVEKIT_ENABLED
        // LiveKit doesn't support generic call links yet
        MXLog.warning("Generic call links not supported with LiveKit integration")
        #else
        presentCallScreen(configuration: .init(genericCallLink: url))
        #endif
    }
    
    private func presentCallScreen(roomID: String, notifyOtherParticipants: Bool) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            return
        }
        
        presentCallScreen(roomProxy: roomProxy, notifyOtherParticipants: notifyOtherParticipants)
    }
    
    private func presentCallScreen(roomProxy: JoinedRoomProxyProtocol, callType: CallType = .video, notifyOtherParticipants: Bool) {
        #if LIVEKIT_ENABLED
        presentLiveKitCallScreen(roomProxy: roomProxy, callType: callType)
        #else
        let colorScheme: ColorScheme = appMediator.windowManager.mainWindow.traitCollection.userInterfaceStyle == .light ? .light : .dark
        presentCallScreen(configuration: .init(roomProxy: roomProxy,
                                               clientProxy: userSession.clientProxy,
                                               clientID: InfoPlistReader.main.bundleIdentifier,
                                               elementCallBaseURL: appSettings.elementCallBaseURL,
                                               elementCallBaseURLOverride: appSettings.elementCallBaseURLOverride,
                                               colorScheme: colorScheme,
                                               notifyOtherParticipants: notifyOtherParticipants))
        #endif
    }
    
    #if LIVEKIT_ENABLED
    private func presentLiveKitCallScreen(roomProxy: JoinedRoomProxyProtocol, callType: CallType = .video) {
        MXLog.info("Presenting LiveKit call screen for room: \(roomProxy.id) with call type: \(callType)")
        
        let authService = LiveKitAuthService(clientProxy: userSession.clientProxy)
        let liveKitCallCoordinator = LiveKitCallCoordinator(roomId: roomProxy.id, authService: authService, clientProxy: userSession.clientProxy, callType: callType)
        
        liveKitCallCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .dismiss:
                    navigationSplitCoordinator.setOverlayCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationSplitCoordinator.setOverlayCoordinator(liveKitCallCoordinator, animated: true)
    }
    #endif
    
    #if !LIVEKIT_ENABLED
    private var callScreenPictureInPictureController: AVPictureInPictureController?
    private func presentCallScreen(configuration: ElementCallConfiguration) {
        guard elementCallService.ongoingCallRoomIDPublisher.value != configuration.callRoomID else {
            MXLog.info("Returning to existing call.")
            callScreenPictureInPictureController?.stopPictureInPicture()
            return
        }
        
        let callScreenCoordinator = CallScreenCoordinator(parameters: .init(elementCallService: elementCallService,
                                                                            configuration: configuration,
                                                                            allowPictureInPicture: true,
                                                                            appHooks: appHooks))
        
        callScreenCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .pictureInPictureIsAvailable(let controller):
                    callScreenPictureInPictureController = controller
                case .pictureInPictureStarted:
                    MXLog.info("Hiding call for PiP presentation.")
                    navigationSplitCoordinator.setOverlayPresentationMode(.minimized)
                case .pictureInPictureStopped:
                    MXLog.info("Restoring call after PiP presentation.")
                    navigationSplitCoordinator.setOverlayPresentationMode(.fullScreen)
                case .dismiss:
                    callScreenPictureInPictureController = nil
                    navigationSplitCoordinator.setOverlayCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationSplitCoordinator.setOverlayCoordinator(callScreenCoordinator, animated: true)
        
        analytics.track(screen: .RoomCall)
    }
    
    private func hideCallScreenOverlay() {
        guard let callScreenPictureInPictureController else {
            MXLog.warning("Picture in picture isn't available, dismissing the call screen.")
            dismissCallScreenIfNeeded()
            return
        }
        
        MXLog.info("Starting picture in picture to hide the call screen overlay.")
        callScreenPictureInPictureController.startPictureInPicture()
        navigationSplitCoordinator.setOverlayPresentationMode(.minimized)
    }
    
    private func dismissCallScreenIfNeeded() {
        guard navigationSplitCoordinator.overlayCoordinator is CallScreenCoordinator else {
            return
        }
        
        navigationSplitCoordinator.setOverlayCoordinator(nil)
    }
    #endif
    
    // MARK: Secure backup
    
    private func presentRecoveryKeyScreen(animated: Bool) {
        let sheetNavigationStackCoordinator = NavigationStackCoordinator()
        let parameters = SecureBackupRecoveryKeyScreenCoordinatorParameters(secureBackupController: userSession.clientProxy.secureBackupController,
                                                                            userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                            isModallyPresented: true,
                                                                            clientProxy: userSession.clientProxy,
                                                                            forceMode: nil)
        
        let coordinator = SecureBackupRecoveryKeyScreenCoordinator(parameters: parameters)
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .complete:
                navigationSplitCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        
        sheetNavigationStackCoordinator.setRootCoordinator(coordinator)
        
        navigationSplitCoordinator.setSheetCoordinator(sheetNavigationStackCoordinator, animated: animated) { [weak self] in
            self?.stateMachine.processEvent(.dismissedRecoveryKeyScreen)
        }
    }
    
    private func startEncryptionResetFlow(animated: Bool) {
        let sheetNavigationStackCoordinator = NavigationStackCoordinator()
        let parameters = EncryptionResetFlowCoordinatorParameters(userSession: userSession,
                                                                  userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                  navigationStackCoordinator: sheetNavigationStackCoordinator,
                                                                  windowManger: appMediator.windowManager)
        
        let coordinator = EncryptionResetFlowCoordinator(parameters: parameters)
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .resetComplete:
                encryptionResetFlowCoordinator = nil
                navigationSplitCoordinator.setSheetCoordinator(nil)
            case .cancel:
                encryptionResetFlowCoordinator = nil
                navigationSplitCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        
        coordinator.start()
        encryptionResetFlowCoordinator = coordinator
        
        navigationSplitCoordinator.setSheetCoordinator(sheetNavigationStackCoordinator, animated: animated) { [weak self] in
            self?.stateMachine.processEvent(.finishedEncryptionResetFlow)
        }
    }
    
    private func presentSecureBackupLogoutConfirmationScreen() {
        let coordinator = SecureBackupLogoutConfirmationScreenCoordinator(parameters: .init(secureBackupController: userSession.clientProxy.secureBackupController,
                                                                                            appMediator: appMediator))
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .cancel:
                    navigationSplitCoordinator.setSheetCoordinator(nil)
                case .settings:
                    settingsFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                case .logout:
                    actionsSubject.send(.logout)
                }
            }
            .store(in: &cancellables)
        
        navigationSplitCoordinator.setSheetCoordinator(coordinator, animated: true)
    }
    
    // MARK: Global search
    
    private func presentGlobalSearch() {
        let roomSummaryProvider = userSession.clientProxy.alternateRoomSummaryProvider
        
        let coordinator = GlobalSearchScreenCoordinator(parameters: .init(roomSummaryProvider: roomSummaryProvider,
                                                                          mediaProvider: userSession.mediaProvider))
        
        globalSearchScreenCoordinator = coordinator
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .dismiss:
                    dismissGlobalSearch()
                case .select(let roomID):
                    dismissGlobalSearch()
                    handleAppRoute(.room(roomID: roomID, via: []), animated: true)
                }
            }
            .store(in: &cancellables)
        
        let hostingController = UIHostingController(rootView: coordinator.toPresentable())
        hostingController.view.backgroundColor = .clear
        appMediator.windowManager.globalSearchWindow.rootViewController = hostingController

        appMediator.windowManager.showGlobalSearch()
    }
    
    private func dismissGlobalSearch() {
        appMediator.windowManager.globalSearchWindow.rootViewController = nil
        appMediator.windowManager.hideGlobalSearch()
        
        globalSearchScreenCoordinator = nil
    }
    
    // MARK: Room Directory Search
    
    private func presentRoomDirectorySearch() {
        let coordinator = RoomDirectorySearchScreenCoordinator(parameters: .init(clientProxy: userSession.clientProxy,
                                                                                 mediaProvider: userSession.mediaProvider,
                                                                                 userIndicatorController: ServiceLocator.shared.userIndicatorController))
        
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .selectAlias(let alias):
                stateMachine.processEvent(.dismissedRoomDirectorySearchScreen)
                handleAppRoute(.roomAlias(alias), animated: true)
            case .selectRoomID(let roomID):
                stateMachine.processEvent(.dismissedRoomDirectorySearchScreen)
                handleAppRoute(.room(roomID: roomID, via: []), animated: true)
            case .dismiss:
                stateMachine.processEvent(.dismissedRoomDirectorySearchScreen)
            }
        }
        .store(in: &cancellables)
        
        navigationSplitCoordinator.setFullScreenCoverCoordinator(coordinator)
    }
    
    private func dismissRoomDirectorySearch() {
        navigationSplitCoordinator.setFullScreenCoverCoordinator(nil)
    }
    
    // MARK: User Profile
    
    private func presentUserProfileScreen(userID: String, animated: Bool) {
        clearRoute(animated: animated)
        
        let navigationStackCoordinator = NavigationStackCoordinator()
        let parameters = UserProfileScreenCoordinatorParameters(userID: userID,
                                                                isPresentedModally: true,
                                                                clientProxy: userSession.clientProxy,
                                                                mediaProvider: userSession.mediaProvider,
                                                                userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                analytics: analytics)
        let coordinator = UserProfileScreenCoordinator(parameters: parameters)
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .openDirectChat(let roomID):
                navigationSplitCoordinator.setSheetCoordinator(nil)
                stateMachine.processEvent(.selectRoom(roomID: roomID, via: [], entryPoint: .room))
            case .startCall(let roomID):
                Task { await self.presentCallScreen(roomID: roomID, notifyOtherParticipants: false) }
            case .dismiss:
                navigationSplitCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator, animated: false)
        navigationSplitCoordinator.setSheetCoordinator(navigationStackCoordinator, animated: animated) { [weak self] in
            self?.stateMachine.processEvent(.dismissedUserProfileScreen)
        }
    }
    
    // MARK: Sharing
    
    private func presentRoomSelectionScreen(sharePayload: ShareExtensionPayload, animated: Bool) {
        let roomSummaryProvider = userSession.clientProxy.alternateRoomSummaryProvider
        
        let stackCoordinator = NavigationStackCoordinator()
        
        let coordinator = RoomSelectionScreenCoordinator(parameters: .init(clientProxy: userSession.clientProxy,
                                                                           roomSummaryProvider: roomSummaryProvider,
                                                                           mediaProvider: userSession.mediaProvider))
        
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .dismiss:
                navigationSplitCoordinator.setSheetCoordinator(nil)
            case .confirm(let roomID):
                let sharePayload = switch sharePayload {
                case .mediaFile(_, let mediaFile):
                    ShareExtensionPayload.mediaFile(roomID: roomID, mediaFile: mediaFile)
                case .text(_, let text):
                    ShareExtensionPayload.text(roomID: roomID, text: text)
                }
                
                navigationSplitCoordinator.setSheetCoordinator(nil)
                
                stateMachine.processEvent(.selectRoom(roomID: roomID,
                                                      via: [],
                                                      entryPoint: .share(sharePayload)),
                                          userInfo: .init(animated: animated))
            }
        }
        .store(in: &cancellables)
        
        stackCoordinator.setRootCoordinator(coordinator)
        
        navigationSplitCoordinator.setSheetCoordinator(stackCoordinator, animated: animated) { [weak self] in
            self?.stateMachine.processEvent(.dismissedShareExtensionRoomList)
        }
    }
    
    private func dismissRoomSelectionScreen() {
        navigationSplitCoordinator.setSheetCoordinator(nil)
    }
    
    // MARK: Toasts and loading indicators
    
    private static let loadingIndicatorIdentifier = "\(UserSessionFlowCoordinator.self)-Loading"
    private static let failureIndicatorIdentifier = "\(UserSessionFlowCoordinator.self)-Failure"
    
    private func showLoadingIndicator(delay: Duration? = nil) {
        ServiceLocator.shared.userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                                                    type: .modal,
                                                                                    title: L10n.commonLoading,
                                                                                    persistent: true),
                                                                      delay: delay)
    }
    
    private func hideLoadingIndicator() {
        ServiceLocator.shared.userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
    
    private func showFailureIndicator() {
        ServiceLocator.shared.userIndicatorController.submitIndicator(UserIndicator(id: Self.failureIndicatorIdentifier,
                                                                                    type: .toast,
                                                                                    title: L10n.errorUnknown,
                                                                                    iconName: "xmark"))
    }
}
