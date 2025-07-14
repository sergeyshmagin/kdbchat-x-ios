# План интеграции LiveKit в ElementX iOS

## 📋 Обзор текущей архитектуры

### Текущая реализация звонков:
- **Web-based архитектура**: Element Call через WebView
- **Widget API**: Сложная система сообщений между JS и Swift
- **Внешняя зависимость**: Element Call web приложение
- **CallKit workarounds**: Хаки для работы с WebView

### Проблемы текущей реализации:
- ❌ Зависимость от внешнего Element Call сервера
- ❌ Сложная Widget API интеграция  
- ❌ WebView overhead и ограничения
- ❌ Трудности с CallKit интеграцией
- ❌ Ограниченная кастомизация UI

## 🎯 Цель миграции на LiveKit

### Преимущества LiveKit интеграции:
- ✅ **Нативная реализация**: Полностью нативные звонки на iOS
- ✅ **Производительность**: Отсутствие WebView overhead
- ✅ **Простота**: Прямая SDK интеграция без Widget API
- ✅ **Кастомизация**: Полный контроль над UI/UX
- ✅ **Надежность**: Устранение сетевых зависимостей

## 📦 LiveKit SDK Dependencies

### iOS Native SDK:
```swift
// Package.swift dependencies
.package(url: "https://github.com/livekit/client-sdk-ios", from: "2.0.0")
```

### Основные компоненты:
- **LiveKit**: Основной SDK для подключения
- **WebRTC**: Медиа обработка (включена в LiveKit)  
- **SwiftUI компоненты**: Готовые UI элементы

## 🏗 Архитектура новой реализации

### 1. Новые сервисы:

```swift
// Заменит ElementCallService
protocol LiveKitCallService {
    func startCall(roomId: String, participants: [String]) async throws
    func joinCall(roomId: String) async throws  
    func endCall() async throws
    var ongoingCall: LiveKitCall? { get }
}

// Управление LiveKit соединением
protocol LiveKitRoomManager {
    func connect(to room: String, with token: String) async throws
    func disconnect() async throws
    var participants: [Participant] { get }
    var localParticipant: LocalParticipant? { get }
}

// JWT токены для LiveKit
protocol LiveKitAuthService {
    func getAccessToken(for roomId: String, participantId: String) async throws -> String
}
```

### 2. Новые UI компоненты:

```swift
// Заменит CallScreen (WebView)
struct LiveKitCallScreen: View {
    @StateObject private var viewModel: LiveKitCallViewModel
    
    var body: some View {
        LiveKitCallView(room: viewModel.room)
            .toolbar { callControls }
            .onAppear { viewModel.startCall() }
    }
}

// Нативные контролы звонка
struct CallControls: View {
    @Binding var isMuted: Bool
    @Binding var isVideoEnabled: Bool
    
    var body: some View {
        HStack {
            muteButton
            videoButton
            hangupButton
        }
    }
}
```

## 🔄 Пошаговый план миграции

### Phase 1: Подготовка (1-2 дня)
1. **Добавить LiveKit SDK**:
   - Интегрировать `client-sdk-ios` через SPM
   - Обновить разрешения для медиа доступа
   - Создать базовую структуру классов

2. **Создать LiveKit сервисы**:
   ```swift
   // LiveKitCallService.swift
   final class LiveKitCallService: ObservableObject, LiveKitCallServiceProtocol {
       private let room = Room()
       @Published var ongoingCall: LiveKitCall?
       
       func startCall(roomId: String) async throws {
           let token = try await authService.getToken(for: roomId)
           try await room.connect(url: liveKitURL, token: token)
           ongoingCall = LiveKitCall(roomId: roomId, room: room)
       }
   }
   ```

### Phase 2: Базовая интеграция (2-3 дня)
1. **Заменить CallScreen**:
   - Создать `LiveKitCallScreen` с нативным UI
   - Интегрировать основные контролы (mute, video, hangup)
   - Добавить отображение участников

2. **JWT Auth интеграция**:
   ```swift
   // LiveKitAuthService.swift
   final class LiveKitAuthService: LiveKitAuthServiceProtocol {
       func getAccessToken(for roomId: String, participantId: String) async throws -> String {
           // Получение OpenID токена от Matrix
           let openIdToken = try await matrixClient.getOpenIdToken()
           
           // Запрос JWT токена с вашего auth сервиса
           let response = try await httpClient.post(
               url: "https://video.aibots.kz/api/auth",
               body: LiveKitAuthRequest(
                   roomId: roomId,
                   participantName: participantId,
                   openIdToken: openIdToken
               )
           )
           return response.accessToken
       }
   }
   ```

