# LiveKit Phase 1: Быстрый старт реализации

## 🎯 Цель Phase 1
Создать MVP версию нативных звонков с базовой функциональностью за 2-3 дня.

## 📦 Шаг 1: Добавление LiveKit SDK (30 мин)

### Package.swift обновление:
```swift
// В ElementX/Package.swift добавить:
.package(url: "https://github.com/livekit/client-sdk-ios", from: "2.0.0")

// В targets dependencies:
.product(name: "LiveKit", package: "client-sdk-ios")
```

### Или через Xcode SPM:
1. File → Add Package Dependencies
2. URL: `https://github.com/livekit/client-sdk-ios`
3. Version: `2.0.0` или latest

## 🏗 Шаг 2: Базовые сервисы (3-4 часа)

### LiveKitCallService.swift
```swift
import LiveKit
import Combine
import Foundation

final class LiveKitCallService: ObservableObject {
    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var participants: [Participant] = []
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var error: LiveKitCallError?
    
    // MARK: - Private Properties
    private let room = Room()
    private let authService: LiveKitAuthService
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Configuration
    private let serverURL = "wss://video.aibots.kz"
    
    init(authService: LiveKitAuthService) {
        self.authService = authService
        setupRoomObservers()
    }
    
    // MARK: - Public Methods
    @MainActor
    func startCall(roomId: String) async throws {
        do {
            let token = try await authService.getAccessToken(roomId: roomId)
            try await room.connect(url: serverURL, token: token)
            isConnected = true
        } catch {
            self.error = .connectionFailed
            throw error
        }
    }
    
    @MainActor  
    func endCall() async {
        await room.disconnect()
        isConnected = false
        participants.removeAll()
    }
    
    func toggleMicrophone() async {
        guard let localParticipant = room.localParticipant else { return }
        let newState = !localParticipant.isMicrophoneEnabled()
        try? await localParticipant.setMicrophone(enabled: newState)
        await MainActor.run { isMuted = !newState }
    }
    
    func toggleCamera() async {
        guard let localParticipant = room.localParticipant else { return }
        let newState = !localParticipant.isCameraEnabled()
        try? await localParticipant.setCamera(enabled: newState)
        await MainActor.run { isVideoEnabled = newState }
    }
    
    // MARK: - Private Methods
    private func setupRoomObservers() {
        room.add(delegate: self)
    }
}

// MARK: - RoomDelegate
extension LiveKitCallService: RoomDelegate {
    func room(_ room: Room, didConnect isReconnect: Bool) {
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }
    
    func room(_ room: Room, didDisconnect error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.participants.removeAll()
        }
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {
        DispatchQueue.main.async {
            if !self.participants.contains(where: { $0.sid == participant.sid }) {
                self.participants.append(participant)
            }
        }
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track) {
        // Handle participant leaving
    }
}

enum LiveKitCallError: Error, LocalizedError {
    case connectionFailed
    case authenticationFailed
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to call"
        case .authenticationFailed:
            return "Authentication failed"
        case .permissionDenied:
            return "Permission denied for audio/video"
        }
    }
}
```

### LiveKitAuthService.swift
```swift
import Foundation

protocol LiveKitAuthServiceProtocol {
    func getAccessToken(roomId: String) async throws -> String
}

final class LiveKitAuthService: LiveKitAuthServiceProtocol {
    private let httpClient: HTTPClient
    private let matrixClient: MatrixClient
    
    // MARK: - Configuration
    private let authURL = "https://video.aibots.kz/api/auth"
    
    init(httpClient: HTTPClient, matrixClient: MatrixClient) {
        self.httpClient = httpClient
        self.matrixClient = matrixClient
    }
    
    func getAccessToken(roomId: String) async throws -> String {
        // 1. Получить OpenID токен от Matrix
        let openIdToken = try await getMatrixOpenIdToken()
        
        // 2. Обменять на LiveKit JWT
        let authRequest = LiveKitAuthRequest(
            roomId: roomId,
            participantName: matrixClient.userId ?? "unknown",
            openIdToken: openIdToken
        )
        
        let response: LiveKitAuthResponse = try await httpClient.post(
            url: authURL,
            body: authRequest
        )
        
        return response.accessToken
    }
    
    private func getMatrixOpenIdToken() async throws -> String {
        // Интеграция с существующим Matrix client
        return try await matrixClient.requestOpenIdToken().accessToken
    }
}

// MARK: - Data Models
struct LiveKitAuthRequest: Codable {
    let roomId: String
    let participantName: String
    let openIdToken: String
}

struct LiveKitAuthResponse: Codable {
    let accessToken: String
    let url: String?
}
```

