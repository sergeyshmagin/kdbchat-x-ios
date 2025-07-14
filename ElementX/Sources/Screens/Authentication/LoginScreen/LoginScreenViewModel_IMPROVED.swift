//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ImprovedLoginScreenViewModelType = StateStoreViewModelV2<LoginScreenViewState, LoginScreenViewAction>

class ImprovedLoginScreenViewModel: ImprovedLoginScreenViewModelType, LoginScreenViewModelProtocol {
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
    
    /// Configures a specific server address with improved error handling.
    private func configureServer(address: String) async {
        MXLog.info("Configuring server: \(address)")
        
        do {
            // Увеличиваем таймаут до 30 секунд для медленных соединений
            let result = try await withTimeout(seconds: 30) {
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
    
    /// Helper function to add timeout to async operations with better error handling
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
    
    /// Configures the current homeserver automatically with improved error handling.
    private func configureCurrentServer() {
        let currentAddress = state.homeserver.address
        MXLog.info("Auto-configuring server: \(currentAddress)")
        
        startLoading(isInteractionBlocking: false)
        
        Task {
            // Добавляем таймаут в 30 секунд для конфигурации
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
                        try await Task.sleep(nanoseconds: 30_000_000_000) // 30 секунд
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
    
    /// Requests the authentication coordinator to log in using the specified credentials with improved error handling.
    private func login() {
        MXLog.info("Starting login with password.")
        startLoading(isInteractionBlocking: true)
        
        Task {
            do {
                // Проверяем, что сервер сконфигурирован
                if state.homeserver.loginMode == .unknown {
                    MXLog.info("Server not configured, configuring before login")
                    await configureServer(address: state.homeserver.address)
                    MXLog.info("Server configuration completed, homeserver mode: \(state.homeserver.loginMode)")
                }
                
                // Проверяем, что сервер поддерживает логин
                if state.homeserver.loginMode == .unsupported {
                    MXLog.error("Server does not support login")
                    stopLoading()
                    analytics.signpost.endLogin()
                    handleError(.loginNotSupported)
                    return
                }
                
                MXLog.info("Starting authentication service login")
                analytics.signpost.beginLogin()
                
                // Увеличиваем таймаут до 60 секунд для медленных соединений
                let result = try await withTimeout(seconds: 60) {
                    await self.authenticationService.login(username: self.state.bindings.username,
                                                           password: self.state.bindings.password,
                                                           initialDeviceName: UIDevice.current.initialDeviceName,
                                                           deviceID: nil)
                }
                
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
            } catch {
                MXLog.error("Login process timed out or failed: \(error)")
                stopLoading()
                analytics.signpost.endLogin()
                handleError(.failedLoggingIn)
            }
        }
    }
    
    private static let loadingIndicatorIdentifier = "\(LoginScreenCoordinatorAction.self)-Loading"
    
    private func startLoading(isInteractionBlocking: Bool) {
        if isInteractionBlocking {
            userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                                  type: .modal,
                                                                  title: "Подключение к серверу...", // Более информативное сообщение
                                                                  persistent: true))
        } else {
            state.isLoading = true
        }
    }
    
    /// Processes an error to either update the flow or display it to the user with improved error handling.
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
        case .invalidServer:
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: "Проблема с сервером",
                                                 message: "Не удалось подключиться к серверу. Проверьте адрес сервера и попробуйте снова.")
        case .invalidHomeserverAddress:
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: "Неверный адрес сервера",
                                                 message: "Указанный адрес сервера недействителен. Проверьте правильность адреса.")
        case .loginNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: "Вход не поддерживается",
                                                 message: "Данный сервер не поддерживает вход с паролем. Попробуйте другой сервер.")
        case .registrationNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: "Регистрация не поддерживается",
                                                 message: "Данный сервер не поддерживает регистрацию новых пользователей.")
        case .failedLoggingIn:
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: "Ошибка входа",
                                                 message: "Не удалось войти в систему. Проверьте подключение к интернету и попробуйте снова.")
        default:
            MXLog.error("Unhandled authentication error: \(error)")
            state.bindings.alertInfo = AlertInfo(id: .unknown,
                                                 title: L10n.commonError,
                                                 message: "Ошибка аутентификации: \(error)")
        }
    }
}
