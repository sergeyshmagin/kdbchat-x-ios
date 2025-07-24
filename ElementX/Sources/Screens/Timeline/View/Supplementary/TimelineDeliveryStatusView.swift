//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct TimelineDeliveryStatusView: View {
    enum Status {
        case sending
        case sent
        case delivered
        case read
    }

    let deliveryStatus: Status

    private var icon: CompoundIcon {
        switch deliveryStatus {
        case .sending:
            return CompoundIcon(\.circle, size: .xSmall, relativeTo: .compound.bodyMD)
        case .sent:
            return CompoundIcon(\.check, size: .xSmall, relativeTo: .compound.bodyMD)
        case .delivered:
            return CompoundIcon(\.checkCircle, size: .xSmall, relativeTo: .compound.bodyMD)
        case .read:
            return CompoundIcon(\.checkCircle, size: .xSmall, relativeTo: .compound.bodyMD)
        }
    }
    
    private var iconColor: Color {
        switch deliveryStatus {
        case .sending:
            return .compound.iconSecondary
        case .sent:
            return .compound.iconSecondary
        case .delivered:
            return .compound.iconSecondary
        case .read:
            return .compound.iconPrimary // Blue for read
        }
    }
    
    var body: some View {
        icon
            .foregroundColor(iconColor)
            .accessibilityLabel(accessibilityLabel)
    }
    
    private var accessibilityLabel: String {
        switch deliveryStatus {
        case .sending:
            return L10n.commonSending
        case .sent:
            return L10n.commonSent
        case .delivered:
            return "Delivered"
        case .read:
            return "Read"
        }
    }
}

struct TimelineDeliveryStatusView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 8) {
            TimelineDeliveryStatusView(deliveryStatus: .sending)
            TimelineDeliveryStatusView(deliveryStatus: .sent)
            TimelineDeliveryStatusView(deliveryStatus: .delivered)
            TimelineDeliveryStatusView(deliveryStatus: .read)
        }
    }
}
