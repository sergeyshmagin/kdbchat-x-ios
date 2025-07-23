//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

#if LIVEKIT_ENABLED
import SwiftUI

/// A modifier that provides Picture-in-Picture functionality for call screens
struct PictureInPictureModifier: ViewModifier {
    @Binding var isPiPActive: Bool
    @State private var dragOffset = CGSize.zero
    @State private var lastDragPosition = CGSize.zero
    
    private let pipSize = CGSize(width: 120, height: 160)
    private let cornerRadius: CGFloat = 12
    
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack {
                if isPiPActive {
                    // Dimmed background
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                isPiPActive = false
                                dragOffset = .zero
                                lastDragPosition = .zero
                            }
                        }
                    
                    // PiP window
                    content
                        .frame(width: pipSize.width, height: pipSize.height)
                        .cornerRadius(cornerRadius)
                        .shadow(radius: 10)
                        .offset(x: dragOffset.width, y: dragOffset.height)
                        .scaleEffect(isPiPActive ? 1.0 : 0.1)
                        .opacity(isPiPActive ? 1.0 : 0.0)
                        .position(x: pipPosition(in: geometry).x,
                                  y: pipPosition(in: geometry).y)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = CGSize(width: lastDragPosition.width + value.translation.width,
                                                        height: lastDragPosition.height + value.translation.height)
                                }
                                .onEnded { _ in
                                    // Snap to corner
                                    let newPosition = snapToCorner(offset: dragOffset,
                                                                   in: geometry)
                                    
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        dragOffset = newPosition
                                        lastDragPosition = newPosition
                                    }
                                }
                        )
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPiPActive)
                } else {
                    // Full screen
                    content
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
    
    private func pipPosition(in geometry: GeometryProxy) -> CGPoint {
        let safeArea = geometry.safeAreaInsets
        let bounds = geometry.frame(in: .local)
        
        // Default position: top-right corner
        let defaultX = bounds.maxX - pipSize.width / 2 - 20
        let defaultY = bounds.minY + safeArea.top + pipSize.height / 2 + 20
        
        // Apply drag offset
        let finalX = defaultX + dragOffset.width
        let finalY = defaultY + dragOffset.height
        
        return CGPoint(x: finalX, y: finalY)
    }
    
    private func snapToCorner(offset: CGSize, in geometry: GeometryProxy) -> CGSize {
        let safeArea = geometry.safeAreaInsets
        let bounds = geometry.frame(in: .local)
        
        let currentX = bounds.maxX - pipSize.width / 2 - 20 + offset.width
        let currentY = bounds.minY + safeArea.top + pipSize.height / 2 + 20 + offset.height
        
        // Define corner regions
        let leftEdge = bounds.minX + pipSize.width / 2 + 20
        let rightEdge = bounds.maxX - pipSize.width / 2 - 20
        let topEdge = bounds.minY + safeArea.top + pipSize.height / 2 + 20
        let bottomEdge = bounds.maxY - safeArea.bottom - pipSize.height / 2 - 100 // Leave space for controls
        
        // Determine which corner to snap to
        let snapToLeft = currentX < bounds.midX
        let snapToTop = currentY < bounds.midY
        
        let targetX = snapToLeft ? leftEdge : rightEdge
        let targetY = snapToTop ? topEdge : bottomEdge
        
        // Calculate offset needed to reach target position
        let defaultX = bounds.maxX - pipSize.width / 2 - 20
        let defaultY = bounds.minY + safeArea.top + pipSize.height / 2 + 20
        
        return CGSize(width: targetX - defaultX,
                      height: targetY - defaultY)
    }
}

extension View {
    func pictureInPicture(isActive: Binding<Bool>) -> some View {
        modifier(PictureInPictureModifier(isPiPActive: isActive))
    }
}
#endif
