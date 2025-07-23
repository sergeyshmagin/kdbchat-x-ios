//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import LiveKit
import SwiftUI
import Combine

struct LiveKitCallScreen: View {
    @StateObject private var viewModel: LiveKitCallViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.presentationMode) private var presentationMode
    @State private var callTimer: Timer?
    @State private var callDuration: TimeInterval = 0
    @State private var showMoreOptions = false
    
    init(roomId: String, authService: LiveKitAuthServiceProtocol) {
        _viewModel = StateObject(wrappedValue: LiveKitCallViewModel(roomId: roomId,
                                                                    callService: LiveKitCallService(authService: authService)))
    }
    
    var body: some View {
        ZStack {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.error != nil {
                errorView
            } else if viewModel.isConnected {
                mainCallView
            } else {
                connectingView
            }
        }
        .onAppear {
            Task { await viewModel.startCall() }
            startCallTimer()
        }
        .onDisappear {
            Task { await viewModel.endCall() }
            stopCallTimer()
        }
    }
    
    private func startCallTimer() {
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            callDuration += 1
        }
    }
    
    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
    }
    
    // MARK: - Main Call View

    @ViewBuilder
    private var mainCallView: some View {
        ZStack {
            // Background based on video state
            if hasActiveVideo {
                videoCallView
                    .ignoresSafeArea()
            } else {
                audioCallView
                    .ignoresSafeArea()
            }
            
            // Always show controls at bottom
            VStack {
                Spacer()
                GeometryReader { geometry in
                    callControlsView
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                }
                .frame(height: 140)
            }
            
            // More options sheet
            .sheet(isPresented: $showMoreOptions) {
                moreOptionsSheet
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
            }
        }
        .ignoresSafeArea()
    }
    
    private var hasActiveVideo: Bool {
        // Check if any participant has video enabled
        let remoteHasVideo = viewModel.participants.contains { participant in
            !participant.videoTracks.isEmpty
        }
        // Use viewModel.isVideoEnabled instead of isCameraEnabled() for consistency
        let localHasVideo = viewModel.isVideoEnabled
        return remoteHasVideo || localHasVideo
    }
    
    // MARK: - Audio Call View (With Black Background and Logo)
    
    @ViewBuilder
    private var audioCallView: some View {
        ZStack {
            // Black background with pattern (like screenshot 3)
            Color.black.ignoresSafeArea()
            
            // Background pattern texture (optional)
            // Image("call_background_pattern") // Add this texture asset if needed
            //     .resizable()
            //     .aspectRatio(contentMode: .fill)
            //     .opacity(0.1)
            //     .ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                // Show participant avatar with animated green ring
                if let remote = remoteParticipant {
                    participantAvatarWithGreenRing(participant: remote)
                        .frame(height: 220)
                } else {
                    // Default avatar if no participant yet
                    defaultAvatarWithGreenRing
                        .frame(height: 220)
                }
                
                // Participant name
                GeometryReader { geometry in
                    VStack(spacing: 10) {
                        Text(participantDisplayName)
                            .font(.system(size: min(geometry.size.width * 0.08, 28)))
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                        
                        // Call status
                        Text(callStatusText)
                            .font(.system(size: min(geometry.size.width * 0.04, 16)))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 80)
                
                Spacer()
                Spacer()
            }
        }
    }
    
    // MARK: - Participant Avatar with Green Ring
    
    @ViewBuilder
    private func participantAvatarWithGreenRing(participant: Participant) -> some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            
            // Adaptive sizing for avatar
            let avatarSize = min(screenWidth * 0.4, screenHeight * 0.25, 180)
            let ringSize = avatarSize + 20
            let fontSize = avatarSize * 0.3
            
            ZStack {
                // Green animated ring
                Circle()
                    .stroke(Color.green, lineWidth: max(3, avatarSize * 0.02))
                    .frame(width: ringSize, height: ringSize)
                    .scaleEffect(animationScale)
                    .opacity(animationOpacity)
                    .animation(
                        Animation.easeInOut(duration: 2.0)
                            .repeatForever(autoreverses: false),
                        value: animationScale
                    )
                
                // Avatar background circle
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: avatarSize, height: avatarSize)
                
                // Participant avatar or initials
                Group {
                    if let avatarURL = participant.metadata, !avatarURL.isEmpty {
                        // If participant has avatar URL, show avatar image
                        AsyncImage(url: URL(string: avatarURL)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Text(getParticipantInitials(participant))
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                    } else {
                        // Show initials if no avatar
                        Text(getParticipantInitials(participant))
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            animationScale = 1.2
            animationOpacity = 0.3
        }
    }
    
    @ViewBuilder
    private var defaultAvatarWithGreenRing: some View {
        ZStack {
            // Green animated ring
            Circle()
                .stroke(Color.green, lineWidth: 4)
                .frame(width: 180, height: 180)
                .scaleEffect(animationScale)
                .opacity(animationOpacity)
                .animation(
                    Animation.easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: false),
                    value: animationScale
                )
            
            // Default avatar background
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 160, height: 160)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.7))
                )
        }
        .onAppear {
            animationScale = 1.2
            animationOpacity = 0.3
        }
    }
    
    // MARK: - Logo with Animated Ring (Unused now, keeping for reference)
    
    @ViewBuilder
    private var logoWithAnimatedRing: some View {
        ZStack {
            // Outer golden/yellow glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.yellow.opacity(0.3),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 100,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .blur(radius: 20)
            
            // Green animated ring
            Circle()
                .stroke(Color.green, lineWidth: 3)
                .frame(width: 160, height: 160)
                .scaleEffect(animationScale)
                .opacity(animationOpacity)
                .animation(
                    Animation.easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: false),
                    value: animationScale
                )
            
            // Logo container
            ZStack {
                // Black square background
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black)
                    .frame(width: 120, height: 120)
                
                // Golden border
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 212/255, green: 175/255, blue: 55/255),
                                Color(red: 255/255, green: 215/255, blue: 0/255),
                                Color(red: 184/255, green: 134/255, blue: 11/255)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 120, height: 120)
                
                // Logo content
                VStack(spacing: 8) {
                    // Bird/Eagle icon
                    Image(systemName: "bird.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color(red: 212/255, green: 175/255, blue: 55/255))
                    
                    Text("UNO")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("ЛУЧШАЯ\nПТИЦЕРИЯ\nВ ГОРОДЕ")
                        .font(.system(size: 8))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Text("2024")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 212/255, green: 175/255, blue: 55/255))
                }
            }
        }
        .onAppear {
            animationScale = 1.2
            animationOpacity = 0.3
        }
    }
    
    @State private var animationScale: CGFloat = 1.0
    @State private var animationOpacity: Double = 1.0
    
    private var callStatusText: String {
        switch viewModel.callState {
        case .ringing:
            return "Звонок..."
        case .connecting:
            return "Соединение..."
        case .active:
            return formattedCallDuration
        case .noAnswer:
            return "Абонент не отвечает"
        case .declined:
            return "Звонок отклонен"
        case .timeout:
            return "Время ожидания истекло"
        case .ended:
            return "Звонок завершен"
        case .idle:
            if viewModel.isLoading {
                return "Подготовка..."
            } else {
                return "Ожидание..."
            }
        }
    }
    
    @ViewBuilder
    private func participantAvatarView(participant: Participant) -> some View {
        ZStack {
            // Green animated ring
            Circle()
                .stroke(Color.green, lineWidth: 4)
                .frame(width: 160, height: 160)
                .scaleEffect(participant.isSpeaking ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), 
                          value: participant.isSpeaking)
            
            // Avatar circle
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 150, height: 150)
                .overlay(
                    // Check if participant has video track for avatar
                    Group {
                        if let videoTrack = participant.videoTracks.first?.track as? VideoTrack {
                            LiveKitVideoView(track: videoTrack, isLocal: participant is LocalParticipant)
                                .clipShape(Circle())
                        } else {
                            // Initials or default avatar
                            Text(getParticipantInitials(participant))
                                .font(.largeTitle)
                                .fontWeight(.medium)
                                .foregroundColor(.black)
                        }
                    }
                )
        }
    }
    
    @ViewBuilder
    private var defaultAvatarView: some View {
        ZStack {
            Circle()
                .stroke(Color.green, lineWidth: 4)
                .frame(width: 160, height: 160)
            
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 150, height: 150)
                .overlay(
                    Text("??")
                        .font(.largeTitle)
                        .fontWeight(.medium)
                        .foregroundColor(.black)
                )
        }
    }
    
    // MARK: - Video Call View (Like Right Screenshot)
    
    @ViewBuilder
    private var videoCallView: some View {
        GeometryReader { geometry in
            ZStack {
                // Background video (remote participant gets priority for full screen)
                if let remoteParticipant = viewModel.participants.first,
                   let remoteVideoTrack = remoteParticipant.videoTracks.first?.track as? VideoTrack {
                    // Remote participant video on full screen
                    LiveKitVideoView(track: remoteVideoTrack, isLocal: false)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .ignoresSafeArea(.all)
                } else if let localParticipant = viewModel.localParticipant,
                          let localVideoTrack = localParticipant.videoTracks.first?.track as? VideoTrack {
                    // Only show local video full screen if no remote participant
                    LiveKitVideoView(track: localVideoTrack, isLocal: true)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .ignoresSafeArea(.all)
                }
                
                // Top overlay with participant name and duration
                VStack {
                    topVideoOverlay
                    Spacer()
                }
                
                // Picture-in-Picture: Local video when remote is on full screen
                if let localParticipant = viewModel.localParticipant,
                   let localVideoTrack = localParticipant.videoTracks.first?.track as? VideoTrack,
                   !viewModel.participants.isEmpty,
                   viewModel.participants.first?.videoTracks.first != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            localVideoPreview(track: localVideoTrack)
                                .padding(.trailing, geometry.size.width * 0.04)
                                .padding(.bottom, 140) // Space for controls
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var topVideoOverlay: some View {
        GeometryReader { geometry in
            let safeAreaTop = geometry.safeAreaInsets.top
            
            VStack(spacing: 8) {
                // Back button
                HStack {
                    Button {
                        Task {
                            await viewModel.endCall()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: min(geometry.size.width * 0.06, 24)))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, geometry.size.width * 0.05)
                .padding(.top, max(safeAreaTop, 10))
                
                // Participant name with camera flip button on the same line
                HStack {
                    // Invisible spacer button to balance the layout
                    Button {} label: {
                        Image(systemName: "camera.rotate.fill")
                            .font(.system(size: min(geometry.size.width * 0.056, 22.5))) // 25% smaller than before
                            .foregroundColor(.clear)
                            .frame(width: 45, height: 45) // 25% smaller than 60x60
                    }
                    .disabled(true)
                    .padding(.leading, geometry.size.width * 0.05)
                    
                    Spacer()
                    
                    VStack(spacing: 4) {
                        Text(participantDisplayName)
                            .font(.system(size: min(geometry.size.width * 0.06, 22)))
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .multilineTextAlignment(.center)
                        
                        // Call duration
                        Text(formattedCallDuration)
                            .font(.system(size: min(geometry.size.width * 0.04, 16)))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    }
                    
                    Spacer()
                    
                    // Camera flip button - 25% smaller than previous version
                    Button {
                        Task { 
                            await viewModel.flipCamera()
                        }
                    } label: {
                        Image(systemName: "camera.rotate.fill")
                            .font(.system(size: min(geometry.size.width * 0.056, 22.5))) // 25% smaller: 0.075 * 0.75 = 0.056
                            .foregroundColor(.white)
                            .frame(width: 45, height: 45) // 25% smaller: 60 * 0.75 = 45
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, geometry.size.width * 0.05)
                }
                
                Spacer()
            }
        }
    }
    
    @ViewBuilder
    private func localVideoPreview(track: VideoTrack) -> some View {
        GeometryReader { geometry in
            let previewWidth = min(geometry.size.width * 0.3, 120)
            let previewHeight = previewWidth * 1.33 // 4:3 aspect ratio
            
            LiveKitVideoView(track: track, isLocal: true)
                .frame(width: previewWidth, height: previewHeight)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        }
    }
    
    // MARK: - Call Controls (Matching Screenshot Layout)
    
    @ViewBuilder
    private var callControlsView: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            
            // Control panel should be medium size, ~13.5% of screen width per button
            let buttonSize = screenWidth * 0.135 // Increased by 50% from 0.09
            let spacing = screenWidth * 0.0375 // Increased by 50% from 0.025
            let horizontalPadding = screenWidth * 0.06 // Increased by 50% from 0.04
            let verticalPadding = buttonSize * 0.3 // Make panel height proportional to button size
            let cornerRadius = buttonSize * 0.5
            
            HStack(spacing: spacing) {
                // Three dots menu button
                Button {
                    showMoreOptions.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: buttonSize * 0.4))
                        .foregroundColor(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Color.gray.opacity(0.6))
                        .clipShape(Circle())
                }
                
                // Video toggle button
                Button {
                    Task { await viewModel.toggleCamera() }
                } label: {
                    Image(systemName: viewModel.isVideoEnabled ? "video.fill" : "video.slash.fill")
                        .font(.system(size: buttonSize * 0.4))
                        .foregroundColor(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Color.gray.opacity(0.6))
                        .clipShape(Circle())
                }
                .disabled(viewModel.isLoading)
                
                // Speaker/Audio button
                Button {
                    Task { await viewModel.toggleSpeaker() }
                } label: {
                    Image(systemName: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill")
                        .font(.system(size: buttonSize * 0.4))
                        .foregroundColor(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Color.gray.opacity(0.6))
                        .clipShape(Circle())
                }
                
                // Microphone button
                Button {
                    Task { await viewModel.toggleMicrophone() }
                } label: {
                    Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: buttonSize * 0.4))
                        .foregroundColor(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Color.gray.opacity(0.6))
                        .clipShape(Circle())
                }
                .disabled(viewModel.isLoading)
                
                // Hang up button (red)
                Button {
                    Task {
                        await viewModel.endCall()
                        await MainActor.run {
                            dismiss()
                            presentationMode.wrappedValue.dismiss()
                            NotificationCenter.default.post(
                                name: NSNotification.Name("ForceDismissLiveKitCall"),
                                object: nil
                            )
                        }
                    }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: buttonSize * 0.4))
                        .foregroundColor(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Color.red)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(0.75))
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.ultraThinMaterial)
                    )
            )
            .frame(maxWidth: .infinity)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(height: max(100, 130)) // Increased height for medium-sized buttons
    }
    
    // MARK: - More Options Sheet
    
    @ViewBuilder
    private var moreOptionsSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Security notice
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.green)
                    Text("Защищено сквозным шифрованием")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("✕") {
                        showMoreOptions = false
                    }
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                
                // Options list
                VStack(spacing: 0) {
                    // Raise hand option
                    Button {
                        // TODO: Implement raise hand functionality
                        showMoreOptions = false
                    } label: {
                        HStack(spacing: 15) {
                            Image(systemName: "hand.raised.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .frame(width: 30)
                            
                            Text("Поднять руку")
                                .font(.body)
                                .foregroundColor(.white)
                            
                            Spacer()
                        }
                        .padding()
                        .background(Color.gray.opacity(0.3))
                    }
                    
                    Divider()
                    
                    // Screen share option
                    Button {
                        // TODO: Implement screen sharing functionality
                        showMoreOptions = false
                    } label: {
                        HStack(spacing: 15) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.title3)
                                .foregroundColor(.white)
                                .frame(width: 30)
                            
                            Text("Демонстрация экрана")
                                .font(.body)
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Image(systemName: "square.and.arrow.up")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.3))
                    }
                    
                    Divider()
                    
                    // Send message option
                    Button {
                        // TODO: Implement send message functionality
                        showMoreOptions = false
                    } label: {
                        HStack(spacing: 15) {
                            Image(systemName: "message.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .frame(width: 30)
                            
                            Text("Отправить сообщение")
                                .font(.body)
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Image(systemName: "message")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.3))
                    }
                    
                    // Connection quality indicator
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(.green)
                        Text("Хорошее подключение")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding()
                }
                
                Spacer()
            }
            .background(Color.black)
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Helper Properties
    
    private var mainParticipant: Participant? {
        // Prioritize remote participants over local participant
        return viewModel.participants.first ?? viewModel.localParticipant
    }
    
    private var remoteParticipant: Participant? {
        return viewModel.participants.first
    }
    
    private var participantDisplayName: String {
        // Always prioritize showing remote participant name
        if let remote = remoteParticipant {
            return remote.name ?? "Unknown"
        }
        
        // If no remote participant and we have video active, show "You" (only for local video)
        if hasActiveVideo, viewModel.localParticipant != nil {
            return "You"
        }
        
        // For audio calls without remote participant, show waiting state
        return "Connecting..."
    }
    
    private var formattedCallDuration: String {
        let minutes = Int(callDuration) / 60
        let seconds = Int(callDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func getParticipantInitials(_ participant: Participant) -> String {
        let name = participant.name ?? "U"
        return getParticipantInitials(name: name)
    }
    
    private func getParticipantInitials(name: String) -> String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
    
    // MARK: - Loading View

    @ViewBuilder
    private var loadingView: some View {
        ZStack {
            Color.gray.opacity(0.1).ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.gray)
                
                Text("Starting call...")
                    .foregroundColor(.black)
                    .font(.headline)
            }
        }
    }
    
    // MARK: - Error View

    @ViewBuilder
    private var errorView: some View {
        ZStack {
            Color.gray.opacity(0.1).ignoresSafeArea()
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 60))
                    .foregroundColor(.red)
                
                Text("Call Failed")
                    .foregroundColor(.black)
                    .font(.title2)
                    .bold()
                
                if let error = viewModel.error {
                    Text(error.localizedDescription)
                        .foregroundColor(.gray)
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
    }
    
    // MARK: - Connecting View

    @ViewBuilder
    private var connectingView: some View {
        ZStack {
            Color.gray.opacity(0.1).ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.gray)
                
                Text("Connecting...")
                    .foregroundColor(.black)
                    .font(.headline)
            }
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
#endif