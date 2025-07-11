//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias LoginScreenViewModelType = StateStoreViewModelV2<LoginScreenViewState, LoginScreenViewAction>

class LoginScreenViewModel: LoginScreenViewModelType, LoginScreenViewModelProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let analytics: AnalyticsService
    
    private var actionsSubject: PassthroughSubject<LoginScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<LoginScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(authenticationService: AuthenticationServiceProtocol,
         loginHint: String?,
         userIndicatorController: UserIndicatorControllerProtocol,
         analytics: AnalyticsService) {
        self.authenticationService = authenticationService
        self.userIndicatorController = userIndicatorController
        self.analytics = analytics
        
        let username = switch loginHint {
        case .some(let hint) where hint.hasPrefix("mxid:"): String(hint.dropFirst(5)) // MSC4198
        case .some(let hint): hint
        case .none: ""
        }
        
        // Устанавливаем сервер по умолчанию, если он не задан или имеет неподходящий адрес
        let currentHomeserver = authenticationService.homeserver.value
        let needsDefaultServer = currentHomeserver.address.isEmpty || 
                                currentHomeserver.address == "example.com" ||
                                currentHomeserver.address.hasPrefix("https://matrix.org")
        
        let defaultHomeserver = LoginHomeserver(address: "matrix.aibots.kz", loginMode: .unknown)
        let homeserver = needsDefaultServer ? defaultHomeserver : currentHomeserver
        
        let viewState = LoginScreenViewState(homeserver: homeserver,
                                             bindings: LoginScreenBindings(username: username))
        
        super.init(initialViewState: viewState)
        
        authenticationService.homeserver
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.homeserver, on: self)
            .store(in: &cancellables)
    }

    override func process(viewAction: LoginScreenViewAction) {
        switch viewAction {
        case .parseUsername:
            parseUsername()
        case .next:
            login()
        case .updateHomeserverAddress(let address):
            updateHomeserverAddress(address)
        case .changeServer:
            actionsSubject.send(.changeServer)
        case .configureServer:
            configureCurrentServer()
        }
    }
    
    func stopLoading() {
        state.isLoading = false
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
    
    // MARK: - Private
    
    /// Parses the specified username and looks up the homeserver when a Matrix ID is entered.
    private func parseUsername() {
        let username = state.bindings.username
        
        guard MatrixEntityRegex.isMatrixUserIdentifier(username) else { return }
        
        let homeserverDomain = String(username.split(separator: ":")[1])
        
        startLoading(isInteractionBlocking: false)
        
        Task {
            switch await authenticationService.configure(for: homeserverDomain, flow: .login) {
            case .success:
                if authenticationService.homeserver.value.loginMode.supportsOIDCFlow {
                    actionsSubject.send(.configuredForOIDC)
                }
                stopLoading()
            case .failure(let error):
                stopLoading()
                handleError(error)
            }
        }
    }
    
    /// Updates the homeserver address and configures the authentication service.
    private func updateHomeserverAddress(_ address: String) {
        MXLog.info("Updating homeserver address to: \(address)")
        // Сброс username и password при смене сервера
        state.bindings.username = ""
        state.bindings.password = ""
        startLoading(isInteractionBlocking: false)
        
        Task {
            MXLog.info("Configuring authentication service for: \(address)")
            switch await authenticationService.configure(for: address, flow: .login) {
            case .success:
                MXLog.info("Successfully configured homeserver. Login mode: \(authenticationService.homeserver.value.loginMode)")
                if authenticationService.homeserver.value.loginMode.supportsOIDCFlow {
                    actionsSubject.send(.configuredForOIDC)
                }
                stopLoading()
            case .failure(let error):
                MXLog.error("Failed to configure homeserver: \(error)")
                stopLoading()
                handleError(error)
            }
        }
    }
    
    /// Configures the current homeserver automatically.
    private func configureCurrentServer() {
        let currentAddress = state.homeserver.address
        MXLog.info("Auto-configuring server: \(currentAddress)")
        
        startLoading(isInteractionBlocking: false)
        
        Task {
            // Добавляем таймаут в 10 секунд для конфигурации
            let result: Result<Void, AuthenticationServiceError>
            
            do {
                result = try await withThrowingTaskGroup(of: Result<Void, AuthenticationServiceError>.self) { group in
                    // Добавляем задачу конфигурации
                    group.addTask { [weak self] in
                        guard let self else { return .failure(AuthenticationServiceError.invalidServer) }
                        return await authenticationService.configure(for: currentAddress, flow: .login)
                    }
                    
                    // Добавляем задачу таймаута
                    group.addTask {
                        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 секунд
                        return .failure(AuthenticationServiceError.invalidServer)
                    }
                    
                    // Ждем первый результат
                    guard let first = try await group.next() else {
                        return .failure(AuthenticationServiceError.invalidServer)
                    }
                    
                    group.cancelAll()
                    return first
                }
            } catch {
                result = .failure(AuthenticationServiceError.invalidServer)
            }
            
            switch result {
            case .success:
                MXLog.info("Successfully auto-configured homeserver. Login mode: \(authenticationService.homeserver.value.loginMode)")
                if authenticationService.homeserver.value.loginMode.supportsOIDCFlow {
                    actionsSubject.send(.configuredForOIDC)
                }
                stopLoading()
            case .failure(let error):
                MXLog.error("Failed to auto-configure homeserver: \(error)")
                stopLoading()
                // При таймауте или ошибке показываем форму для ручного ввода
                if error == AuthenticationServiceError.invalidServer {
                    state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                         title: "Проблема с подключением",
                                                         message: "Не удалось подключиться к серверу автоматически. Нажмите 'сменить сервер' для ручной настройки.")
                } else {
                    handleError(error)
                }
            }
        }
    }
    
    /// Requests the authentication coordinator to log in using the specified credentials.
    private func login() {
        MXLog.info("Starting login with password.")
        startLoading(isInteractionBlocking: true)
        
        Task {
            analytics.signpost.beginLogin()
            switch await authenticationService.login(username: state.bindings.username,
                                                     password: state.bindings.password,
                                                     initialDeviceName: UIDevice.current.initialDeviceName,
                                                     deviceID: nil) {
            case .success(let userSession):
                actionsSubject.send(.signedIn(userSession))
                analytics.signpost.endLogin()
                stopLoading()
            case .failure(let error):
                stopLoading()
                analytics.signpost.endLogin()
                handleError(error)
            }
        }
    }
    
    private static let loadingIndicatorIdentifier = "\(LoginScreenCoordinatorAction.self)-Loading"
    
    private func startLoading(isInteractionBlocking: Bool) {
        if isInteractionBlocking {
            userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                                  type: .modal,
                                                                  title: L10n.commonLoading,
                                                                  persistent: true))
        } else {
            state.isLoading = true
        }
    }
    
    /// Processes an error to either update the flow or display it to the user.
    private func handleError(_ error: AuthenticationServiceError) {
        MXLog.info("Error occurred: \(error)")
        
        switch error {
        case .invalidCredentials:
            state.bindings.alertInfo = AlertInfo(id: .credentialsAlert,
                                                 title: L10n.commonError,
                                                 message: L10n.screenLoginErrorInvalidCredentials)
        case .accountDeactivated:
            state.bindings.alertInfo = AlertInfo(id: .deactivatedAlert,
                                                 title: L10n.commonError,
                                                 message: L10n.screenLoginErrorDeactivatedAccount)
        case .invalidWellKnown(let error):
            state.bindings.alertInfo = AlertInfo(id: .slidingSyncAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenChangeServerErrorInvalidWellKnown(error))
        case .slidingSyncNotAvailable:
            let nonBreakingAppName = InfoPlistReader.main.bundleDisplayName.replacingOccurrences(of: " ", with: "\u{00A0}")
            state.bindings.alertInfo = AlertInfo(id: .slidingSyncAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenChangeServerErrorNoSlidingSyncMessage(nonBreakingAppName))
            
            // Clear out the invalid username to avoid an attempted login to matrix.org
            state.bindings.username = ""
        case .sessionTokenRefreshNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .refreshTokenAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenLoginErrorRefreshTokens)
        default:
            state.bindings.alertInfo = AlertInfo(id: .unknown)
        }
    }
}
