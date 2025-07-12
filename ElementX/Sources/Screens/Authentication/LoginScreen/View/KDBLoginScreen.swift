import SwiftUI

struct KDBLoginScreen: View {
    @Bindable var context: LoginScreenViewModel.Context
    @State private var isShowingForgotPasswordAlert = false
    @FocusState private var isUsernameFocused: Bool
    @FocusState private var isPasswordFocused: Bool
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Логотип и заголовок
                VStack(spacing: 24) {
                    Image(asset: Asset.Images.appLogo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .padding(.top, 48)
                    Text("Корпоративный мессенджер\nАО \"Банк Развития Казахстана\"")
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)
                }
                
                // Показать статус загрузки, если происходит конфигурация сервера
                if context.viewState.isLoading {
                    ProgressView("Настройка сервера...")
                        .padding(.bottom, 24)
                }
                
                // Форма логина
                switch context.viewState.loginMode {
                case .password:
                    loginForm
                case .oidc:
                    ProgressView("Подключение к серверу...")
                        .padding()
                case .unknown:
                    VStack {
                        ProgressView("Проверка сервера...")
                            .padding()
                        Text("Подключение к серверу matrix.aibots.kz")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Показываем кнопку смены сервера если проверка затянулась
                        if context.viewState.isLoading {
                            Button("Настроить сервер вручную") {
                                changeServer()
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                            .padding(.top, 8)
                        }
                    }
                default:
                    Text("Сервер не поддерживает вход с паролем")
                        .foregroundColor(.red)
                        .padding()
                }
                
                // Кнопка смены сервера
                Button("сменить сервер") {
                    changeServer()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.black)
                .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.white.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo)
        .alert("Обратитесь в службу поддержки вашей компании", isPresented: $isShowingForgotPasswordAlert) {
            Button("OK", role: .cancel) { }
        }
        .onAppear {
            // Автоматически конфигурируем сервер при появлении экрана только если сервер не настроен
            if context.viewState.homeserver.address.isEmpty ||
                context.viewState.homeserver.address == "example.com" ||
                context.viewState.homeserver.loginMode == .unknown {
                // Запускаем конфигурацию только один раз
                context.send(viewAction: .configureServer)
            }
        }
    }
    
    var loginForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Введите свои данные")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            
            TextField("Имя пользователя", text: $context.username)
                .focused($isUsernameFocused)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textContentType(.username)
                .submitLabel(.next)
                .onSubmit { isPasswordFocused = true }
                .onChange(of: isUsernameFocused) { _, newValue in
                    if !newValue, !context.username.isEmpty {
                        context.send(viewAction: .parseUsername)
                    }
                }
            
            SecureField("Пароль", text: $context.password)
                .focused($isPasswordFocused)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .submitLabel(.done)
                .onSubmit(submit)
            
            Button("Забыли пароль ?") {
                isShowingForgotPasswordAlert = true
            }
            .font(.system(size: 13))
            .foregroundColor(.gray)
            .padding(.top, 2)
            
            Button(action: submit) {
                HStack {
                    Text("Продолжить")
                    if context.viewState.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(context.viewState.canSubmit && !context.viewState.isLoading ? Color.blue : Color(.systemGray4))
                .foregroundColor(.white)
                .cornerRadius(24)
            }
            .disabled(!context.viewState.canSubmit || context.viewState.isLoading)
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
    
    private func submit() {
        guard context.viewState.canSubmit else { return }
        context.send(viewAction: .next)
        isUsernameFocused = false
        isPasswordFocused = false
    }
    
    private func changeServer() {
        context.send(viewAction: .changeServer)
    }
}
