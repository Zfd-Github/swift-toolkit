//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

struct PublicationFixture: Equatable {
    enum AccessibilityOverride: String {
        case none
        case reduceMotion
        case voiceOver
    }

    let filename: String
    let description: String
    var hasFailedContinuousNeighbor = false
    var failsCurrentResourceOnLayoutSwitch = false
    var accessibilityOverride: AccessibilityOverride = .none

    var accessibilityIdentifier: String {
        let variant = if hasFailedContinuousNeighbor {
            "?failed-neighbor"
        } else if failsCurrentResourceOnLayoutSwitch {
            "?failed-current-on-layout-switch"
        } else {
            ""
        }
        let coverVariant = switch accessibilityOverride {
        case .none: variant
        case .reduceMotion: "?reduce-motion"
        case .voiceOver: "?voice-over"
        }
        return "publication://\(filename)\(coverVariant)"
    }

    var startsInContinuousScroll: Bool {
        self == .continuousScrollEPUB || self == .continuousScrollFailedNeighborEPUB
    }

    var enablesContinuousScrollActions: Bool {
        startsInContinuousScroll || failsCurrentResourceOnLayoutSwitch
    }

    var usesCoverPageTurn: Bool {
        filename.hasPrefix("page-turn-probe-")
    }

    static let childrensLiteratureEPUB: PublicationFixture = .init(
        filename: "childrens-literature.epub",
        description: "Basic reflowable EPUB with a page-list."
    )

    static let daisyPDF: PublicationFixture = .init(
        filename: "daisy.pdf",
        description: "Basic PDF document."
    )

    static let continuousScrollEPUB: PublicationFixture = .init(
        filename: "continuous-scroll.epub",
        description: "Fifty-resource reflowable EPUB for continuous scrolling."
    )

    static let continuousScrollFailedNeighborEPUB: PublicationFixture = .init(
        filename: "continuous-scroll.epub",
        description: "Continuous EPUB with a missing preloaded neighbor.",
        hasFailedContinuousNeighbor: true
    )

    static let continuousScrollFailedCurrentTransitionEPUB: PublicationFixture = .init(
        filename: "continuous-scroll.epub",
        description: "Paged EPUB whose current resource fails during a continuous-mode transition.",
        failsCurrentResourceOnLayoutSwitch: true
    )

    static let pageTurnProbeLTR: PublicationFixture = .init(
        filename: "page-turn-probe-ltr.epub",
        description: "Deterministic LTR snapshot probe."
    )

    static let pageTurnProbeRTL: PublicationFixture = .init(
        filename: "page-turn-probe-rtl.epub",
        description: "Deterministic RTL snapshot probe."
    )

    static let pageTurnProbeReduceMotion: PublicationFixture = .init(
        filename: "page-turn-probe-ltr.epub",
        description: "Cover probe with Reduce Motion enabled.",
        accessibilityOverride: .reduceMotion
    )

    static let pageTurnProbeVoiceOver: PublicationFixture = .init(
        filename: "page-turn-probe-ltr.epub",
        description: "Cover probe with VoiceOver enabled.",
        accessibilityOverride: .voiceOver
    )
}
