//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import LiveKit
import SwiftUI

struct LiveKitCallScreen: View {
    @StateObject private var viewModel: LiveKitCallViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(roomId: String, authService: LiveKitAuthServiceProtocol) {
        _viewModel = StateObject(wrappedValue: LiveKitCallViewModel(roomId: roomId,
                                                                    callService: LiveKitCallService(authService: authService)))
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            if viewModel.isLoading {
                loadingView
            } else if viewModel.error != nil {
                errorView
            } else if viewModel.isConnected {
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
    
    // MARK: - Loading View

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Starting call...")
                .foregroundColor(.white)
                .font(.headline)
        }
    }
    
    // MARK: - Error View

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("Call Failed")
                .foregroundColor(.white)
                .font(.title2)
                .bold()
            
            if let error = viewModel.error {
                Text(error.localizedDescription)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            HStack(spacing: 20) {
                Button("Retry") {
                    Task { await viewModel.retryConnection() }
                }
                .buttonStyle(CallActionButtonStyle(backgroundColor: .blue))
                
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(CallActionButtonStyle(backgroundColor: .red))
            }
        }
        .padding()
    }
    
    // MARK: - Connecting View

    @ViewBuilder
    private var connectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Connecting...")
                .foregroundColor(.white)
                .font(.headline)
        }
    }
    
    // MARK: - Connected Call View

    @ViewBuilder
    private var connectedCallView: some View {
        VStack {
            // Status bar
            callStatusBar
                .padding(.top, 10)
            
            // Participants area
            participantsView
            
            Spacer()
            
            // Call controls
            callControlsView
                .padding(.bottom, 50)
        }
    }
    
    // MARK: - Call Status Bar

    @ViewBuilder
    private var callStatusBar: some View {
        VStack(spacing: 4) {
            Text(viewModel.connectionStatusText)
                .foregroundColor(.white)
                .font(.caption)
            
            Text("\(viewModel.participantCount) participant\(viewModel.participantCount == 1 ? "" : "s")")
                .foregroundColor(.white.opacity(0.7))
                .font(.caption2)
        }
        .padding(.horizontal)
    }
    
    // MARK: - Participants View

    @ViewBuilder
    private var participantsView: some View {
        if viewModel.participants.isEmpty {
            // Waiting for participants
            VStack(spacing: 20) {
                Image(systemName: "person.2")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.6))
                
                Text("Waiting for others to join...")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.headline)
                
                // Show local participant if available
                if let localParticipant = viewModel.localParticipant {
                    ParticipantView(participant: localParticipant, isLocal: true)
                        .frame(width: 200, height: 150)
                        .cornerRadius(12)
                }
            }
        } else {
            // Show participants grid
            LazyVGrid(columns: gridColumns, spacing: 8) {
                // Remote participants
                ForEach(viewModel.participants, id: \.sid) { participant in
                    ParticipantView(participant: participant, isLocal: false)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }
                
                // Local participant
                if let localParticipant = viewModel.localParticipant {
                    ParticipantView(participant: localParticipant, isLocal: true)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(12)
                        .overlay(
                            VStack {
                                HStack {
                                    Spacer()
                                    Text("You")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(4)
                                        .padding(8)
                                }
                                Spacer()
                            }
                        )
                }
            }
            .padding()
        }
    }
    
    private var gridColumns: [GridItem] {
        let totalParticipants = viewModel.participantCount
        let columns = totalParticipants <= 2 ? 1 : 2
        return Array(repeating: GridItem(.flexible()), count: columns)
    }
    
    // MARK: - Call Controls

    @ViewBuilder
    private var callControlsView: some View {
        HStack(spacing: 30) {
            // Mute button
            Button {
                Task { await viewModel.toggleMicrophone() }
            } label: {
                Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundColor(viewModel.isMuted ? .red : .white)
                    .frame(width: 60, height: 60)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
            
            // Video button
            Button {
                Task { await viewModel.toggleCamera() }
            } label: {
                Image(systemName: viewModel.isVideoEnabled ? "video.fill" : "video.slash.fill")
                    .font(.title2)
                    .foregroundColor(viewModel.isVideoEnabled ? .white : .red)
                    .frame(width: 60, height: 60)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
            
            // Hang up button
            Button {
                Task {
                    await viewModel.endCall()
                    dismiss()
                }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.red)
                    .clipShape(Circle())
            }
        }
    }
}

// MARK: - Supporting Views

struct ParticipantView: View {
    let participant: Participant
    let isLocal: Bool
    
    var body: some View {
        ZStack {
            // Video view placeholder - will be replaced with actual video rendering
            Rectangle()
                .fill(Color.gray.opacity(0.5))
            
            // Participant info overlay
            VStack {
                Spacer()
                HStack {
                    Text(displayName)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    // Audio indicator
                    if !isAudioEnabled {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(8)
            }
        }
    }
    
    private var displayName: String {
        if isLocal {
            return "You"
        } else {
            return participant.name ?? "Unknown"
        }
    }
    
    private var isAudioEnabled: Bool {
        if isLocal {
            return (participant as? LocalParticipant)?.isMicrophoneEnabled() ?? false
        } else {
            return !(participant.audioTracks.isEmpty)
        }
    }
}

// MARK: - Button Styles

struct CallActionButtonStyle: ButtonStyle {
    let backgroundColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.headline)
            .padding()
            .background(backgroundColor)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    LiveKitCallScreen(roomId: "test-room",
                      authService: MockLiveKitAuthService())
}