### Phase 3: CallKit интеграция (1-2 дня)
1. **Обновить CallKit integration**:
   ```swift
   // LiveKitCallKitService.swift  
   final class LiveKitCallKitService: NSObject, CXProviderDelegate {
       private let provider = CXProvider(configuration: callConfiguration)
       private let callController = CXCallController()
       
       func reportIncomingCall(roomId: String, callerName: String) {
           let update = CXCallUpdate()
           update.remoteHandle = CXHandle(type: .generic, value: roomId)
           update.localizedCallerName = callerName
           
           provider.reportNewIncomingCall(with: UUID(), update: update) { error in
               if let error = error {
                   // Handle error
               }
           }
       }
   }
   ```

### Phase 4: UI/UX полировка (2-3 дня)  
1. **Продвинутые UI компоненты**:
   - Grid view для участников
   - Screen sharing поддержка
   - Picture-in-Picture режим
   - Анимации и переходы

2. **Оптимизация производительности**:
   - Эффективный рендеринг видео
   - Управление памятью
   - Батарея optimization

### Phase 5: Интеграция и тестирование (2-3 дня)
1. **Полная замена старой системы**:
   - Удалить ElementCallService
   - Удалить ElementCallWidgetDriver  
   - Удалить Element Call WebView
   - Обновить Flow Coordinators

2. **Тестирование**:
   - Unit тесты для новых сервисов
   - Integration тесты звонков
   - UI тесты call flows
   - Performance тестирование

## 🔧 Технические детали

### Matrix RTC интеграция:
```swift
// Отправка Matrix call events
extension LiveKitCallService {
    private func sendCallMemberEvent(roomId: String, callId: String) async throws {
        let memberEvent = CallMemberEvent(
            callId: callId,
            deviceId: deviceId,
            expires: Date().addingTimeInterval(3600),
            fociPreferred: ["livekit"],
            foci: [
                LiveKitFocus(
                    type: "livekit", 
                    liveKitServiceURL: "https://video.aibots.kz"
                )
            ]
        )
        
        try await matrixClient.sendStateEvent(
            roomId: roomId,
            eventType: "org.matrix.msc3401.call.member",
            stateKey: "@\(userId)_\(deviceId)",
            content: memberEvent
        )
    }
}
```

### Error Handling:
```swift
enum LiveKitCallError: Error, LocalizedError {
    case connectionFailed
    case authenticationFailed  
    case roomNotFound
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to call"
        case .authenticationFailed:
            return "Authentication failed"
        case .roomNotFound:
            return "Call room not found"
        case .permissionDenied:
            return "Permission denied for audio/video"
        }
    }
}
```

## 📝 Файлы для изменения/удаления

### Удалить (старая система):
- `ElementCallService.swift`
- `ElementCallWidgetDriver.swift`  
- `CallScreen.swift` (WebView based)
- `ElementCallConfiguration.swift`
- `EmbeddedElementCall` dependency

### Создать (новая система):
- `LiveKitCallService.swift`
- `LiveKitAuthService.swift`
- `LiveKitCallKitService.swift`
- `LiveKitCallScreen.swift`
- `LiveKitCallViewModel.swift`

### Обновить:
- `UserSessionFlowCoordinator.swift` - новая call presentation логика
- `RoomFlowCoordinator.swift` - интеграция с LiveKit
- `AppSettings.swift` - LiveKit configuration
- `Info.plist` - обновить permissions если нужно

## 🎯 Ожидаемые результаты

### Улучшения производительности:
- 📈 **50%+ снижение memory usage** (удаление WebView)
- 📈 **Быстрее запуск звонков** (нет загрузки web app)
- 📈 **Лучшее качество звонков** (нативный WebRTC)

### Улучшения UX:
- ✨ **Нативный iOS look & feel**
- ✨ **Лучшая CallKit интеграция**
- ✨ **Кастомизируемый UI**
- ✨ **Надежность соединения**

### Упрощение архитектуры:
- 🔧 **Удаление 500+ строк Widget API кода**
- 🔧 **Прямая SDK интеграция**
- 🔧 **Меньше внешних зависимостей**
- 🔧 **Более понятная кодовая база**

## ⏱ Timeline

**Общая оценка: 10-12 дней разработки**

| Phase | Описание | Время |
|-------|----------|--------|
| 1 | Подготовка и SDK интеграция | 1-2 дня |
| 2 | Базовая функциональность | 2-3 дня |  
| 3 | CallKit интеграция | 1-2 дня |
| 4 | UI/UX полировка | 2-3 дня |
| 5 | Интеграция и тестирование | 2-3 дня |

**Рекомендация**: Начать с Phase 1-2 для создания MVP версии с базовой функциональностью звонков.