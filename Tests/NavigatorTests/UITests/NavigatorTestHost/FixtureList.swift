//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// Provides a simple UI for opening publication fixtures and display memory
/// status for UI test verification.
struct FixtureList: View {
    @ObservedObject private var memoryTracker: MemoryTracker
    @StateObject private var viewModel = FixtureListViewModel()

    init() {
        memoryTracker = Container.shared.memoryTracker
    }

    var body: some View {
        List {
            Section {
                fixture(.childrensLiteratureEPUB)
                fixture(.continuousScrollEPUB)
                fixture(.continuousScrollFailedNeighborEPUB)
                fixture(.continuousScrollFailedCurrentTransitionEPUB)
                fixture(.pageTurnProbeLTR)
                fixture(.pageTurnProbeRTL)
                fixture(.pageTurnProbeReduceMotion)
                fixture(.pageTurnProbeVoiceOver)
                fixture(.daisyPDF)
            }

            Section {
                Toggle(isOn: $memoryTracker.allDeallocated) {
                    Text("All memory is deallocated")
                }
                .accessibilityIdentifier(.allMemoryDeallocated)
            }
            .disabled(true)
        }
        .fullScreenCover(item: $viewModel.readerViewModel) { viewModel in
            ReaderView(viewModel: viewModel)
        }
    }

    private func fixture(_ fixture: PublicationFixture) -> some View {
        ListRow(action: { viewModel.open(fixture) }) {
            VStack(alignment: .leading) {
                Text(fixture.filename)
                    .font(.headline)

                Text(fixture.description)
                    .font(.caption)
            }

            Spacer()

            Image(systemName: "chevron.right")
        }
        .accessibilityIdentifier(fixture.accessibilityIdentifier)
    }
}

@MainActor
class FixtureListViewModel: ObservableObject {
    @Published var readerViewModel: ReaderViewModel?

    private var openTask: Task<Void, Never>?

    func open(_ fixture: PublicationFixture) {
        openTask?.cancel()
        openTask = Task { try! await open(fixture) }
    }

    private func open(_ fixture: PublicationFixture) async throws {
        let components = fixture.filename.split(separator: ".", maxSplits: 1)
            .map { String($0) }

        guard
            components.count == 2,
            let epubURL = Bundle.main.url(
                forResource: components[0],
                withExtension: components[1],
                subdirectory: "Publications"
            )
        else {
            throw FixtureError.notFound(fixture)
        }

        let fileURL = FileURL(url: epubURL)!

        let container = Container.shared
        var publication = try await container.publication(at: fileURL)
        var resourceFailureController: ResourceFailureController?
        if fixture.hasFailedContinuousNeighbor {
            publication.manifest.readingOrder[1] = Link(
                href: "missing-neighbor.xhtml",
                mediaType: .xhtml
            )
        } else if fixture.failsCurrentResourceOnLayoutSwitch {
            (publication, resourceFailureController) = container
                .publicationFailingResourcesOnDemand(from: publication)
        }
        let preferences = fixture.startsInContinuousScroll
            ? EPUBPreferences(scroll: true)
            : .empty
        let navigator = try container.navigator(
            for: publication,
            epubPreferences: preferences,
            disablePageTurnsWhileScrolling: fixture.startsInContinuousScroll,
            pageTurnStyle: fixture.usesCoverPageTurn ? .cover : .none,
            accessibilityOverride: fixture.accessibilityOverride
        )

        readerViewModel = ReaderViewModel(
            navigator: navigator,
            enablesContinuousScrollActions: fixture.enablesContinuousScrollActions,
            epubPreferences: preferences,
            resourceFailureController: resourceFailureController,
            pageTurnStyle: fixture.usesCoverPageTurn ? .cover : .none
        )
    }
}

enum FixtureError: LocalizedError {
    case notFound(PublicationFixture)

    var errorDescription: String? {
        switch self {
        case let .notFound(fixture):
            return "Test fixture \(fixture.filename) not found in bundle"
        }
    }
}
