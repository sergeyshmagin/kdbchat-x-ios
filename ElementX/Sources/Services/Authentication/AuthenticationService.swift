//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

class AuthenticationService: AuthenticationServiceProtocol {
    private var client: ClientProtocol?
    private var sessionDirectories: SessionDirectories
    private let passphrase: String
    
    private let clientBuilderFactory: AuthenticationClientBuilderFactoryProtocol
    private let userSessionStore: UserSessionStoreProtocol
    private let appSettings: AppSettings
    private let appHooks: AppHooks
    
    private let homeserverSubject: CurrentValueSubject<LoginHomeserver, Never>
    var homeserver: CurrentValuePublisher<LoginHomeserver, Never> { homeserverSubject.asCurrentValuePublisher() }
    private(set) var flow: AuthenticationFlow
    
    init(userSessionStore: UserSessionStoreProtocol,
         encryptionKeyProvider: EncryptionKeyProviderProtocol,
         clientBuilderFactory: AuthenticationClientBuilderFactoryProtocol = AuthenticationClientBuilderFactory(),
         appSettings: AppSettings,
         appHooks: AppHooks) {
        sessionDirectories = .init()
        passphrase = encryptionKeyProvider.generateKey().base64EncodedString()
        self.clientBuilderFactory = clientBuilderFactory
        self.userSessionStore = userSessionStore
        self.appSettings = appSettings
        self.appHooks = appHooks
        
        // When updating these, don't forget to update the reset method too.
        homeserverSubject = .init(LoginHomeserver(address: appSettings.accountProviders[0], loginMode: .unknown))
        flow = .login
    }
    
    // MARK: - Public
    
    func configure(for homeserverAddress: String, flow: AuthenticationFlow) async -> Result<Void, AuthenticationServiceError> {
        MXLog.info("Starting server configuration for: \(homeserverAddress)")
        do {
            var homeserver = LoginHomeserver(address: homeserverAddress, loginMode: .unknown)
            
            MXLog.info("Creating client builder for: \(homeserverAddress)")
            let clientBuilder = makeClientBuilder()
            
            MXLog.info("Building client for: \(homeserverAddress)")
            let client = try await clientBuilder.build(homeserverAddress: homeserverAddress)
            
            MXLog.info("Getting homeserver login details for: \(homeserverAddress)")
            let loginDetails = await client.homeserverLoginDetails()
            
            MXLog.info("Sliding sync version: \(client.slidingSyncVersion())")
            MXLog.info("Supports OIDC login: \(loginDetails.supportsOidcLogin())")
            MXLog.info("Supports password login: \(loginDetails.supportsPasswordLogin())")
            
            if loginDetails.supportsOidcLogin() {
                MXLog.info("Setting login mode to OIDC")
                homeserver.loginMode = .oidc(supportsCreatePrompt: loginDetails.supportedOidcPrompts().contains(.create))
            } else if loginDetails.supportsPasswordLogin() {
                MXLog.info("Setting login mode to password")
                homeserver.loginMode = .password
            } else {
                MXLog.info("Setting login mode to unsupported")
                homeserver.loginMode = .unsupported
            }
            
            if flow == .login, homeserver.loginMode == .unsupported {
                MXLog.error("Login not supported for server: \(homeserverAddress)")
                return .failure(.loginNotSupported)
            }
            if flow == .register, !homeserver.loginMode.supportsOIDCFlow {
                MXLog.error("Registration not supported for server: \(homeserverAddress)")
                return .failure(.registrationNotSupported)
            }
            
            MXLog.info("Storing client and sending homeserver update")
            self.client = client
            self.flow = flow
            homeserverSubject.send(homeserver)
            MXLog.info("Server configuration completed successfully for: \(homeserverAddress)")
            return .success(())
        } catch ClientBuildError.WellKnownDeserializationError(let error) {
            MXLog.error("The user entered a server with an invalid well-known file: \(error)")
            return .failure(.invalidWellKnown(error))
        } catch ClientBuildError.SlidingSyncVersion(let error) {
            MXLog.error("Server \(homeserverAddress) doesn't support sliding sync (required for ElementX): \(error)")
            return .failure(.slidingSyncNotAvailable)
        } catch {
            MXLog.error("Failed configuring a server: \(error)")
            return .failure(.invalidHomeserverAddress)
        }
    }
    
    func urlForOIDCLogin(loginHint: String?) async -> Result<OIDCAuthorizationDataProxy, AuthenticationServiceError> {
        guard let client else { return .failure(.oidcError(.urlFailure)) }
        do {
            // The create prompt is broken: https://github.com/element-hq/matrix-authentication-service/issues/3429
            // let prompt: OidcPrompt = flow == .register ? .create : .consent
            let oidcData = try await client.urlForOidc(oidcConfiguration: appSettings.oidcConfiguration.rustValue,
                                                       prompt: .consent,
                                                       loginHint: loginHint)
            return .success(OIDCAuthorizationDataProxy(underlyingData: oidcData))
        } catch {
            MXLog.error("Failed to get URL for OIDC login: \(error)")
            return .failure(.oidcError(.urlFailure))
        }
    }
    