## 🎨 Шаг 3: Базовый UI (2-3 часа)

### LiveKitCallScreen.swift
```swift
import SwiftUI
import LiveKit

struct LiveKitCallScreen: View {
    @StateObject private var viewModel: LiveKitCallViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(roomId: String, authService: LiveKitAuthService) {
        self._viewModel = StateObject(wrappedValue: LiveKitCallViewModel(
            roomId: roomId,
            callService: LiveKitCallService(authService: authService)
        ))
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            if viewModel.isConnected {
                connectedCallView
            } else {
                connectingView
            }
        }
        .onAppear {
            Task { await viewModel.startCall() }
        }
        .onDisappear {
            Task { await viewModel.endCall() }
        }
    }
    
    @ViewBuilder
    private var connectedCallView: some View {
        VStack {
            // Participants area
            participantsView
            
            Spacer()
            
            // Call controls
            callControlsView
                .padding(.bottom, 50)
        }
    }
    
    @ViewBuilder
    private var participantsView: some View {
        if viewModel.participants.isEmpty {
            // Waiting for participants
            VStack {
                Image(systemName: "person.2")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.6))
                Text("Waiting for others to join...")
                    .foregroundColor(.white.opacity(0.8))
            }
        } else {
            // Show participants
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(viewModel.participants, id: \.sid) { participant in
                    ParticipantView(participant: participant)
                        .aspectRatio(4/3, contentMode: .fit)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }
            }
            .padding()
        }
    }
    
    private var gridColumns: [GridItem] {
        let count = max(1, min(2, viewModel.participants.count))
        return Array(repeating: GridItem(.flexible()), count: count)
    }
    
    @ViewBuilder
    private var callControlsView: some View {
        HStack(spacing: 30) {
            // Mute button
            CallControlButton(
                systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: !viewModel.isMuted,
                action: { Task { await viewModel.toggleMicrophone() } }
            )
            
            // Video button
            CallControlButton(
                systemImage: viewModel.isVideoEnabled ? "video.fill" : "video.slash.fill",
                isActive: viewModel.isVideoEnabled,
                action: { Task { await viewModel.toggleCamera() } }
            )
            
            // Hang up button
            CallControlButton(
                systemImage: "phone.down.fill",
                backgroundColor: .red,
                action: {
                    Task {
                        await viewModel.endCall()
                        dismiss()
                    }
                }
            )
        }
    }
    
    @ViewBuilder
    private var connectingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Connecting...")
                .foregroundColor(.white)
                .padding(.top)
        }
    }
}

// MARK: - Supporting Views
struct CallControlButton: View {
    let systemImage: String
    var backgroundColor: Color = .white.opacity(0.2)
    var isActive: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundColor(isActive ? .white : .gray)
                .frame(width: 60, height: 60)
                .background(backgroundColor)
                .clipShape(Circle())
        }
    }
}

struct ParticipantView: View {
    let participant: Participant
    
    var body: some View {
        ZStack {
            // Video view placeholder
            Rectangle()
                .fill(Color.gray.opacity(0.5))
            
            // Participant name overlay
            VStack {
                Spacer()
                HStack {
                    Text(participant.name ?? participant.identity)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                    Spacer()
                }
                .padding(8)
            }
        }
    }
}
```

