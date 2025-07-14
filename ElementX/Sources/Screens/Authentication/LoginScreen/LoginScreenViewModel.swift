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
        
        // Автоматически конфигурируем сервер при первом запуске
        if needsDefaultServer {
            MXLog.info("Default server set, configuring automatically: \(defaultHomeserver.address)")
            Task {
                await configureServer(address: defaultHomeserver.address)
            }
        }
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
    
    /// Configures a specific server address.
    private func configureServer(address: String) async {
        MXLog.info("Configuring server: \(address)")
        
        do {
            let result = try await withTimeout(seconds: 15) {
                await self.authenticationService.configure(for: address, flow: .login)
            }
            
            switch result {
            case .success:
                MXLog.info("Successfully configured server: \(address)")
            case .failure(let error):
                MXLog.error("Failed to configure server \(address): \(error)")
                // Не показываем ошибку пользователю при автоматической конфигурации
                // Ошибка будет показана при попытке логина
            }
        } catch {
            MXLog.error("Server configuration timed out for \(address): \(error)")
        }
    }
    
    /// Helper function to add timeout to async operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            
            group.cancelAll()
            return result
        }
    }
    
    private struct TimeoutError: Error { }
    
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
    /// Uses the same logic as ServerConfirmationScreen for proper authentication flow.
    private func login() {
        MXLog.info("Starting login with password using ServerConfirmation flow logic")
        
        // Сбрасываем authentication service перед новой попыткой логина
        // чтобы избежать ошибки "Client authentication data was already set"
        authenticationService.reset()
        MXLog.info("Authentication service reset before login attempt")
        
        startLoading(isInteractionBlocking: true)
        
        Task {
            // Step 1: Ensure server is properly configured using ServerConfirmation logic
            let configurationSuccess = await configureServerForLogin()
            guard configurationSuccess else {
                MXLog.error("Server configuration failed")
                stopLoading()
                analytics.signpost.endLogin()
                return
            }
            
            // Step 2: Check if OIDC is required (following ServerConfirmation flow)
            if authenticationService.homeserver.value.loginMode.supportsOIDCFlow {
                MXLog.info("Server requires OIDC authentication, but password login was attempted")
                stopLoading()
                analytics.signpost.endLogin()
                handleError(.loginNotSupported)
                return
            }
            
            // Step 3: Proceed with password authentication
            MXLog.info("Starting password authentication")
            analytics.signpost.beginLogin()
            
            let result = await self.authenticationService.login(username: self.state.bindings.username,
                                                                password: self.state.bindings.password,
                                                                initialDeviceName: UIDevice.current.initialDeviceName,
                                                                deviceID: nil)
            
            MXLog.info("Authentication service login completed")
            
            switch result {
            case .success(let userSession):
                MXLog.info("Login successful, sending signedIn action")
                actionsSubject.send(.signedIn(userSession))
                analytics.signpost.endLogin()
                stopLoading()
            case .failure(let error):
                MXLog.error("Login failed with error: \(error)")
                stopLoading()
                analytics.signpost.endLogin()
                handleError(error)
            }
        }
    }
    
    /// Configures the server for login using the same logic as ServerConfirmationScreen.confirmServer()
    private func configureServerForLogin() async -> Bool {
        let homeserver = authenticationService.homeserver.value
        
        // После reset() homeserver может иметь default address, нужно настроить на правильный сервер
        let targetServer = homeserver.address.isEmpty ||
            homeserver.address == "example.com" ||
            homeserver.address.hasPrefix("https://matrix.org") ?
            "matrix.aibots.kz" : homeserver.address
        
        // Always configure server after reset to ensure proper setup
        MXLog.info("Configuring server for login: \(targetServer)")
        
        switch await authenticationService.configure(for: targetServer, flow: .login) {
        case .success:
            MXLog.info("Server configuration successful")
            return true
        case .failure(let error):
            MXLog.error("Server configuration failed: \(error)")
            switch error {
            case .invalidServer, .invalidHomeserverAddress:
                handleError(.invalidHomeserverAddress)
            case .invalidWellKnown(let error):
                handleError(.invalidWellKnown(error))
            case .slidingSyncNotAvailable:
                handleError(.slidingSyncNotAvailable)
            case .loginNotSupported:
                handleError(.loginNotSupported)
            case .registrationNotSupported:
                handleError(.registrationNotSupported)
            default:
                handleError(.failedLoggingIn)
            }
            return false
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
        MXLog.error("Authentication error occurred: \(error)")
        MXLog.error("Error details: \(String(describing: error))")
        
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
            MXLog.error("Server does not support sliding sync - required for ElementX")
            state.bindings.alertInfo = AlertInfo(id: .slidingSyncAlert,
                                                 title: "Сервер не поддерживается",
                                                 message: "Сервер matrix.aibots.kz не поддерживает технологию sliding sync, которая требуется для работы ElementX. Используйте сервер с поддержкой sliding sync или другой Matrix-клиент.")
            
            // Clear out the invalid username to avoid an attempted login to matrix.org
            state.bindings.username = ""
        case .sessionTokenRefreshNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .refreshTokenAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenLoginErrorRefreshTokens)
        default:
            MXLog.error("Unhandled authentication error: \(error)")
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: L10n.commonError,
                                                 message: "Ошибка аутентификации: \(error)")
        }
    }
}
