//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import LiveKit
import SwiftUI
import UIKit

/// A SwiftUI wrapper for LiveKit's VideoView to display video tracks
struct LiveKitVideoView: UIViewRepresentable {
    let track: VideoTrack?
    let isLocal: Bool
    
    func makeUIView(context: Context) -> VideoView {
        let videoView = VideoView()
        videoView.layoutMode = .fit
        videoView.isDebugMode = false
        videoView.backgroundColor = UIColor.clear
        
        return videoView
    }
    
    func updateUIView(_ uiView: VideoView, context: Context) {
        // Update the video track
        if let track = track {
            uiView.track = track
            
            // Only mirror front camera for local video
            if isLocal {
                let shouldMirror = shouldMirrorCamera(for: track)
                uiView.transform = shouldMirror ? CGAffineTransform(scaleX: -1, y: 1) : CGAffineTransform.identity
            }
        } else {
            uiView.track = nil
        }
    }
    
    private func shouldMirrorCamera(for track: VideoTrack) -> Bool {
        // Only mirror front camera
        guard let localTrack = track as? LocalVideoTrack,
              let cameraCapturer = localTrack.capturer as? CameraCapturer else {
            return false
        }
        
        // Check camera position - only mirror front camera
        return cameraCapturer.options.position == .front
    }
}

/// A more advanced video participant view with animations and better UX
struct EnhancedParticipantView: View {
    let participant: Participant
    let isLocal: Bool
    @State private var isExpanded = false
    
    var body: some View {
        ZStack {
            // Video content
            Group {
                if isVideoEnabled, let videoTrack = videoTrack {
                    LiveKitVideoView(track: videoTrack, isLocal: isLocal)
                        .clipped()
                        .cornerRadius(12)
                } else {
                    // Avatar placeholder with gradient background
                    avatarPlaceholder
                }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
            
            // Overlays
            participantOverlays
        }
        .scaleEffect(isExpanded ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
    }
    
    @ViewBuilder
    private var avatarPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(colors: [
                    Color.blue.opacity(0.6),
                    Color.purple.opacity(0.4)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            )
            .overlay(
                VStack(spacing: 12) {
                    // Animated avatar circle
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 60, height: 60)
                        
                        Text(initials)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .scaleEffect(isSpeaking ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.3).repeatCount(isSpeaking ? .max : 0), value: isSpeaking)
                    
                    Text(displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                        .fontWeight(.medium)
                }
            )
    }
    
    @ViewBuilder
    private var participantOverlays: some View {
        VStack {
            // Top overlay: Connection quality and screen share indicator
            HStack {
                Spacer()
                
                VStack(spacing: 4) {
                    // Connection quality indicator
                    if !isLocal {
                        connectionQualityIndicator
                    }
                    
                    // Screen share indicator
                    if hasScreenShare {
                        screenShareIndicator
                    }
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
            
            Spacer()
            
            // Bottom overlay: Name and audio status
            bottomOverlay
        }
    }
    
    @ViewBuilder
    private var connectionQualityIndicator: some View {
        if connectionQuality != nil {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Rectangle()
                        .fill(connectionQualityColor)
                        .frame(width: 3, height: 4 + CGFloat(index) * 2)
                        .opacity(index < connectionQualityBars ? 1.0 : 0.3)
                }
            }
            .padding(4)
            .background(Color.black.opacity(0.7))
            .cornerRadius(4)
        }
    }
    
    @ViewBuilder
    private var screenShareIndicator: some View {
        Image(systemName: "rectangle.on.rectangle.fill")
            .font(.caption)
            .foregroundColor(.green)
            .padding(4)
            .background(Color.black.opacity(0.7))
            .clipShape(Circle())
    }
    
    @ViewBuilder
    private var bottomOverlay: some View {
        HStack {
            // Name tag
            Text(displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
            
            Spacer()
            
            // Audio status
            audioStatusIndicator
        }
        .padding(8)
    }
    
    @ViewBuilder
    private var audioStatusIndicator: some View {
        Group {
            if !isAudioEnabled {
                Image(systemName: "mic.slash.fill")
                    .foregroundColor(.red)
            } else if isSpeaking {
                Image(systemName: "mic.fill")
                    .foregroundColor(.green)
                    .scaleEffect(1.2)
                    .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: isSpeaking)
            } else {
                Image(systemName: "mic.fill")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .font(.caption)
        .padding(4)
        .background(Color.black.opacity(0.7))
        .clipShape(Circle())
    }
    
    // MARK: - Computed Properties
    
    private var displayName: String {
        if isLocal {
            return "You"
        } else {
            return participant.name ?? String(describing: participant.identity)
        }
    }
    
    private var initials: String {
        let name = displayName
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
    
    private var isAudioEnabled: Bool {
        if isLocal {
            return (participant as? LocalParticipant)?.isMicrophoneEnabled() ?? false
        } else {
            return !participant.audioTracks.isEmpty
        }
    }
    
    private var isVideoEnabled: Bool {
        if isLocal {
            return (participant as? LocalParticipant)?.isCameraEnabled() ?? false
        } else {
            return !participant.videoTracks.isEmpty
        }
    }
    
    private var videoTrack: VideoTrack? {
        if isLocal {
            if let localParticipant = participant as? LocalParticipant {
                return localParticipant.videoTracks.first?.track as? VideoTrack
            }
        } else if let remoteParticipant = participant as? RemoteParticipant {
            return remoteParticipant.videoTracks.first?.track as? VideoTrack
        }
        return nil
    }
    
    private var isSpeaking: Bool {
        participant.isSpeaking
    }
    
    private var hasScreenShare: Bool {
        if let remoteParticipant = participant as? RemoteParticipant {
            return remoteParticipant.videoTracks.contains { track in
                track.source == .screenShareVideo
            }
        }
        return false
    }
    
    private var connectionQuality: ConnectionQuality? {
        (participant as? RemoteParticipant)?.connectionQuality
    }
    
    private var connectionQualityColor: Color {
        guard let quality = connectionQuality else { return .white }
        
        switch quality {
        case .poor, .lost: return .red
        case .good: return .yellow
        case .excellent: return .green
        case .unknown: return .gray
        @unknown default: return .gray
        }
    }
    
    private var connectionQualityBars: Int {
        guard let quality = connectionQuality else { return 3 }
        
        switch quality {
        case .poor: return 1
        case .good: return 2
        case .excellent: return 3
        case .lost, .unknown: return 0
        @unknown default: return 0
        }
    }
}
#endif