### LiveKitCallViewModel.swift
```swift
import Foundation
import Combine

@MainActor
final class LiveKitCallViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var participants: [Participant] = []
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var error: LiveKitCallError?
    
    // MARK: - Private Properties
    private let roomId: String
    private let callService: LiveKitCallService
    private var cancellables = Set<AnyCancellable>()
    
    init(roomId: String, callService: LiveKitCallService) {
        self.roomId = roomId
        self.callService = callService
        setupBindings()
    }
    
    // MARK: - Public Methods
    func startCall() async {
        do {
            try await callService.startCall(roomId: roomId)
        } catch {
            self.error = error as? LiveKitCallError ?? .connectionFailed
        }
    }
    
    func endCall() async {
        await callService.endCall()
    }
    
    func toggleMicrophone() async {
        await callService.toggleMicrophone()
    }
    
    func toggleCamera() async {
        await callService.toggleCamera()
    }
    
    // MARK: - Private Methods
    private func setupBindings() {
        callService.$isConnected
            .assign(to: &$isConnected)
            
        callService.$participants
            .assign(to: &$participants)
            
        callService.$isMuted
            .assign(to: &$isMuted)
            
        callService.$isVideoEnabled
            .assign(to: &$isVideoEnabled)
            
        callService.$error
            .assign(to: &$error)
    }
}
```

## 🔗 Шаг 4: Интеграция с существующим кодом (1-2 часа)

### Обновить UserSessionFlowCoordinator.swift
```swift
// Добавить в UserSessionFlowCoordinator.swift

private func presentLiveKitCallScreen(roomProxy: JoinedRoomProxyProtocol) {
    let authService = LiveKitAuthService(
        httpClient: userSession.httpClient,
        matrixClient: userSession.clientProxy
    )
    
    let callScreen = LiveKitCallScreen(
        roomId: roomProxy.id,
        authService: authService
    )
    
    navigationRootCoordinator.setFullScreenCover(callScreen) { [weak self] in
        // Cleanup when call screen dismisses
        self?.navigationRootCoordinator.setFullScreenCover(nil)
    }
}

// Обновить существующий метод presentCallScreen
private func presentCallScreen(roomProxy: JoinedRoomProxyProtocol) {
    #if LIVEKIT_ENABLED
    presentLiveKitCallScreen(roomProxy: roomProxy)
    #else
    // Existing Element Call implementation
    presentElementCallScreen(roomProxy: roomProxy)
    #endif
}
```

### Добавить compiler flag
```swift
// В Build Settings добавить:
// SWIFT_ACTIVE_COMPILATION_CONDITIONS = LIVEKIT_ENABLED DEBUG
```

## 🧪 Шаг 5: Базовое тестирование (1 час)

### Простой тест
```swift
import XCTest
@testable import ElementX

final class LiveKitCallServiceTests: XCTestCase {
    func testCallServiceInitialization() {
        let mockAuthService = MockLiveKitAuthService()
        let callService = LiveKitCallService(authService: mockAuthService)
        
        XCTAssertFalse(callService.isConnected)
        XCTAssertTrue(callService.participants.isEmpty)
    }
}

class MockLiveKitAuthService: LiveKitAuthServiceProtocol {
    func getAccessToken(roomId: String) async throws -> String {
        return "mock-token"
    }
}
```

## ✅ Результат Phase 1

После выполнения этих шагов у вас будет:

- ✅ **LiveKit SDK интегрирован** в проект
- ✅ **Базовые сервисы** для звонков созданы  
- ✅ **Простой UI** для звонков работает
- ✅ **Интеграция** с существующим кодом
- ✅ **Возможность переключения** между Element Call и LiveKit

## 🚀 Быстрый старт команды

```bash
# 1. Checkout branch
git checkout -b feature/livekit-integration

# 2. Добавить LiveKit SDK через Xcode SPM

# 3. Создать файлы в правильных директориях:
mkdir -p ElementX/Sources/Services/LiveKit
touch ElementX/Sources/Services/LiveKit/LiveKitCallService.swift
touch ElementX/Sources/Services/LiveKit/LiveKitAuthService.swift

mkdir -p ElementX/Sources/Screens/LiveKitCall  
touch ElementX/Sources/Screens/LiveKitCall/LiveKitCallScreen.swift
touch ElementX/Sources/Screens/LiveKitCall/LiveKitCallViewModel.swift

# 4. Скопировать код из этого плана

# 5. Добавить LIVEKIT_ENABLED flag в Build Settings

# 6. Build и test!
```

**Время выполнения: 6-8 часов** для создания полностью функционального MVP с базовыми звонками!