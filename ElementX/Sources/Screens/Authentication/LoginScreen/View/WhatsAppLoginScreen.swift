//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct WhatsAppLoginScreen: View {
    /// The focus state of the username text field.
    @FocusState private var isUsernameFocused: Bool
    /// The focus state of the password text field.
    @FocusState private var isPasswordFocused: Bool
    /// The focus state of the server text field.
    @FocusState private var isServerFocused: Bool

    @Bindable var context: LoginScreenViewModel.Context
    @State private var serverAddress: String = "https://matrix.aibots.kz"

    var body: some View {
        VStack(spacing: 0) {
            // Логотип и название
            VStack(spacing: 20) {
                Image("AppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                Text("KDB Messenger")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            .padding(.top, 60)
            .padding(.bottom, 20)
            
            // Приветствие
            Text("Добро пожаловать\nв корпоративный мессенджер\nбанка развития Казахстана!")
                .font(.title3)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
            
            // Поле для ввода сервера
            VStack(alignment: .leading, spacing: 8) {
                Text("Сервер")
                    .font(.headline)
                    .foregroundColor(.primary)
                TextField("https://matrix.aibots.kz", text: $serverAddress)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: serverAddress) { newValue in
                        context.send(viewAction: .updateHomeserverAddress(newValue))
                    }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            
            // Штатная форма авторизации
            LoginScreen(context: context)
            
            Spacer()
        }
        .onAppear {
            if serverAddress.isEmpty {
                serverAddress = "https://matrix.aibots.kz"
                context.send(viewAction: .updateHomeserverAddress(serverAddress))
            }
        }
        .background(Color(.systemBackground))
        .navigationBarHidden(true)
    }

    /// WhatsApp-style header with logo and title
    var whatsAppHeader: some View {
        VStack(spacing: 24) {
            // WhatsApp-style logo
            Image(systemName: "message.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.whatsAppGreen)
                .padding(.bottom, 8)

            // Title
            Text("KDB Messenger")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.whatsAppTextPrimary)
                .multilineTextAlignment(.center)

            // Subtitle
            Text("Sign in to your account")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.whatsAppTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    /// WhatsApp-style login form
    var whatsAppLoginForm: some View {
        VStack(spacing: 20) {
            // Поле сервера
            whatsAppTextField(
                text: $serverAddress,
                placeholder: "Сервер",
                icon: "server.rack",
                isFocused: $isServerFocused,
                contentType: .URL,
                submitLabel: .next
            ) {
                isUsernameFocused = true
            }
            .onChange(of: serverAddress) { _, newValue in
                // Обновляем адрес сервера в view model
                context.send(viewAction: .updateHomeserverAddress(newValue))
            }
            
            // Поле логина
            whatsAppTextField(
                text: $context.username,
                placeholder: "Имя пользователя или email",
                icon: "person.fill",
                isFocused: $isUsernameFocused,
                contentType: .username,
                submitLabel: .next
            ) {
                isPasswordFocused = true
            }
            // Поле пароля
            whatsAppTextField(
                text: $context.password,
                placeholder: "Пароль",
                icon: "lock.fill",
                isSecure: true,
                isFocused: $isPasswordFocused,
                contentType: .password,
                submitLabel: .done
            ) {
                submit()
            }
            // Кнопка входа
            Button(action: submit) {
                HStack {
                    Text("Войти")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    if context.viewState.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    context.viewState.canSubmit && !context.viewState.isLoading
                        ? Color.whatsAppGreen
                        : Color.whatsAppGreen.opacity(0.5)
                )
                .cornerRadius(8)
            }
            .disabled(!context.viewState.canSubmit || context.viewState.isLoading)
            .padding(.top, 8)
        }
    }

    /// WhatsApp-style text field
    func whatsAppTextField(
        text: Binding<String>,
        placeholder: String,
        icon: String,
        isSecure: Bool = false,
        isFocused: FocusState<Bool>.Binding,
        contentType: UITextContentType? = nil,
        submitLabel: SubmitLabel = .done,
        onSubmit: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.whatsAppTextSecondary)
                .frame(width: 20)

            if isSecure {
                SecureField(text: text) {
                    Text(placeholder)
                        .foregroundColor(.whatsAppTextSecondary)
                }
            } else {
                TextField(text: text) {
                    Text(placeholder)
                        .foregroundColor(.whatsAppTextSecondary)
                }
            }
        }
        .focused(isFocused)
        .textContentType(contentType)
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color.whatsAppTextFieldBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused.wrappedValue ? Color.whatsAppGreen : Color.clear, lineWidth: 2)
        )
    }

    /// WhatsApp-style footer
    var whatsAppFooter: some View {
        VStack(spacing: 16) {
            Text("Продолжая, вы соглашаетесь с ")
                .font(.system(size: 12))
                .foregroundColor(.whatsAppTextSecondary)
            + Text("Условиями использования")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.whatsAppGreen)
            + Text(" и ")
                .font(.system(size: 12))
                .foregroundColor(.whatsAppTextSecondary)
            + Text("Политикой конфиденциальности")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.whatsAppGreen)
            // Сервер
            Text("Сервер: \(serverAddress)")
                .font(.system(size: 12))
                .foregroundColor(.whatsAppTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Sends the `next` view action so long as valid credentials have been input.
    private func submit() {
        guard context.viewState.canSubmit else { return }
        context.send(viewAction: .next)
        isUsernameFocused = false
        isPasswordFocused = false
        isServerFocused = false
    }
}

// MARK: - WhatsApp Color Extensions

extension Color {
    static let whatsAppBackground = Color(red: 0.98, green: 0.98, blue: 0.98)
    static let whatsAppGreen = Color(red: 0.13, green: 0.69, blue: 0.29)
    static let whatsAppTextPrimary = Color(red: 0.13, green: 0.13, blue: 0.13)
    static let whatsAppTextSecondary = Color(red: 0.45, green: 0.45, blue: 0.45)
    static let whatsAppTextFieldBackground = Color.white
}

// MARK: - Previews

struct WhatsAppLoginScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let credentialsViewModel = makeViewModel(withCredentials: true)

    static var previews: some View {
        NavigationStack {
            WhatsAppLoginScreen(context: viewModel.context)
        }
        .previewDisplayName("Initial State")

        NavigationStack {
            WhatsAppLoginScreen(context: credentialsViewModel.context)
        }
        .previewDisplayName("Credentials Entered")
    }

    static func makeViewModel(homeserverAddress: String = "example.com", withCredentials: Bool = false) -> LoginScreenViewModel {
        let authenticationService = AuthenticationService.mock

        Task { await authenticationService.configure(for: homeserverAddress, flow: .login) }

        let viewModel = LoginScreenViewModel(authenticationService: authenticationService,
                                           loginHint: nil,
                                           userIndicatorController: UserIndicatorControllerMock(),
                                           analytics: ServiceLocator.shared.analytics)

        if withCredentials {
            viewModel.context.username = "alice"
            viewModel.context.password = "password"
        }

        return viewModel
    }
} 