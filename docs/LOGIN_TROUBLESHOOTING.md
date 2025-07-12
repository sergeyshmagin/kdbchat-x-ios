# Диагностика проблем с входом в ElementX

## Описание проблемы

Приложение ElementX долго зависает после нажатия кнопки "Продолжить" в окне ввода логина и пароля, а затем выдает ошибку.

## Анализ кода

### Потенциальные причины зависания

1. **Таймауты при конфигурации сервера**
   - В `LoginScreenViewModel.swift` есть таймаут в 15 секунд для конфигурации сервера
   - Если сервер не отвечает, приложение может зависать

2. **Проблемы с сетевым подключением**
   - Сервер `matrix.aibots.kz` может быть недоступен
   - Проблемы с DNS резолвингом
   - Блокировка файрволом

3. **Проблемы с аутентификацией**
   - Неправильная конфигурация OIDC
   - Проблемы с sliding sync
   - Неподдерживаемые методы аутентификации

### Критические участки кода

#### LoginScreenViewModel.swift
```swift
// Таймаут для конфигурации сервера
private func configureServer(address: String) async {
    do {
        let result = try await withTimeout(seconds: 15) {
            await self.authenticationService.configure(for: address, flow: .login)
        }
        // ...
    } catch {
        MXLog.error("Server configuration timed out for \(address): \(error)")
    }
}

// Таймаут для входа
private func login() {
    Task {
        let result = try await withTimeout(seconds: 30) {
            await self.authenticationService.login(username: self.state.bindings.username,
                                                  password: self.state.bindings.password,
                                                  initialDeviceName: UIDevice.current.initialDeviceName,
                                                  deviceID: nil)
        }
        // ...
    }
}
```

#### AuthenticationService.swift
```swift
func login(username: String, password: String, initialDeviceName: String?, deviceID: String?) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
    guard let client else { 
        MXLog.error("Login failed: client is nil")
        return .failure(.failedLoggingIn) 
    }
    
    do {
        try await client.login(username: username, password: password, initialDeviceName: initialDeviceName, deviceId: deviceID)
        // ...
    } catch {
        // Обработка ошибок
    }
}
```

## Диагностические скрипты

### 1. Анализ логов
```bash
./scripts/debug/analyze_login_logs.sh
```

### 2. Мониторинг в реальном времени
```bash
./scripts/debug/monitor_login_logs.sh
```

## Пошаговая диагностика

### Шаг 1: Проверка сервера
```bash
# Проверка доступности
curl -I https://matrix.aibots.kz/.well-known/matrix/client

# Проверка well-known
curl https://matrix.aibots.kz/.well-known/matrix/client

# Проверка версий API
curl https://matrix.aibots.kz/_matrix/client/versions
```

### Шаг 2: Включение подробного логирования
1. Откройте приложение ElementX
2. Перейдите в Settings → Developer Options
3. Установите Log Level в "Debug" или "Trace"
4. Включите нужные trace packs:
   - Event cache
   - Send queue
   - Timeline
   - Notification client

### Шаг 3: Запуск из Xcode
1. Откройте проект в Xcode
2. Запустите приложение в режиме отладки
3. Попробуйте войти в систему
4. Смотрите консоль Xcode на наличие ошибок

### Шаг 4: Анализ системных логов
```bash
# Логи за последний час
log show --predicate 'process == "ElementX"' --last 1h

# Поиск ошибок
log show --predicate 'process == "ElementX"' --last 1h | grep -E "(error|Error|ERROR|fail|Fail|FAIL|timeout|Timeout|TIMEOUT)"
```

## Возможные решения

### 1. Проблемы с сервером
- **Симптомы**: Таймауты при конфигурации сервера
- **Решение**: 
  - Проверить доступность сервера
  - Попробовать альтернативный сервер (matrix.org)
  - Проверить настройки сети

### 2. Проблемы с аутентификацией
- **Симптомы**: Ошибки "Invalid credentials" или "Login not supported"
- **Решение**:
  - Проверить правильность логина/пароля
  - Убедиться, что сервер поддерживает password login
  - Проверить настройки OIDC

### 3. Проблемы с sliding sync
- **Симптомы**: Ошибка "Sliding sync not available"
- **Решение**:
  - Сервер должен поддерживать sliding sync
  - Использовать сервер с поддержкой sliding sync

### 4. Сетевые проблемы
- **Симптомы**: Таймауты, ошибки подключения
- **Решение**:
  - Проверить интернет-соединение
  - Отключить VPN если используется
  - Проверить настройки файрвола

## Рекомендации по исправлению

### 1. Улучшение обработки ошибок
```swift
// Добавить более детальную обработку ошибок
private func handleError(_ error: AuthenticationServiceError) {
    switch error {
    case .invalidServer:
        // Показать пользователю возможность смены сервера
    case .slidingSyncNotAvailable:
        // Предложить альтернативный сервер
    case .timeout:
        // Показать сообщение о проблемах с сетью
    default:
        // Общая обработка ошибок
    }
}
```

### 2. Улучшение таймаутов
```swift
// Увеличить таймауты для медленных соединений
private func configureServer(address: String) async {
    do {
        let result = try await withTimeout(seconds: 30) { // Увеличить с 15 до 30
            await self.authenticationService.configure(for: address, flow: .login)
        }
    } catch {
        // Обработка таймаута
    }
}
```

### 3. Добавление индикаторов прогресса
```swift
// Показывать пользователю прогресс операций
private func startLoading(isInteractionBlocking: Bool) {
    if isInteractionBlocking {
        userIndicatorController.submitIndicator(UserIndicator(
            id: Self.loadingIndicatorIdentifier,
            type: .modal,
            title: "Подключение к серверу...", // Более информативное сообщение
            persistent: true
        ))
    }
}
```

## Контакты для поддержки

- **Сервер**: matrix.aibots.kz
- **Статус сервера**: https://matrix.aibots.kz/_matrix/client/versions
- **Документация**: https://github.com/element-hq/element-x

## Полезные команды

```bash
# Проверка DNS
nslookup matrix.aibots.kz

# Проверка HTTPS
curl -v https://matrix.aibots.kz/.well-known/matrix/client

# Мониторинг сетевых подключений
sudo tcpdump -i any host matrix.aibots.kz

# Анализ логов приложения
./scripts/debug/analyze_login_logs.sh
``` 