    func abortOIDCLogin(data: OIDCAuthorizationDataProxy) async {
        guard let client else { return }
        MXLog.info("Aborting OIDC login.")
        await client.abortOidcAuth(authorizationData: data.underlyingData)
    }
    
    func loginWithOIDCCallback(_ callbackURL: URL) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        guard let client else { return .failure(.failedLoggingIn) }
        do {
            try await client.loginWithOidcCallback(callbackUrl: callbackURL.absoluteString)
            return await userSession(for: client)
        } catch OidcError.Cancelled {
            return .failure(.oidcError(.userCancellation))
        } catch {
            MXLog.error("Login with OIDC failed: \(error)")
            return .failure(.failedLoggingIn)
        }
    }
    
    func login(username: String, password: String, initialDeviceName: String?, deviceID: String?) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        guard let client else {
            MXLog.error("Login failed: client is nil")
            return .failure(.failedLoggingIn)
        }
        
        MXLog.info("Starting login for username: \(username), server: \(client.homeserver())")
        
        do {
            MXLog.info("Calling client.login with username: \(username)")
            try await client.login(username: username, password: password, initialDeviceName: initialDeviceName, deviceId: deviceID)
            MXLog.info("client.login completed successfully")
            
            let refreshToken = try? client.session().refreshToken
            if refreshToken != nil {
                MXLog.warning("Refresh token found for a non oidc session, can't restore session, logging out")
                _ = try? await client.logout()
                return .failure(.sessionTokenRefreshNotSupported)
            }
            
            MXLog.info("Creating user session for client")
            let userSessionResult = await userSession(for: client)
            switch userSessionResult {
            case .success(let session):
                MXLog.info("User session created successfully for: \(session.clientProxy.userID)")
                return .success(session)
            case .failure(let error):
                MXLog.error("Failed to create user session: \(error)")
                return .failure(error)
            }
        } catch let ClientError.MatrixApi(errorKind, _, _, _) {
            MXLog.error("Failed logging in with Matrix API error kind: \(errorKind)")
            switch errorKind {
            case .forbidden:
                MXLog.error("Login failed: invalid credentials (forbidden)")
                return .failure(.invalidCredentials)
            case .userDeactivated:
                MXLog.error("Login failed: user account deactivated")
                return .failure(.accountDeactivated)
            default:
                MXLog.error("Login failed: unhandled Matrix API error kind: \(errorKind)")
                return .failure(.failedLoggingIn)
            }
        } catch {
            MXLog.error("Failed logging in with general error: \(error)")
            MXLog.error("Error type: \(type(of: error))")
            MXLog.error("Error description: \(String(describing: error))")
            if let localizedError = error as? LocalizedError {
                MXLog.error("Localized error description: \(localizedError.localizedDescription)")
                if let failureReason = localizedError.failureReason {
                    MXLog.error("Failure reason: \(failureReason)")
                }
                if let recoverySuggestion = localizedError.recoverySuggestion {
                    MXLog.error("Recovery suggestion: \(recoverySuggestion)")
                }
            }
            return .failure(.failedLoggingIn)
        }
    }
    
    func reset() {
        homeserverSubject.send(LoginHomeserver(address: appSettings.accountProviders[0], loginMode: .unknown))
        flow = .login
        client = nil
    }
    
    // MARK: - Private
    
    private func makeClientBuilder() -> AuthenticationClientBuilderProtocol {
        // Use a fresh session directory each time the user enters a different server
        // so that caches (e.g. server versions) are always fresh for the new server.
        rotateSessionDirectory()
        
        return clientBuilderFactory.makeBuilder(sessionDirectories: sessionDirectories,
                                                passphrase: passphrase,
                                                clientSessionDelegate: userSessionStore.clientSessionDelegate,
                                                appSettings: appSettings,
                                                appHooks: appHooks)
    }
    
    private func rotateSessionDirectory() {
        sessionDirectories.delete()
        sessionDirectories = .init()
    }
    
    private func userSession(for client: ClientProtocol) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        MXLog.info("Creating user session for client with homeserver: \(client.homeserver())")
        
        let result = await userSessionStore.userSession(for: client, sessionDirectories: sessionDirectories, passphrase: passphrase)
        switch result {
        case .success(let clientProxy):
            MXLog.info("Successfully created user session with user ID: \(clientProxy.clientProxy.userID)")
            return .success(clientProxy)
        case .failure(let error):
            MXLog.error("Failed to create user session: \(error)")
            MXLog.error("UserSessionStore error type: \(type(of: error))")
            MXLog.error("UserSessionStore error description: \(String(describing: error))")
            return .failure(.failedLoggingIn)
        }
    }
}

// MARK: - Mocks

extension AuthenticationService {
    static var mock: AuthenticationService {
        AuthenticationService(userSessionStore: UserSessionStoreMock(configuration: .init()),
                              encryptionKeyProvider: EncryptionKeyProvider(),
                              clientBuilderFactory: AuthenticationClientBuilderFactoryMock(configuration: .init()),
                              appSettings: ServiceLocator.shared.settings,
                              appHooks: AppHooks())
    }
}
