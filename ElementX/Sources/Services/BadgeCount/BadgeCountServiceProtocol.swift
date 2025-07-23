//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

protocol BadgeCountServiceProtocol {
    func updateBadgeCount(to count: Int)
    func clearBadgeCount()
    func updateBadgeCountFromRoomSummaries(_ summaries: [RoomSummary])
}
