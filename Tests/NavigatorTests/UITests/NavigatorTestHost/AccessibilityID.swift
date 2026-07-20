//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import SwiftUI

enum AccessibilityID: String {
    case open
    case close
    case allMemoryDeallocated
    case isNavigatorReady
    case runStressTest
    case stressTestCompleted
    case readerViewport
    case testActions
    case navigationActions
    case captureActions
    case actionMarker
    case currentLocationMarker
    case locationRevisionMarker
    case firstVisibleMarker
    case metricsMarker
    case viewportMetricsMarker
    case titleMarker
    case modeMarker
    case transitionMarker
    case selectionMarker
    case decorationMarker
    case applyTypography
    case shrinkTypography
    case toggleLayoutMode
    case toggleLayoutModeWithFailedNeighbor
    case rapidlyToggleLayoutMode
    case toggleLayoutModeWithFailedCurrent
    case jumpMissingResource
    case jumpFirstResourceEnd
    case jumpFragment
    case jumpText
    case jumpTableOfContents
    case jumpProgression10
    case jumpProgression80
    case jumpReflowMarker
    case captureCurrentLocation
    case captureFirstVisible
    case captureMetrics
    case captureViewportMetrics
    case captureTitle
    case captureSelection
}

extension View {
    func accessibilityIdentifier(_ id: AccessibilityID) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        accessibilityIdentifier(id.rawValue)
    }
}
