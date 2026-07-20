//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import UIKit

final class ResourceFailureController {
    private(set) var failedHREF: AnyURL?

    func failResource(at href: AnyURL) {
        failedHREF = href
    }

    func shouldFail(_ url: any URLConvertible) -> Bool {
        failedHREF?.isEquivalentTo(url) == true
    }
}

private final class FailureInjectingContainer: ReadiumShared.Container {
    let sourceURL: AbsoluteURL? = nil
    let entries: Set<AnyURL> = []

    private let publication: Publication
    private let failureController: ResourceFailureController

    init(
        publication: Publication,
        failureController: ResourceFailureController
    ) {
        self.publication = publication
        self.failureController = failureController
    }

    subscript(url: any URLConvertible) -> Resource? {
        guard !failureController.shouldFail(url) else {
            return nil
        }
        return publication.get(url)
    }
}

/// Shared Readium infrastructure for testing.
@MainActor class Container {
    static let shared = Container()

    let memoryTracker = MemoryTracker()
    let httpClient: HTTPClient
    let assetRetriever: AssetRetriever
    let publicationOpener: PublicationOpener
    var continuousScrollLocation: Locator?

    init() {
        httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)

        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            contentProtections: []
        )
    }

    func publication(at url: FileURL) async throws -> Publication {
        let asset = try await assetRetriever.retrieve(url: url).get()
        let publication = try await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false,
            sender: nil
        ).get()

        memoryTracker.track(publication)
        return publication
    }

    func publicationFailingResourcesOnDemand(
        from publication: Publication
    ) -> (Publication, ResourceFailureController) {
        let failureController = ResourceFailureController()
        let wrappedPublication = Publication(
            manifest: publication.manifest,
            container: FailureInjectingContainer(
                publication: publication,
                failureController: failureController
            )
        )
        memoryTracker.track(wrappedPublication)
        return (wrappedPublication, failureController)
    }

    func navigator(
        for publication: Publication,
        epubPreferences: EPUBPreferences = .empty,
        disablePageTurnsWhileScrolling: Bool = false
    ) throws -> VisualNavigator & UIViewController {
        if publication.conforms(to: .epub) {
            return try epubNavigator(
                for: publication,
                preferences: epubPreferences,
                disablePageTurnsWhileScrolling: disablePageTurnsWhileScrolling
            )
        } else if publication.conforms(to: .pdf) {
            return try pdfNavigator(for: publication)
        } else {
            fatalError("Publication not supported")
        }
    }

    func epubNavigator(
        for publication: Publication,
        preferences: EPUBPreferences = .empty,
        disablePageTurnsWhileScrolling: Bool = false
    ) throws -> EPUBNavigatorViewController {
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: preferences.scroll == true ? continuousScrollLocation : nil,
            config: EPUBNavigatorViewController.Configuration(
                preferences: preferences,
                disablePageTurnsWhileScrolling: disablePageTurnsWhileScrolling
            )
        )
        memoryTracker.track(navigator)
        return navigator
    }

    func pdfNavigator(for publication: Publication) throws -> PDFNavigatorViewController {
        let navigator = try PDFNavigatorViewController(
            publication: publication,
            initialLocation: nil
        )
        memoryTracker.track(navigator)
        return navigator
    }
}
