//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumInternal
import ReadiumShared
import SafariServices
import SwiftSoup
import UIKit
import WebKit

func pageTurnSnapshotsRequireInvalidationForPagesDidChange(
    _ spreadView: UIView,
    in paginationView: PaginationView?
) -> Bool {
    guard let paginationView else { return true }
    return paginationView.axis == .verticalContinuous
        || paginationView.currentView === spreadView
}

private final class WeakNavigationOwner<Owner: AnyObject> {
    weak var value: Owner?

    init(_ value: Owner) {
        self.value = value
    }
}

@MainActor public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate,
    ViewportObservingNavigatorDelegate
{
    /// Root view representing one complete reader page, including app chrome.
    func pageTurnRootView(for navigator: EPUBNavigatorViewController) -> UIView?

    /// UIKit owner for a complete reader surface transaction.
    func pageTurnContainerViewController(
        for navigator: EPUBNavigatorViewController
    ) -> UIViewController?

    /// The complete live surface captured by a simulation transaction.
    func pageTurnLiveSurfaceViewController(
        for navigator: EPUBNavigatorViewController
    ) -> UIViewController?

    /// Presents a temporary location while the live reader is hidden by a page surface.
    func navigator(
        _ navigator: EPUBNavigatorViewController,
        previewLocationDidChange locator: Locator?,
        viewport: NavigatorViewport?
    )

    // MARK: - WebView Customization

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController)
}

public extension EPUBNavigatorDelegate {
    func pageTurnRootView(for navigator: EPUBNavigatorViewController) -> UIView? {
        nil
    }

    func pageTurnContainerViewController(
        for navigator: EPUBNavigatorViewController
    ) -> UIViewController? {
        nil
    }

    func pageTurnLiveSurfaceViewController(
        for navigator: EPUBNavigatorViewController
    ) -> UIViewController? {
        nil
    }

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        previewLocationDidChange locator: Locator?,
        viewport: NavigatorViewport?
    ) {}

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {}
}

public typealias EPUBContentInsets = (top: CGFloat, bottom: CGFloat)

open class EPUBNavigatorViewController: InputObservableViewController,
    VisualNavigator, ViewportObservingNavigator, SelectableNavigator,
    DecorableNavigator, Configurable, Loggable
{
    public enum EPUBError: Error {
        /// The provided publication is restricted. Check that any DRM was
        /// properly unlocked using a Content Protection.
        case publicationRestricted

        /// Returned when calling evaluateJavaScript() before a resource is
        /// loaded.
        case spreadNotLoaded

        /// Failed to serve the publication or assets with the provided HTTP
        /// server.
        @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
        case serverFailure(Error)
    }

    public struct Configuration {
        /// Initial set of setting preferences.
        public var preferences: EPUBPreferences

        /// Provides default fallback values and ranges for the user settings.
        public var defaults: EPUBDefaults

        /// Page turn animation used for horizontally paginated publications.
        public var pageTurnStyle: EPUBPageTurnStyle

        /// Editing actions which will be displayed in the default text selection menu.
        ///
        /// The default set of editing actions is `EditingAction.defaultActions`.
        ///
        /// You can provide custom actions with `EditingAction(title: "Highlight", action: #selector(highlight:))`.
        /// Then, implement the selector in one of your classes in the responder chain. Typically, in the
        /// `UIViewController` wrapping the `EPUBNavigatorViewController`.
        public var editingActions: [EditingAction]

        /// Disables horizontal page turning when scroll is enabled.
        public var disablePageTurnsWhileScrolling: Bool

        /// Content insets used to add some vertical margins around reflowable
        /// EPUB publications. Note that the margins include the safe area
        /// insets. To avoid any "jump" when toggling the status bar, provide
        /// values large enough.
        ///
        /// The insets can be configured for each size class to allow smaller
        /// margins on compact screens.
        ///
        /// For more control, implement the `navigatorContentInset()` delegate
        /// method, which takes precedence over this configuration property
        /// when implemented.
        public var contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]

        /// Number of positions (as in `Publication.positionList`) to preload before the current page.
        public var preloadPreviousPositionCount: Int

        /// Number of positions (as in `Publication.positionList`) to preload after the current page.
        public var preloadNextPositionCount: Int

        /// Supported HTML decoration templates.
        public var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate]

        /// Additional font families which will be available in the preferences.
        public var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]

        /// Readium CSS reading system settings.
        ///
        /// See https://readium.org/readium-css/docs/CSS19-api.html#reading-system-styles
        public var readiumCSSRSProperties: CSSRSProperties

        /// Logs the state changes when true.
        public var debugState: Bool

        public init(
            preferences: EPUBPreferences = .empty,
            defaults: EPUBDefaults = EPUBDefaults(),
            pageTurnStyle: EPUBPageTurnStyle = .push,
            editingActions: [EditingAction] = EditingAction.defaultActions,
            disablePageTurnsWhileScrolling: Bool = false,
            contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
                .compact: (top: 34, bottom: 34),
                .regular: (top: 62, bottom: 62),
            ],
            preloadPreviousPositionCount: Int = 2,
            preloadNextPositionCount: Int = 6,
            decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = HTMLDecorationTemplate.defaultTemplates(),
            fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [],
            readiumCSSRSProperties: CSSRSProperties = CSSRSProperties(),
            debugState: Bool = false
        ) {
            self.preferences = preferences
            self.defaults = defaults
            self.pageTurnStyle = pageTurnStyle
            self.editingActions = editingActions
            self.disablePageTurnsWhileScrolling = disablePageTurnsWhileScrolling
            self.contentInset = contentInset
            self.preloadPreviousPositionCount = preloadPreviousPositionCount
            self.preloadNextPositionCount = preloadNextPositionCount
            self.decorationTemplates = decorationTemplates
            self.fontFamilyDeclarations = fontFamilyDeclarations
            self.readiumCSSRSProperties = readiumCSSRSProperties
            self.debugState = debugState
        }

        func contentInset(for sizeClass: UIUserInterfaceSizeClass) -> EPUBContentInsets {
            contentInset[sizeClass]
                ?? contentInset[.regular]
                ?? contentInset[.unspecified]
                ?? (top: 0, bottom: 0)
        }
    }

    public weak var delegate: EPUBNavigatorDelegate?

    /// Information about the visible portion of the publication, when rendered.
    public private(set) var viewport: NavigatorViewport? {
        didSet {
            if oldValue != viewport {
                delegate?.navigator(self, viewportDidChange: viewport)
            }
        }
    }

    @available(*, deprecated, renamed: "NavigatorViewport")
    public typealias Viewport = NavigatorViewport

    /// Navigation state.
    private enum State: Equatable {
        /// Initializing the navigator.
        case initializing
        /// Loading the spreads at the `pendingLocator`, for example after
        /// changing the user settings, rotating the screen or loading the
        /// publication.
        case loading(pendingLocator: Locator?)
        /// Waiting for further navigation instructions.
        case idle
        /// Jumping to `pendingLocator`.
        case jumping(pendingLocator: Locator)
        /// Turning the page in the given `direction`.
        case moving(direction: EPUBSpreadView.Direction)

        var pendingLocator: Locator? {
            switch self {
            case let .loading(pendingLocator: locator):
                return locator
            case let .jumping(pendingLocator: locator):
                return locator
            default:
                return nil
            }
        }

        mutating func transition(_ event: Event) -> Bool {
            switch (self, event) {
            // Loading the spreads is always possible, because it can be triggered by rotating the
            // screen. In which case it cancels any on-going state.
            case let (_, .load(locator)):
                self = .loading(pendingLocator: locator)

            // All events are ignored when loading spreads, except for `loaded` and `load`.
            case (.loading, .loaded):
                self = .idle

            case (.loading, _):
                return false

            case let (.idle, .jump(locator)):
                self = .jumping(pendingLocator: locator)

            case let (.idle, .move(direction)):
                self = .moving(direction: direction)

            case (.jumping, .jumped):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending jump.
            case (.jumping, .jump),
                 (.jumping, .move):
                return false

            case (.moving, .moved):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending move.
            case (.moving, .jump),
                 (.moving, .move):
                return false

            default:
                log(.error, "Invalid event \(event) for state \(self)")
                return false
            }

            return true
        }
    }

    /// Navigation event.
    private enum Event: Equatable {
        /// Load the spreads at the given locator, for example after changing
        /// the user settings, rotating the screen or loading the publication.
        case load(Locator?)
        /// The spreads were loaded.
        case loaded
        /// Jump to the given locator.
        case jump(Locator)
        /// Finished jumping to a locator.
        case jumped
        /// Turn the page in the given direction.
        case move(EPUBSpreadView.Direction)
        /// Finished turning the page.
        case moved
    }

    /// Current navigation state.
    private var state: State = .initializing {
        didSet {
            if config.debugState {
                log(.debug, "* \(state)")
            }

            // Disable user interaction while transitioning, to avoid UX issues.
            switch state {
            case .initializing, .loading, .jumping, .moving:
                paginationView?.isUserInteractionEnabled = false
            case .idle:
                if paginationView !== pendingReplacementPaginationView {
                    paginationView?.isUserInteractionEnabled = true
                }
            }
        }
    }

    private let readingOrder: [Link]
    public private(set) var currentLocation: Locator?
    /// Sole owner of reading-position mutations submitted by public
    /// navigation entry points. Recovery remains inside the active body.
    private var initializedNavigationExecutor: NavigationOperationExecutor?
    private var navigationExecutor: NavigationOperationExecutor {
        if let executor = initializedNavigationExecutor {
            return executor
        }
        let executor = NavigationOperationExecutor { [weak self] _, result in
            self?.isolateAbandonedNavigation(with: result)
        }
        initializedNavigationExecutor = executor
        return executor
    }

    private var navigationOperationTimeout: NavigationOperationTimeout = .seconds(15)
    private struct DeferredPoisonedPaginationReplacement {
        let stableLocator: Locator?
    }

    private var deferredPoisonedPaginationReplacement: DeferredPoisonedPaginationReplacement?
    private var storedPageTurnStyle: EPUBPageTurnStyle

    /// Retires every live generation synchronously before a timed-out executor
    /// lease is released. A non-cooperative WebKit/UIKit continuation may still
    /// resume later, but it no longer has a surface in the navigation tree.
    private func isolateAbandonedNavigation(with result: NavigationResult) {
        let stableLocator = pageTurnTransaction?.originalLocator
            ?? pageTurnSurfaceOriginalPreview?.location
            ?? currentLocation
        retireAbandonedPageTurn(with: result)
        poisonVisibleSpreads(with: result)
        if deferredPoisonedPaginationReplacement == nil {
            deferredPoisonedPaginationReplacement = .init(
                stableLocator: stableLocator
            )
        }
        paginationView?.isolateForDeferredReload(with: result)
    }

    /// Synchronously releases page-turn ownership before the executor starts a
    /// replacement request. Suspended UIKit/WebKit continuations may resume, but
    /// transaction identity and recovery generation checks reject every late
    /// state write.
    private func retireAbandonedPageTurn(with result: NavigationResult) {
        pageTurnRecoveryGeneration &+= 1
        pageTurnRecoveryTask?.cancel()
        pageTurnRecoveryTask = nil
        pageTurnRecoveryTaskGeneration = nil
        pageTurnDisplayFrameWaiter?.cancel()
        pageTurnDisplayFrameWaiter = nil

        if let transaction = pageTurnTransaction {
            transaction.invalidate()
            transaction.complete(with: transaction.mutationResult.replacingResult(
                result,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .stableLocationRestore
            ))
        }
        pageTurnTransactionTask?.cancel()
        pageTurnTransactionTask = nil
        pageTurnTransaction = nil
        pageTurnRecoverySessionID = nil
        let drainWaiters = pageTurnRecoveryDrainWaiters
        pageTurnRecoveryDrainWaiters.removeAll()
        drainWaiters.forEach { $0.resume() }
        finishPageTurnRecoveryOperationWaiters(with: result)

        pageTurnSurfaceAnimator?.cancelAnimation()
        forceReleaseOrphanPageTurnSurface()
        if let session = pageTurnController.activeSession {
            _ = pageTurnController.finish(session)
        }
        releasePageTurnNavigatorNavigationLock()
        applyDeferredPageTurnInteractionMode()
    }

    private func cancelOwnedNavigationWork() {
        // Do not initialize the executor while `self` is deinitializing. Its
        // isolation callback captures the navigator weakly, and forming that
        // weak reference after Objective-C deallocation has begun aborts the
        // process. An executor which was never initialized owns no work.
        initializedNavigationExecutor?.shutdown()
        hardAbortPanResumeTask?.cancel()
        hardAbortPanResumeTask = nil
        pendingPageTurnGesture = nil
        pageTurnRecoveryTask?.cancel()
        pageTurnRecoveryTask = nil
        pageTurnRecoveryTaskGeneration = nil
        pageTurnRecoverySessionID = nil
        let recoveryDrainWaiters = pageTurnRecoveryDrainWaiters
        pageTurnRecoveryDrainWaiters.removeAll()
        recoveryDrainWaiters.forEach { $0.resume() }
        finishPageTurnRecoveryOperationWaiters(with: .cancelled)
        pageTurnTransactionTask?.cancel()
        pageTurnDisplayFrameWaiter?.cancel()
        pageTurnDisplayFrameWaiter = nil
        pageTurnTransaction?.invalidate()
        if let transaction = pageTurnTransaction {
            transaction.complete(with: transaction.mutationResult.replacingResult(
                .cancelled,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .stableLocationRestore
            ))
        }
        pageTurnSurfaceAnimator?.remove()
        pageTurnSurfaceAnimator = nil
    }

    /// Reader containers should call the normal containment removal APIs;
    /// tests which mount only the view use this hook to model that lifecycle.
    func cancelOwnedNavigationWorkForTesting() {
        cancelOwnedNavigationWork()
    }

    public var pageTurnStyle: EPUBPageTurnStyle {
        get { storedPageTurnStyle }
        set {
            guard storedPageTurnStyle != newValue || !snapshotProvider.isIdle else { return }
            storedPageTurnStyle = newValue
            hasDeferredPageTurnInteractionModeUpdate = true
            cancelActivePageTurn(reason: "pageTurnStyle-set")
            snapshotProvider.invalidate()
            snapshotProvider.deferPageTurnInteraction { [weak self] in
                self?.applyDeferredPageTurnInteractionMode()
            }
        }
    }

    private let loadPositionsByReadingOrder: () async -> ReadResult<[[Locator]]>
    private var positionsByReadingOrder: [[Locator]] = []

    private let viewModel: EPUBNavigatorViewModel
    private let notificationCenter: NotificationCenter
    private var accessibilityObserverTokens: [NSObjectProtocol] = []
    private let accessibilityStatusProvider: @MainActor () -> (
        isReduceMotionEnabled: Bool,
        isVoiceOverRunning: Bool
    )
    public var publication: Publication {
        viewModel.publication
    }

    var config: Configuration {
        viewModel.config
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    ///
    /// - Parameters:
    ///   - publication: EPUB publication to render.
    ///   - initialLocation: Starting location in the publication, defaults to
    ///   the beginning.
    ///   - readingOrder: Custom order of resources to display. Used for example
    ///   to display a non-linear resource on its own.
    ///   - config: Additional navigator configuration.
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init()
    ) throws {
        try self.init(
            publication: publication,
            initialLocation: initialLocation,
            readingOrder: readingOrder,
            config: config,
            notificationCenter: .default,
            accessibilityStatusProvider: {
                (
                    UIAccessibility.isReduceMotionEnabled,
                    UIAccessibility.isVoiceOverRunning
                )
            }
        )
    }

    convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init(),
        notificationCenter: NotificationCenter,
        accessibilityStatusProvider: @escaping @MainActor () -> (
            isReduceMotionEnabled: Bool,
            isVoiceOverRunning: Bool
        )
    ) throws {
        precondition(readingOrder.map { !$0.isEmpty } ?? true)

        guard !publication.isRestricted else {
            throw EPUBError.publicationRestricted
        }

        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: readingOrder ?? publication.readingOrder,
            config: config
        )

        self.init(
            viewModel: viewModel,
            initialLocation: initialLocation,
            readingOrder: viewModel.readingOrder,
            positionsByReadingOrder:
            // Positions and total progression only make sense in the context
            // of the publication's actual reading order. Therefore when
            // provided with a different reading order, we should assume the
            // positions list is empty, and also not compute the
            // totalProgression when calculating the current locator.
            (readingOrder != nil) ? { .success([]) } : publication.positionsByReadingOrder,
            notificationCenter: notificationCenter,
            accessibilityStatusProvider: accessibilityStatusProvider
        )
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init(),
        httpServer: HTTPServer
    ) throws {
        try self.init(
            publication: publication,
            initialLocation: initialLocation,
            readingOrder: readingOrder,
            config: config
        )
    }

    private init(
        viewModel: EPUBNavigatorViewModel,
        initialLocation: Locator?,
        readingOrder: [Link],
        positionsByReadingOrder: @escaping () async -> ReadResult<[[Locator]]>,
        notificationCenter: NotificationCenter,
        accessibilityStatusProvider: @escaping @MainActor () -> (
            isReduceMotionEnabled: Bool,
            isVoiceOverRunning: Bool
        )
    ) {
        self.viewModel = viewModel
        self.notificationCenter = notificationCenter
        self.accessibilityStatusProvider = accessibilityStatusProvider
        currentLocation = initialLocation
        storedPageTurnStyle = viewModel.config.pageTurnStyle
        self.readingOrder = readingOrder
        loadPositionsByReadingOrder = positionsByReadingOrder

        super.init(nibName: nil, bundle: nil)

        viewModel.delegate = self
        viewModel.editingActions.delegate = self

        setupLegacyInputCallbacks(
            onTap: { [weak self] point in
                guard let self else { return }
                self.delegate?.navigator(self, didTapAt: point)
            },
            onPressKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didPressKey: event)
            },
            onReleaseKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didReleaseKey: event)
            }
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        accessibilityObserverTokens = [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.voiceOverStatusDidChangeNotification,
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.accessibilityStatusDidChange()
                }
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            cancelOwnedNavigationWork()
            pageTurnTransaction?.resolve(.cancel)
        }
        viewportPropagationTask?.cancel()
        accessibilityObserverTokens.forEach(notificationCenter.removeObserver)
        notificationCenter.removeObserver(self)
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        // Will call `accessibilityScroll()` when VoiceOver reaches the end of
        // the current resource. We can use this to go to the next resource.
        view.accessibilityTraits.insert(.causesPageTurn)

        Task {
            await initialize()
        }
    }

    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if
            pageTurnTransaction?.isRunning == false,
            !pageTurnController.isIdle
        {
            pageTurnSurfaceAnimator?.retainCurrentSurfaceForSafety()
        }
    }

    private var isActive = true

    @objc private func willResignActive() {
        isActive = false
        cancelActivePageTurn(reason: "willResignActive")
        snapshotProvider.invalidate()
    }

    @objc private func didBecomeActive() {
        isActive = true

        // The device may have rotated since the last time the app was active.
        // We may need to refresh the spreads in this situation. Unfortunately,
        // the `viewWillTransition(to:with:)` API is called before we receive
        // the `didBecomeActive` notification, so we cannot rely on it here.
        deferViewSizeChangeUntilSnapshotRestored(view.bounds.size)

        if needsReloadSpreadsOnActive {
            needsReloadSpreadsOnActive = false
            reloadSpreads()
        }
    }

    private func initialize() async {
        do {
            positionsByReadingOrder = try await loadPositionsByReadingOrder().get()
        } catch {
            log(.error, DebugError("Failed to load positions.", cause: error))
        }

        paginationView = makePaginationView(
            hasPositions: !positionsByReadingOrder.isEmpty
        )

        paginationView!.frame = view.bounds
        paginationView!.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(paginationView!)
        updatePageTurnInteractionMode()
        updatePaginationContentInset()

        applySettings()

        snapshotProvider.invalidate()
        _reloadSpreads()

        onInitializedCallbacks.complete()
    }

    private let onInitializedCallbacks = CompletionList()

    func initialized() async {
        await withCheckedContinuation { continuation in
            whenInitialized {
                continuation.resume()
            }
        }
    }

    private func whenInitialized(_ callback: @escaping () -> Void) {
        let callback = onInitializedCallbacks.add(callback)
        if state != .initializing {
            callback()
        }
    }

    @available(iOS 13.0, *)
    override open func buildMenu(with builder: UIMenuBuilder) {
        viewModel.editingActions.buildMenu(with: builder)
        super.buildMenu(with: builder)
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deferViewSizeChangeUntilSnapshotRestored(view.bounds.size)
        updatePaginationContentInset()
    }

    override open func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updatePaginationContentInset()
    }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // `snapshotView(afterScreenUpdates:)` can synchronously re-enter with
        // non-appearance trait echoes while installing/restoring surfaces or
        // while prepare is still capturing original/target previews. Those must
        // not cancel the in-flight turn. Real color-appearance or contrast
        // changes, however, must cancel mid-turn so we never commit snapshots
        // captured under the previous theme.
        if isInstallingPageTurnSurface || isPreparingPageTurnSurface {
            snapshotProvider.invalidate()
            updatePaginationContentInset()
            return
        }

        let appearanceChanged = previousTraitCollection.map {
            $0.hasDifferentColorAppearance(comparedTo: traitCollection)
        } ?? false
        let contrastChanged = previousTraitCollection.map {
            $0.accessibilityContrast != traitCollection.accessibilityContrast
        } ?? false

        if appearanceChanged || contrastChanged {
            cancelActivePageTurn(reason: "trait-appearance")
        } else if
            pageTurnTransaction == nil,
            pageTurnController.isIdle,
            pendingPageTurnGesture == nil
        {
            // Preserve idle-path cancellation for other trait noise.
            cancelActivePageTurn(reason: "trait-idle")
        }

        snapshotProvider.invalidate()
        updatePaginationContentInset()
    }

    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if isActive {
            cancelActivePageTurn(reason: "viewWillTransition")
            deferViewSizeChangeUntilSnapshotRestored(size)
        }
    }

    override open func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        cancelActivePageTurn(reason: "memoryWarning")
        snapshotProvider.invalidate()
    }

    @discardableResult
    private func on(_ event: Event) -> Bool {
        assert(Thread.isMainThread, "Raising navigation events must be done from the main thread")

        if config.debugState {
            log(.debug, "-> on \(event)")
        }

        return state.transition(event)
    }

    /// Mapping between reading order hrefs and the table of contents title.
    private var tableOfContentsTitleByHref: [AnyURL: String] {
        get async { await tableOfContentsTitleByHrefTask.value }
    }

    private lazy var tableOfContentsTitleByHrefTask: Task<[AnyURL: String], Never> = Task { [publication] in
        func fulfill(linkList: [Link]) -> [AnyURL: String] {
            var result = [AnyURL: String]()

            for link in linkList {
                if let title = link.title {
                    result[link.url()] = title
                }
                let subResult = fulfill(linkList: link.children)
                result.merge(subResult) { current, _ -> String in
                    current
                }
            }
            return result
        }

        guard let toc = try? await publication.tableOfContents().get() else {
            return [:]
        }

        return fulfill(linkList: toc)
    }

    private lazy var pageTurnController = EPUBPageTurnController(
        refreshCurrentLocation: { [weak self] in
            guard let self else { return }
            await self.awaitCurrentLocationRefresh()
        }
    )

    let snapshotProvider = EPUBPageTurnSnapshotProvider()

    private lazy var pageTurnPanGestureRecognizer: UIPanGestureRecognizer = {
        let gestureRecognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePageTurnPan(_:))
        )
        gestureRecognizer.maximumNumberOfTouches = 1
        gestureRecognizer.cancelsTouchesInView = false
        gestureRecognizer.delegate = self
        return gestureRecognizer
    }()

    @MainActor
    private final class PageTurnTransaction {
        enum TerminalIntent {
            case commit
            case cancel
        }

        enum PreparationState {
            case pending
            case preparing
            case ready
            case failed
        }

        let session: PageTurnSession
        var style: EPUBPageTurnStyle
        let target: Locator?
        var progress: CGFloat = 0
        var preparationState: PreparationState = .pending
        var didPrepareTarget = false
        /// True when this transaction was started by replaying a queued reverse
        /// gesture after the previous turn cancelled.
        var isResumedPendingGesture = false
        /// True when `.commit` was resolved before surface prepare began
        /// (discrete edge/keyboard turns). Used to keep preparing through
        /// selection interrupts that would otherwise hard-abort the turn.
        var didResolveCommitBeforePrepare = false
        var originalLocator: Locator?
        var mutationResult = NavigationMutationResult.rejected(
            .cancelled,
            mayHaveMutated: false,
            stage: .preflight
        )
        var didObserveSurface = false
        private(set) var isInvalidated = false
        private(set) var terminalIntent: TerminalIntent?
        private(set) var isRunning = false
        private var isComplete = false
        private var terminalWaiter: CheckedContinuation<Void, Never>?
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []

        var isPrepared: Bool {
            if case .ready = preparationState {
                return true
            }
            return false
        }

        /// Prepare must stop as soon as the user/system cancels, not only when
        /// the cooperative task handle is cancelled.
        var isPrepareCancelled: Bool {
            isInvalidated || terminalIntent == .cancel
        }

        init(
            session: PageTurnSession,
            style: EPUBPageTurnStyle,
            target: Locator?
        ) {
            self.session = session
            self.style = style
            self.target = target
        }

        func start() {
            isRunning = true
            preparationState = style == .none ? .ready : .preparing
        }

        func resolve(_ intent: TerminalIntent) {
            guard !isComplete, terminalIntent != .cancel else { return }
            if terminalIntent == nil || intent == .cancel {
                terminalIntent = intent
            }
            let waiter = terminalWaiter
            terminalWaiter = nil
            waiter?.resume()
        }

        func invalidate() {
            isInvalidated = true
            resolve(.cancel)
        }

        func waitForTerminalIntent(
            operation: NavigationOperationToken
        ) async -> TerminalIntent? {
            let cancellationTask = Task { @MainActor [weak self] in
                _ = await operation.waitForCancellation()
                guard !Task.isCancelled else { return }
                self?.resolve(.cancel)
            }
            defer { cancellationTask.cancel() }
            return await withTaskCancellationHandler {
                if terminalIntent == nil, !isComplete {
                    await withCheckedContinuation { continuation in
                        if terminalIntent != nil || isComplete {
                            continuation.resume()
                        } else {
                            terminalWaiter = continuation
                        }
                    }
                }
                return terminalIntent
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolve(.cancel)
                }
            }
        }

        func complete(with result: NavigationMutationResult) {
            guard !isComplete else { return }
            isComplete = true
            isRunning = false
            mutationResult = result
            let terminalWaiter = terminalWaiter
            self.terminalWaiter = nil
            terminalWaiter?.resume()
            let waiters = completionWaiters
            completionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitForCompletion() async -> NavigationMutationResult {
            if !isComplete {
                await withCheckedContinuation { continuation in
                    completionWaiters.append(continuation)
                }
            }
            return mutationResult
        }
    }

    private struct PendingPageTurnGesture {
        let direction: EPUBSpreadView.Direction
        var translationX: CGFloat
        var velocityX: CGFloat
        var terminalState: UIGestureRecognizer.State?
    }

    private var pageTurnTransaction: PageTurnTransaction?
    private var pendingPageTurnGesture: PendingPageTurnGesture?
    private var hasDeferredPageTurnInteractionModeUpdate = false

    private var pageTurnPanSession: PageTurnSession? {
        pageTurnTransaction?.session
    }

    private var pageTurnSurfaceAnimator: EPUBPageTurnSurfaceAnimator?

    private var pageTurnSurfaceStyle: EPUBPageTurnStyle? {
        pageTurnTransaction?.style
    }

    private var pageTurnSurfaceProgress: CGFloat {
        get { pageTurnTransaction?.progress ?? 0 }
        set { pageTurnTransaction?.progress = newValue }
    }

    private var pageTurnSurfaceDidPrepareTarget: Bool {
        get { pageTurnTransaction?.didPrepareTarget == true }
        set { pageTurnTransaction?.didPrepareTarget = newValue }
    }

    private struct PageTurnPreview: Equatable {
        let location: Locator
        let viewport: NavigatorViewport
    }

    private var pageTurnSurfaceOriginalPreview: PageTurnPreview?
    private var pageTurnSurfaceTargetPreview: PageTurnPreview?
    private var pageTurnSurfaceTargetLocator: Locator? {
        pageTurnTransaction?.target
    }

    private var isInstallingPageTurnSurface = false
    /// True for the whole `preparePageTurnSurface` body (not only install/capture).
    /// Snapshot-driven trait re-entry during preview must not cancel the turn.
    private var isPreparingPageTurnSurface = false
    private var pageTurnTransactionTask: Task<Bool, Never>?
    /// Cancellation recovery runs outside the transaction task so WebView
    /// waiters don't inherit its cancelled state. The lease remains active
    /// until the owning transaction runner has fully stopped mutating state.
    private var pageTurnRecoveryTask: Task<Void, Never>?
    private var pageTurnRecoveryTaskGeneration: UInt64?
    private var pageTurnRecoverySessionID: UUID?
    private var pageTurnRecoveryGeneration: UInt64 = 0
    private var pageTurnRecoveryDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pageTurnRecoveryOperationWaiters: [
        UUID: CheckedContinuation<NavigationResult, Never>
    ] = [:]
    private var pageTurnRecoveryOperationWaiterTasks: [UUID: Task<Void, Never>] = [:]
    var pageTurnNavigationForTesting: ((
        PageTurnSession,
        Locator?
    ) async -> Bool)?
    var pageTurnLocationCalculationForTesting: (
        () async -> (Locator?, NavigatorViewport?)
    )?
    var pageTurnPreviewCalculationForTesting: (
        () async -> (Locator?, NavigatorViewport?)
    )?
    var pageTurnDisplayFrameWaiterForTesting: (() async -> Void)?
    var pageTurnDisplayFrameSchedulerForTesting: (
        @MainActor (PageTurnAnimationFrameWaiter) -> Void
    )?
    private var pageTurnDisplayFrameWaiter: PageTurnAnimationFrameWaiter?
    var pageTurnWillValidateCommitForTesting: (() -> Void)?
    var pageTurnPreparedPageRestoreForTesting: (() async -> Bool)?
    var pageTurnOriginalLocationRestoreForTesting: (() async -> Bool)?
    /// When set, replaces `paginationView.goToIndex` inside
    /// `restorePageTurnLocator` after position→progression resolution so tests
    /// can assert the resolved locator without hanging on headless WebKit go.
    var pageTurnRestoreGoForTesting: ((Locator) async -> Bool)?
    /// When set, replaces `paginationView.goToIndex` inside
    /// `performLocatorNavigation` so tests can drive mutation/verify without
    /// hanging on headless WebKit go.
    var pageTurnGoToIndexForTesting: ((Locator) async -> NavigationResult)?
    var pageTurnRestoreGoToIndexForTesting: ((Locator) async -> Bool)?
    var linkLocatorForTesting: ((Link) async -> Locator?)?
    var locatorNavigationLocationCalculationForTesting: (
        () async -> (Locator?, NavigatorViewport?)
    )?
    var locatorNavigationDOMTargetVerifierForTesting: ((Locator) async -> Bool)?
    var pageTurnLeaseAfterHardAbortRegistrationForTesting: (() async -> Void)?
    private(set) var pageTurnRestoreUsedOperationTokenForTesting: Bool?
    private(set) var pageTurnPoisonReloadLocatorForTesting: Locator?
    private(set) var pageTurnHardAbortSnapHadExecutorLeaseForTesting: Bool?
    /// When set, `isLiveViewAtPageTurnOriginalLocator` uses this synthetic
    /// multi-column geometry instead of the live `UIScrollView`. Headless
    /// WebKit resets forced `contentSize` across `await` suspension points.
    var pageTurnMultiColumnGeometryForTesting: (
        pageWidth: CGFloat,
        contentWidth: CGFloat,
        progression: Double
    )?
    var pageTurnSnapsToPageForTesting: Bool?
    var pageTurnVerticalLocationVerifierForTesting: ((PageLocation, Int) async -> Bool)?
    private(set) var pageTurnInteractionModeUpdateCountForTesting = 0
    private var coldPageTurnTargetIndexForTesting: Int?
    private var isColdPageTurnArmedForTesting = false
    private var didBeginWithColdTargetForTesting = false
    private var didNavigateColdTargetForTesting = false
    private var didCaptureAfterColdNavigationForTesting = false

    /// Each hard-abort synchronously reserves a mandatory executor request.
    /// Multiple restores remain FIFO and never overlap.
    private struct HardAbortRecoveryRequest {
        let locator: Locator?
        let snapAfterRestore: Bool
    }

    private final class HardAbortOperationWaiter {
        let dependencyIDs: Set<UInt64>
        private var terminalResults: [UInt64: NavigationResult] = [:]
        private var terminalResult: NavigationResult?
        private var continuation: CheckedContinuation<NavigationResult, Never>?

        init(dependencyIDs: Set<UInt64>) {
            self.dependencyIDs = dependencyIDs
        }

        func record(operationID: UInt64, result: NavigationResult) -> NavigationResult? {
            guard terminalResult == nil, dependencyIDs.contains(operationID) else {
                return nil
            }
            terminalResults[operationID] = result
            guard terminalResults.count == dependencyIDs.count else { return nil }
            return dependencyIDs.sorted()
                .compactMap { terminalResults[$0] }
                .first(where: { !$0.isApplied })
                ?? .applied
        }

        func wait() async -> NavigationResult {
            if let terminalResult { return terminalResult }
            return await withCheckedContinuation { continuation in
                if let terminalResult {
                    continuation.resume(returning: terminalResult)
                } else {
                    self.continuation = continuation
                }
            }
        }

        func finish(with result: NavigationResult) {
            guard terminalResult == nil else { return }
            terminalResult = result
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private var pendingHardAbortRecoveryIDs: Set<UInt64> = []
    private var hardAbortDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var hardAbortLocationRestoreGeneration: UInt64 = 0
    private var hardAbortLocationRestorePending: Bool {
        !pendingHardAbortRecoveryIDs.isEmpty
    }

    private var hardAbortOperationWaiters: [
        UUID: HardAbortOperationWaiter
    ] = [:]
    private var hardAbortOperationWaiterTasks: [UUID: Task<Void, Never>] = [:]
    /// Flushes a pan that began while restore was still running.
    private var hardAbortPanResumeTask: Task<Void, Never>?

    private func effectivePageTurnStyle(
        userStyle: EPUBPageTurnStyle,
        isReduceMotionEnabled: Bool,
        isVoiceOverRunning: Bool
    ) -> EPUBPageTurnStyle {
        EPUBPageTurnStyle.effective(
            userStyle: userStyle,
            isReduceMotionEnabled: isReduceMotionEnabled,
            isVoiceOverRunning: isVoiceOverRunning
        )
    }

    /// Reserves the restore before this MainActor turn can release the active
    /// mutation lease. Waiting is asynchronous; registration is not.
    private func queueHardAbortLocationRestore(
        _ locator: Locator?,
        snapAfterRestore: Bool
    ) {
        let request = HardAbortRecoveryRequest(
            locator: locator,
            snapAfterRestore: snapAfterRestore
        )
        hardAbortLocationRestoreGeneration &+= 1
        let generation = hardAbortLocationRestoreGeneration
        _ = navigationExecutor.reserve(
            intent: .mustRunRecovery("hard-abort-restore"),
            timeout: navigationOperationTimeout,
            registration: { [weak self] operationID in
                self?.pendingHardAbortRecoveryIDs.insert(operationID)
            },
            completion: { [weak self] operationID, terminalResult in
                self?.finishHardAbortRecovery(
                    operationID: operationID,
                    with: terminalResult
                )
            }
        ) { [weak self] operation in
            guard let self else { return .cancelled }
            return await self.performHardAbortRecovery(
                request,
                generation: generation,
                operation: operation
            )
        }
    }

    private func performHardAbortRecovery(
        _ request: HardAbortRecoveryRequest,
        generation: UInt64,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        operation.beginRecovery()
        let result: NavigationResult
        if let locator = request.locator {
            var restore = await restorePageTurnLocator(
                locator,
                operation: operation
            )
            if let cancellation = operation.check() {
                restore = restore.replacingResult(
                    cancellation,
                    stableLocator: locator,
                    failureStage: .stableLocationRestore
                )
            }
            guard restore.result.isApplied, restore.stableVerified else {
                let failure = restore.result.isApplied
                    ? NavigationResult.spreadNotLoaded
                    : restore.result
                poisonVisibleSpreads(with: failure)
                return await recoverPoisonedSpreadsIfNeeded(
                    after: failure,
                    stableLocator: restore.stableLocator ?? locator,
                    operation: operation
                )
            }
            result = restore.result
        } else {
            result = operation.check() ?? .applied
        }
        if !result.isApplied {
            poisonVisibleSpreads(with: result)
        }
        let terminal = await recoverPoisonedSpreadsIfNeeded(
            after: result,
            stableLocator: request.locator ?? currentLocation,
            operation: operation
        )
        if
            terminal.isApplied,
            request.snapAfterRestore,
            hardAbortLocationRestoreGeneration == generation,
            operation.check() == nil
        {
            pageTurnHardAbortSnapHadExecutorLeaseForTesting =
                navigationExecutor.activeOperationCountForTesting == 1
            snapVisibleDocumentToPageBoundaries()
        }
        return terminal
    }

    /// Waits until the restore worker is idle and no request remains.
    private func awaitHardAbortLocationRestoreIfNeeded() async {
        while hardAbortLocationRestorePending {
            await withCheckedContinuation { continuation in
                if hardAbortLocationRestorePending {
                    hardAbortDrainWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func registerHardAbortOperationWaiter(
        operation: NavigationOperationToken
    ) -> (id: UUID, waiter: HardAbortOperationWaiter)? {
        let dependencyIDs = Set(pendingHardAbortRecoveryIDs.filter {
            $0 < operation.operationID
        })
        guard !dependencyIDs.isEmpty else { return nil }
        let id = UUID()
        let waiter = HardAbortOperationWaiter(dependencyIDs: dependencyIDs)
        hardAbortOperationWaiters[id] = waiter
        hardAbortOperationWaiterTasks[id] = Task { @MainActor [weak self] in
            let result = await operation.waitForCancellation()
            self?.finishHardAbortOperationWaiter(id, with: result)
        }
        return (id, waiter)
    }

    /// After restore drains, replay any pan that was buffered during restore.
    private func schedulePendingPanResumeAfterHardAbortRestore() {
        guard hardAbortPanResumeTask == nil else { return }
        hardAbortPanResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.hardAbortPanResumeTask = nil }
            await self.awaitPageTurnRecoveryDrainIfNeeded()
            guard !Task.isCancelled else { return }
            await self.awaitHardAbortLocationRestoreIfNeeded()
            guard !Task.isCancelled else { return }
            await self.resumePendingPageTurnGesture()
        }
    }

    private func isCurrentPageTurnRecovery(
        _ transaction: PageTurnTransaction,
        generation: UInt64
    ) -> Bool {
        pageTurnRecoveryGeneration == generation
            && pageTurnRecoverySessionID == transaction.session.id
            && pageTurnTransaction === transaction
    }

    private func runPageTurnRecovery(
        for transaction: PageTurnTransaction,
        operation token: NavigationOperationToken,
        operation: @escaping @MainActor (
            EPUBNavigatorViewController,
            PageTurnTransaction,
            UInt64
        ) async -> Void
    ) async {
        guard pageTurnTransaction === transaction else { return }

        pageTurnRecoveryGeneration &+= 1
        let generation = pageTurnRecoveryGeneration
        pageTurnRecoverySessionID = transaction.session.id
        token.beginRecovery()
        guard isCurrentPageTurnRecovery(transaction, generation: generation) else {
            return
        }
        // Recovery must not inherit cancellation from the mutation task, but
        // it remains registered with the executor-owned token so its deadline
        // cancels this task too.
        let task = Task.detached { @MainActor in
            await operation(self, transaction, generation)
        }
        pageTurnRecoveryTask = task
        pageTurnRecoveryTaskGeneration = generation
        let recoveryTaskID = token.registerRecoveryTask(task)
        await task.value
        token.unregisterRecoveryTask(recoveryTaskID)
        if pageTurnRecoveryTaskGeneration == generation {
            pageTurnRecoveryTask = nil
            pageTurnRecoveryTaskGeneration = nil
        }
    }

    private func finishPageTurnRecovery(
        for transaction: PageTurnTransaction
    ) {
        guard pageTurnRecoverySessionID == transaction.session.id else { return }
        pageTurnRecoverySessionID = nil
        if pageTurnTransaction == nil {
            pageTurnTransactionTask = nil
        }
        let waiters = pageTurnRecoveryDrainWaiters
        pageTurnRecoveryDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        finishPageTurnRecoveryOperationWaiters(with: .applied)
    }

    private func awaitPageTurnRecoveryDrainIfNeeded() async {
        guard pageTurnRecoverySessionID != nil else { return }
        await withCheckedContinuation { continuation in
            if pageTurnRecoverySessionID == nil {
                continuation.resume()
            } else {
                pageTurnRecoveryDrainWaiters.append(continuation)
            }
        }
    }

    private func awaitPageTurnRecoveryDrainIfNeeded(
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard pageTurnRecoverySessionID != nil else {
            return operation.check() ?? .applied
        }
        let id = UUID()
        pageTurnRecoveryOperationWaiterTasks[id] = Task { @MainActor [weak self] in
            let result = await operation.waitForCancellation()
            self?.finishPageTurnRecoveryOperationWaiter(id, with: result)
        }
        return await withCheckedContinuation { continuation in
            if pageTurnRecoverySessionID == nil {
                pageTurnRecoveryOperationWaiterTasks.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: operation.check() ?? .applied)
            } else {
                pageTurnRecoveryOperationWaiters[id] = continuation
            }
        }
    }

    private func awaitPageTurnNavigationLease() async {
        repeat {
            await awaitPageTurnRecoveryDrainIfNeeded()
            await awaitHardAbortLocationRestoreIfNeeded()
        } while pageTurnRecoverySessionID != nil || hardAbortLocationRestorePending
    }

    private func awaitPageTurnNavigationLease(
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        let hardAbortBoundary = registerHardAbortOperationWaiter(
            operation: operation
        )
        if let hook = pageTurnLeaseAfterHardAbortRegistrationForTesting {
            await hook()
        }
        repeat {
            let recovery = await awaitPageTurnRecoveryDrainIfNeeded(operation: operation)
            guard recovery.isApplied else {
                if let hardAbortBoundary {
                    finishHardAbortOperationWaiter(
                        hardAbortBoundary.id,
                        with: recovery
                    )
                }
                return recovery
            }
        } while pageTurnRecoverySessionID != nil
        if let hardAbortBoundary {
            let hardAbort = await hardAbortBoundary.waiter.wait()
            guard hardAbort.isApplied else { return hardAbort }
        }
        return operation.check() ?? .applied
    }

    private func finishPageTurnRecoveryOperationWaiter(
        _ id: UUID,
        with result: NavigationResult
    ) {
        pageTurnRecoveryOperationWaiterTasks.removeValue(forKey: id)?.cancel()
        pageTurnRecoveryOperationWaiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func finishPageTurnRecoveryOperationWaiters(with result: NavigationResult) {
        let ids = Array(pageTurnRecoveryOperationWaiters.keys)
        ids.forEach { finishPageTurnRecoveryOperationWaiter($0, with: result) }
    }

    private func finishHardAbortOperationWaiter(
        _ id: UUID,
        with result: NavigationResult
    ) {
        hardAbortOperationWaiterTasks.removeValue(forKey: id)?.cancel()
        hardAbortOperationWaiters.removeValue(forKey: id)?.finish(with: result)
    }

    private func finishHardAbortRecovery(
        operationID: UInt64,
        with result: NavigationResult
    ) {
        guard pendingHardAbortRecoveryIDs.remove(operationID) != nil else {
            return
        }

        for waiterID in Array(hardAbortOperationWaiters.keys) {
            guard let waiter = hardAbortOperationWaiters[waiterID],
                  waiter.dependencyIDs.contains(operationID)
            else {
                continue
            }
            guard let terminalResult = waiter.record(
                operationID: operationID,
                result: result
            ) else { continue }
            finishHardAbortOperationWaiter(waiterID, with: terminalResult)
        }

        if pendingHardAbortRecoveryIDs.isEmpty {
            let waiters = hardAbortDrainWaiters
            hardAbortDrainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func beginPageTurn(
        to direction: EPUBSpreadView.Direction,
        ownsPendingGesture: Bool = false
    ) async -> PageTurnSession? {
        // Drain any recovery or hard-abort restore before opening a new session
        // so a previous WebView navigation cannot race the next gesture.
        await awaitPageTurnNavigationLease()
        // Recover from selection-interrupted stuck presentation for every style
        // so the user does not need to leave the book to get a clean page again.
        let hasOrphanWork = ownsPendingGesture
            ? hasInFlightPageTurnWorkExcludingPendingGesture
            : hasInFlightPageTurnWork
        if hasOrphanWork, pageTurnTransaction?.isRunning != true {
            hardAbortInFlightPageTurn(
                restorePreparedLocation: true,
                reason: "beginPageTurn-orphan"
            )
            await awaitPageTurnNavigationLease()
        }
        return openPageTurnSession(to: direction)
    }

    private func beginPageTurn(
        to direction: EPUBSpreadView.Direction,
        operation: NavigationOperationToken
    ) async -> NavigationValueResult<PageTurnSession> {
        let firstLease = await awaitPageTurnNavigationLease(operation: operation)
        guard firstLease.isApplied else { return .rejected(firstLease) }
        if hasInFlightPageTurnWork, pageTurnTransaction?.isRunning != true {
            hardAbortInFlightPageTurn(
                restorePreparedLocation: true,
                reason: "beginPageTurn-orphan"
            )
            let recoveredLease = await awaitPageTurnNavigationLease(operation: operation)
            guard recoveredLease.isApplied else { return .rejected(recoveredLease) }
        }
        if let result = operation.check() { return .rejected(result) }
        guard let session = openPageTurnSession(to: direction) else {
            return .rejected(.spreadNotLoaded)
        }
        return .applied(session)
    }

    /// Opens a page-turn session assuming hard-abort restore is not pending.
    /// Callers that cannot await must only use this when
    /// `hardAbortLocationRestorePending` is false.
    private func openPageTurnSession(
        to direction: EPUBSpreadView.Direction
    ) -> PageTurnSession? {
        guard on(.move(direction)) else { return nil }
        guard let session = pageTurnController.begin(
            to: direction,
            readingProgression: viewModel.readingProgression
        ) else {
            on(.moved)
            return nil
        }
        return session
    }

    private func performPageTurn(
        _ session: PageTurnSession,
        options: NavigatorGoOptions,
        target: Locator? = nil,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        guard let navigation = pageTurnNavigation(
            session,
            options: options,
            target: target,
            operation: operation
        ) else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        return await navigation()
    }

    private func pageTurnNavigation(
        _ session: PageTurnSession,
        options: NavigatorGoOptions,
        target: Locator?,
        operation: NavigationOperationToken
    ) -> (() async -> NavigationMutationResult)? {
        if let pageTurnNavigationForTesting {
            return {
                let applied = await pageTurnNavigationForTesting(session, target)
                return applied
                    ? .applied(mayHaveMutated: true)
                    : .rejected(
                        .spreadNotLoaded,
                        mayHaveMutated: true,
                        stage: .pageViewMutation
                    )
            }
        }
        guard let paginationView else { return nil }

        if let target,
           let resourceIndex = readingOrder.firstIndexWithHREF(target.href),
           let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex)
        {
            return {
                await paginationView.goToIndexWithMutation(
                    spreadIndex,
                    location: .locator(target),
                    options: options,
                    operation: operation
                )
            }
        }

        let spreadView = paginationView.currentView as? EPUBSpreadView
        let currentSpreadIndex = currentSpreadIndex
        let isRTL = (session.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        return {
            if let spreadView {
                let withinSpread = await spreadView.go(
                    to: session.direction,
                    options: options,
                    operation: operation
                )
                if withinSpread.result.isApplied || withinSpread.mayHaveMutated {
                    return withinSpread
                }
            }
            switch session.direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndexWithMutation(
                    currentSpreadIndex - delta,
                    location: location,
                    options: options,
                    operation: operation
                )
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndexWithMutation(
                    currentSpreadIndex + delta,
                    location: location,
                    options: options,
                    operation: operation
                )
            }
        }
    }

    private func finishPageTurn(
        _ session: PageTurnSession,
        didMove: Bool = true
    ) {
        guard pageTurnController.finish(session) else { return }
        if
            let transaction = pageTurnTransaction,
            transaction.session.id == session.id,
            !transaction.isRunning
        {
            transaction.complete(with: transaction.mutationResult.replacingResult(
                .cancelled,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .stableLocationRestore
            ))
            pageTurnTransaction = nil
        }
        // Never leave a snapshot mounted after the controller is idle with no
        // owning transaction — that blocks the next installPageTurnSurface.
        if pageTurnTransaction == nil, pageTurnSurfaceAnimator != nil {
            forceReleaseOrphanPageTurnSurface()
        }
        // beginPageTurn always acquires `.moving` via on(.move). Ending the
        // controller session must release the navigator navigation lock even
        // when location restore or snapshot recapture failed — otherwise a
        // pending reverse gesture can never begin.
        // `didMove` is retained for call-site clarity only.
        _ = didMove
        releasePageTurnNavigatorNavigationLock()
        applyDeferredPageTurnInteractionMode()
    }

    /// Drop whatever navigation lock a page-turn session may have left behind
    /// (`.moving` from begin, or `.loading` from reload restore fallback).
    private func releasePageTurnNavigatorNavigationLock() {
        switch state {
        case .moving:
            on(.moved)
        case .loading:
            on(.loaded)
        case .jumping:
            on(.jumped)
        case .idle, .initializing:
            break
        }
    }

    /// Completes a surface-style turn when the user committed but overlay
    /// prepare failed (interactive pan, discrete tap, missing root, capture
    /// failure, resumed reverse). If prepare already moved the live page, only
    /// publish; otherwise perform the same instant navigation as `.none`.
    private func commitPageTurnAfterFailedSurfacePrepare(
        _ transaction: PageTurnTransaction,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        let session = transaction.session
        // Capture before cleanup: `cleanupPageTurnSurface` clears
        // `pageTurnSurfaceDidPrepareTarget`, which writes through to
        // `transaction.didPrepareTarget`. Reading after cleanup always sees
        // false and would wrongly perform another forward navigation.
        let didPrepareTarget = transaction.didPrepareTarget
        let originalLocator = transaction.originalLocator
        cleanupPageTurnSurface(session)
        if didPrepareTarget {
            let committed = await pageTurnController.commit(session) { [self] in
                defer { finishPageTurn(session) }
                if isActivePageTurnCommitCancelled(session) {
                    await reversePageTurnAfterCancelledCommit(
                        session,
                        originalLocator: originalLocator,
                        operation: operation
                    )
                    return false
                }
                await waitForPageTurnDisplayFrames()
                if isActivePageTurnCommitCancelled(session) {
                    await reversePageTurnAfterCancelledCommit(
                        session,
                        originalLocator: originalLocator,
                        operation: operation
                    )
                    return false
                }
                // Locator navigation verifies the live target after this
                // fallback returns. Let that outer commit publish it only after
                // verification succeeds, as the normal surface path does.
                guard pageTurnSurfaceTargetLocator == nil else {
                    return true
                }
                return await publishCurrentLocationIfCommitStillActive(
                    session,
                    originalLocator: originalLocator,
                    operation: operation
                )
            }
            guard committed else {
                return .rejected(
                    operation.check() ?? .spreadNotLoaded,
                    mayHaveMutated: transaction.mutationResult.mayHaveMutated,
                    stableLocator: transaction.mutationResult.stableLocator
                        ?? originalLocator,
                    stage: .publication
                )
            }
            return transaction.mutationResult
        }
        return await commitPageTurn(
            session,
            options: .none,
            operation: operation
        )
    }

    private func commitPageTurn(
        _ session: PageTurnSession,
        options: NavigatorGoOptions,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        var mutation = NavigationMutationResult.rejected(
            .cancelled,
            mayHaveMutated: false,
            stage: .preflight
        )
        let committed = await pageTurnController.commit(session) { [self] in
            defer { finishPageTurn(session) }
            // `.none` has no surface animator; honour invalidate the same way
            // surface commit checks shouldContinue / isInvalidated.
            if isActivePageTurnCommitCancelled(session) {
                mutation = .rejected(
                    .cancelled,
                    mayHaveMutated: false,
                    stage: .preflight
                )
                return false
            }
            // Capture before navigation so cancel recovery can re-locate even
            // when inverse page-turn fails (cross-resource cold chapter, etc.).
            let originalLocator = capturePageTurnCommitOriginalLocator(session)
            mutation = await performPageTurn(
                session,
                options: options,
                operation: operation
            )
            .preservingStableLocator(originalLocator)
            if let transaction = pageTurnTransaction,
               transaction.session.id == session.id
            {
                transaction.mutationResult = mutation
            }
            guard mutation.result.isApplied else { return false }
            if isActivePageTurnCommitCancelled(session) {
                await reversePageTurnAfterCancelledCommit(
                    session,
                    originalLocator: originalLocator,
                    operation: operation
                )
                mutation = .rejected(
                    .cancelled,
                    mayHaveMutated: mutation.mayHaveMutated,
                    stableLocator: originalLocator,
                    stage: .stableLocationRestore
                )
                return false
            }
            if
                let transaction = pageTurnTransaction,
                transaction.session.id == session.id,
                transaction.style == .none
            {
                await waitForPageTurnDisplayFrames()
            }
            if isActivePageTurnCommitCancelled(session) {
                await reversePageTurnAfterCancelledCommit(
                    session,
                    originalLocator: originalLocator,
                    operation: operation
                )
                mutation = .rejected(
                    .cancelled,
                    mayHaveMutated: mutation.mayHaveMutated,
                    stableLocator: originalLocator,
                    stage: .stableLocationRestore
                )
                return false
            }
            // See the matching fallback branch above. An absolute locator turn
            // must not publish until `finishLocatorNavigation` verifies it.
            guard pageTurnSurfaceTargetLocator == nil else {
                return true
            }
            // Re-check after the async location calculation: cancel during
            // compute must not still notify the target location.
            let published = await publishCurrentLocationIfCommitStillActive(
                session,
                originalLocator: originalLocator,
                operation: operation
            )
            if !published {
                mutation = .rejected(
                    .spreadNotLoaded,
                    mayHaveMutated: mutation.mayHaveMutated,
                    stableLocator: originalLocator,
                    stage: .publication
                )
            }
            return published
        }
        if committed {
            return mutation
        }
        if mutation.result.isApplied {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: mutation.mayHaveMutated,
                stableLocator: mutation.stableLocator,
                stage: .publication
            )
        }
        return mutation
    }

    private func capturePageTurnCommitOriginalLocator(
        _ session: PageTurnSession
    ) -> Locator? {
        if
            let transaction = pageTurnTransaction,
            transaction.session.id == session.id
        {
            if transaction.originalLocator == nil {
                transaction.originalLocator = currentLocation
            }
            return transaction.originalLocator
        }
        return currentLocation
    }

    private func isActivePageTurnCommitCancelled(_ session: PageTurnSession) -> Bool {
        guard
            let transaction = pageTurnTransaction,
            transaction.session.id == session.id
        else {
            return false
        }
        return transaction.isInvalidated || transaction.terminalIntent == .cancel
    }

    private func publishCurrentLocationIfCommitStillActive(
        _ session: PageTurnSession,
        originalLocator: Locator?,
        operation: NavigationOperationToken
    ) async -> Bool {
        let calculate = pageTurnLocationCalculationForTesting
            ?? computeCurrentLocationAndViewport
        let calculation = await calculateCurrentLocationAndViewport(
            calculating: calculate,
            operation: operation
        )
        guard case let .applied((location, newViewport)) = calculation else {
            return false
        }
        if isActivePageTurnCommitCancelled(session) {
            await reversePageTurnAfterCancelledCommit(
                session,
                originalLocator: originalLocator,
                operation: operation
            )
            return false
        }
        guard operation.check() == nil else {
            return false
        }
        return publishCurrentLocation(location: location, viewport: newViewport)
    }

    private func reversePageTurnAfterCancelledCommit(
        _ session: PageTurnSession,
        originalLocator: Locator?,
        operation: NavigationOperationToken
    ) async {
        guard
            let transaction = pageTurnTransaction,
            transaction.session.id == session.id
        else {
            return
        }
        await runPageTurnRecovery(
            for: transaction,
            operation: operation
        ) { owner, transaction, generation in
            await owner.performReversePageTurnAfterCancelledCommit(
                transaction,
                originalLocator: originalLocator,
                recoveryGeneration: generation,
                operation: operation
            )
        }
    }

    private func performReversePageTurnAfterCancelledCommit(
        _ transaction: PageTurnTransaction,
        originalLocator: Locator?,
        recoveryGeneration: UInt64,
        operation: NavigationOperationToken
    ) async {
        guard isCurrentPageTurnRecovery(transaction, generation: recoveryGeneration) else {
            return
        }
        let session = transaction.session
        let inverse = PageTurnSession(
            direction: session.direction == .left ? .right : .left,
            readingProgression: session.readingProgression
        )
        // Match surface restorePreparedPage: a true reverse is not enough —
        // the live view must actually report the saved original Locator before
        // we skip locator/reload fallbacks. Use a location check (not full
        // surface geometry stability) so a false-positive reverse still falls
        // through without blocking cancel recovery on layout settling.
        let reverseMutation = await performPageTurn(
            inverse,
            options: .none,
            operation: operation
        )
        let didReverse = reverseMutation.result.isApplied
        guard isCurrentPageTurnRecovery(transaction, generation: recoveryGeneration) else {
            return
        }
        if didReverse {
            let isOriginal = await isLiveViewAtPageTurnOriginalLocator(
                originalLocator,
                operation: operation
            )
            guard isCurrentPageTurnRecovery(transaction, generation: recoveryGeneration) else {
                return
            }
            if isOriginal {
                return
            }
        }
        guard let originalLocator else {
            log(.error, "Cancelled page-turn could not reverse and has no original locator.")
            failPageTurnRecovery(with: operation.check() ?? .spreadNotLoaded)
            return
        }
        let restore = await restorePageTurnLocator(
            originalLocator,
            operation: operation
        )
        guard isCurrentPageTurnRecovery(transaction, generation: recoveryGeneration) else {
            return
        }
        if restore.result.isApplied, restore.stableVerified {
            let isOriginal = await isLiveViewAtPageTurnOriginalLocator(
                originalLocator,
                operation: operation
            )
            guard isCurrentPageTurnRecovery(transaction, generation: recoveryGeneration) else {
                return
            }
            if isOriginal {
                return
            }
        }
        let didReload = await reloadPageTurnOriginalLocation(
            originalLocator,
            operation: operation
        )
        guard isCurrentPageTurnRecovery(transaction, generation: recoveryGeneration) else {
            return
        }
        if didReload {
            return
        }
        log(.error, "Failed to restore the original location after a cancelled page-turn.")
        failPageTurnRecovery(with: operation.check() ?? .spreadNotLoaded)
    }

    /// A recovery which cannot prove the stable locator must retire the live
    /// generation before releasing the executor lease.
    private func failPageTurnRecovery(with result: NavigationResult) {
        poisonVisibleSpreads(with: result)
        if deferredPoisonedPaginationReplacement == nil {
            deferredPoisonedPaginationReplacement = .init(
                stableLocator: pageTurnTransaction?.originalLocator
                    ?? pageTurnSurfaceOriginalPreview?.location
                    ?? currentLocation
            )
        }
        paginationView?.isolateForDeferredReload()
    }

    /// Confirms cancel recovery landed on the saved original page.
    ///
    /// - Wrong resource: rejected by pagination spread index.
    /// - Same resource multi-column: CSS columns share that index, so
    ///   `locations.progression` is checked with the JS definition
    ///   (`abs(scrollX) / scrollWidth`) via `leadingProgression`. When the
    ///   saved Locator is position-only, the live column is mapped through the
    ///   positions list and compared to `locations.position` — never "resource
    ///   equal ⇒ success".
    /// - Single-page reflowable / fixed-layout: resource index is definitive.
    /// Published `currentLocation` is not trusted: it can lag behind prepare
    /// navigation.
    private func isLiveViewAtPageTurnOriginalLocator(
        _ locator: Locator?,
        operation: NavigationOperationToken
    ) async -> Bool {
        guard let locator, let paginationView else { return false }
        func waitForVerificationFrame() async -> Bool {
            await waitForPageTurnDisplayFrame(operation: operation).isApplied
        }
        guard await waitForVerificationFrame() else { return false }
        if
            let resourceIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex),
            paginationView.currentIndex != spreadIndex
        {
            guard await waitForVerificationFrame() else { return false }
            if paginationView.currentIndex != spreadIndex {
                return false
            }
        }

        // Do not call `pageTurnLocationCalculationForTesting` here: that hook is
        // the publish-path probe and tests often return a synthetic *target*
        // location to exercise cancel-during-publish.

        if
            paginationView.currentView is EPUBReflowableSpreadView
            || pageTurnMultiColumnGeometryForTesting != nil
        {
            func readGeometry() -> (
                pageWidth: CGFloat,
                contentWidth: CGFloat,
                progression: () -> Double
            )? {
                if let forced = pageTurnMultiColumnGeometryForTesting {
                    return (
                        forced.pageWidth,
                        forced.contentWidth,
                        { forced.progression }
                    )
                }
                guard let reflowable = paginationView.currentView as? EPUBReflowableSpreadView
                else {
                    return nil
                }
                return (
                    reflowable.scrollView.bounds.width,
                    reflowable.scrollView.contentSize.width,
                    { reflowable.leadingProgression }
                )
            }

            guard var geometry = readGeometry() else {
                return false
            }
            // Zero bounds/content are not a single-page resource — cold chapter
            // load and reload often report 0 on the first frame. Wait one frame
            // and fail closed if layout is still unusable so restore can run.
            if geometry.pageWidth <= 0 || geometry.contentWidth <= 0 {
                guard await waitForVerificationFrame() else { return false }
                guard let retried = readGeometry() else {
                    return false
                }
                geometry = retried
                if geometry.pageWidth <= 0 || geometry.contentWidth <= 0 {
                    let calculation = await NavigationOperationWaiter<(
                        Locator?, NavigatorViewport?
                    )>().wait(
                        operation: operation,
                        work: computeCurrentLocationAndViewport,
                        onAbandon: { [weak self] result in
                            self?.failPageTurnRecovery(with: result)
                        }
                    )
                    guard case let .applied((current, _)) = calculation else {
                        return false
                    }
                    return pageTurnLocatorMatchesOriginal(current, locator)
                }
            }

            let pageWidth = geometry.pageWidth
            let contentWidth = geometry.contentWidth
            let readLiveProgression = geometry.progression
            guard contentWidth > pageWidth + 0.5 else {
                // In continuous scroll, a resource can be one column wide but
                // many viewports tall. Verify the requested resource-local
                // offset against PaginationView's outer live Y.
                if locatorHasWithinResourceTarget(locator),
                   let resourceIndex = readingOrder.firstIndexWithHREF(locator.href),
                   let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex),
                   paginationView.axis == .verticalContinuous
                   || pageTurnVerticalLocationVerifierForTesting != nil
                {
                    let location = PageLocation.locator(
                        resolvePageTurnLocatorForRestore(locator)
                    )
                    if let verify = pageTurnVerticalLocationVerifierForTesting {
                        let verification = await NavigationOperationWaiter<Bool>().wait(
                            operation: operation,
                            work: { await verify(location, spreadIndex) },
                            onAbandon: { [weak self] result in
                                self?.failPageTurnRecovery(with: result)
                            }
                        )
                        if case .applied(true) = verification {
                            return true
                        }
                        return false
                    }
                    let verification = await NavigationOperationWaiter<Bool>().wait(
                        operation: operation,
                        work: {
                            await paginationView.isAtVerticalLocation(
                                location,
                                at: spreadIndex
                            )
                        },
                        onAbandon: { [weak self] result in
                            self?.failPageTurnRecovery(with: result)
                        }
                    )
                    if case .applied(true) = verification {
                        return true
                    }
                    return false
                }
                // Horizontal content that fits one viewport has no additional
                // within-resource page to verify.
                return true
            }

            // Multi-column same resource: prefer progression; otherwise position.
            if let expectedProgression = locator.locations.progression {
                let liveProgression = readLiveProgression()
                let live = Locator(
                    href: locator.href,
                    mediaType: locator.mediaType,
                    locations: .init(progression: liveProgression)
                )
                if pageTurnLocatorMatchesOriginal(live, locator) {
                    return true
                }
                guard await waitForVerificationFrame() else { return false }
                let retriedProgression = readLiveProgression()
                let retried = Locator(
                    href: locator.href,
                    mediaType: locator.mediaType,
                    locations: .init(progression: retriedProgression)
                )
                if pageTurnLocatorMatchesOriginal(retried, locator) {
                    return true
                }
                let snapsToPage = pageTurnSnapsToPageForTesting
                    ?? !(viewModel.scroll && viewModel.verticalText)
                let reachable = EPUBReflowableSpreadView.reachableHorizontalProgression(
                    requested: expectedProgression,
                    pageWidth: pageWidth,
                    contentWidth: contentWidth,
                    isRTL: viewModel.readingProgression == .rtl,
                    snapsToPage: snapsToPage
                )
                if snapsToPage {
                    let pageSpan = Double(pageWidth / contentWidth)
                    return abs(retriedProgression - reachable)
                        <= max(pageSpan * 0.51, 0.001)
                }
                let pixelTolerance = Double(
                    EPUBReflowableSpreadView.settlementPixelTolerance / contentWidth
                )
                return abs(retriedProgression - reachable)
                    <= max(pixelTolerance, 0.000_001)
            }

            if let expectedPosition = locator.locations.position {
                if let livePosition = pageTurnPosition(
                    href: locator.href,
                    progression: readLiveProgression()
                ), livePosition == expectedPosition {
                    return true
                }
                guard await waitForVerificationFrame() else { return false }
                if let retriedPosition = pageTurnPosition(
                    href: locator.href,
                    progression: readLiveProgression()
                ) {
                    return retriedPosition == expectedPosition
                }
                // Position-only multi-column without a positions list cannot be
                // verified from resource index alone — fail closed so restore runs.
                return false
            }

            // A DOM target in a multi-column resource cannot be verified from
            // the resource index: the live view may still be on another column.
            if locatorHasPreciseDOMTarget(locator) {
                guard
                    let spreadView = paginationView.currentView as? EPUBSpreadView
                else {
                    return false
                }
                return await (spreadView.isLocatorVisible(
                    locator,
                    operation: operation
                )).isApplied
            }

            // No within-resource anchor: resource index is the best available signal.
            return true
        }

        // Fixed-layout / non-reflowable spreads: resource index match is enough.
        if
            let resourceIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex)
        {
            return paginationView.currentIndex == spreadIndex
        }
        return false
    }

    /// Maps resource progression to a discrete position using the same ceil
    /// formula as `EPUBViewportAndLocationCalculator`.
    private func pageTurnPosition(href: AnyURL, progression: Double) -> Int? {
        guard
            let resourceIndex = readingOrder.firstIndexWithHREF(href),
            let positions = positionsByReadingOrder.getOrNil(resourceIndex),
            !positions.isEmpty
        else {
            return nil
        }
        let clamped = min(max(progression, 0), 1)
        let index = Int(ceil(clamped * Double(positions.count - 1)))
        let safeIndex = min(max(index, 0), positions.count - 1)
        return positions[safeIndex].locations.position
    }

    private func locatorHasWithinResourceTarget(_ locator: Locator) -> Bool {
        locator.locations.progression != nil
            || locator.locations.position != nil
            || !locator.locations.fragments.isEmpty
            || locator.locations.otherLocations["cssSelector"] != nil
            || locator.text.highlight != nil
    }

    private func pageTurnLocatorMatchesOriginal(
        _ current: Locator?,
        _ original: Locator
    ) -> Bool {
        guard
            let current,
            current.href.isEquivalentTo(original.href)
        else {
            return false
        }
        if current.locations == original.locations {
            return true
        }
        if
            let expected = original.locations.progression,
            let actual = current.locations.progression
        {
            return abs(expected - actual) < 0.001
        }
        if
            let expected = original.locations.position,
            let actual = current.locations.position
        {
            return expected == actual
        }
        return false
    }

    private func restorePageTurnLocator(
        _ locator: Locator,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        // Recovery remains under the owning executor's deadline and watchdog.
        // A fresh token would let a timed-out request continue without an active
        // executor task to cancel it.
        operation.beginRecovery()
        pageTurnRestoreUsedOperationTokenForTesting = true
        if let pageTurnOriginalLocationRestoreForTesting {
            return await pageTurnOriginalLocationRestoreForTesting()
                ? NavigationMutationResult.applied(
                    mayHaveMutated: true,
                    stableLocator: locator
                ).verifiedStableLocation()
                : .rejected(
                    operation.check() ?? .spreadNotLoaded,
                    mayHaveMutated: true,
                    stableLocator: locator,
                    stage: .stableLocationRestore
                )
        }
        let resolved = resolvePageTurnLocatorForRestore(locator)
        let mutation: NavigationMutationResult
        if let restoreGo = pageTurnRestoreGoForTesting {
            mutation = await restoreGo(resolved)
                ? .applied(mayHaveMutated: true, stableLocator: resolved)
                : .rejected(
                    .spreadNotLoaded,
                    mayHaveMutated: true,
                    stableLocator: resolved,
                    stage: .stableLocationRestore
                )
        } else if let restoreGo = pageTurnRestoreGoToIndexForTesting {
            mutation = await restoreGo(resolved)
                ? .applied(mayHaveMutated: true, stableLocator: resolved)
                : .rejected(
                    .spreadNotLoaded,
                    mayHaveMutated: true,
                    stableLocator: resolved,
                    stage: .stableLocationRestore
                )
        } else {
            guard
                let paginationView,
                let resourceIndex = readingOrder.firstIndexWithHREF(locator.href),
                let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex)
            else {
                return .rejected(
                    .spreadNotLoaded,
                    mayHaveMutated: false,
                    stableLocator: resolved,
                    stage: .stableLocationRestore
                )
            }
            mutation = await (paginationView.goToIndexWithMutation(
                spreadIndex,
                location: .locator(resolved),
                options: .none,
                waitForLoad: true,
                operation: operation
            )).preservingStableLocator(resolved)
        }
        guard mutation.result.isApplied else { return mutation }
        if let result = operation.check() {
            return .rejected(
                result,
                mayHaveMutated: mutation.mayHaveMutated,
                stableLocator: mutation.stableLocator ?? resolved,
                stage: .stableLocationRestore
            )
        }
        let verified = await isLiveViewAtPageTurnOriginalLocator(
            resolved,
            operation: operation
        )
        guard verified else {
            return .rejected(
                operation.check() ?? .spreadNotLoaded,
                mayHaveMutated: mutation.mayHaveMutated,
                stableLocator: mutation.stableLocator ?? resolved,
                stage: .stableLocationRestore
            )
        }
        return mutation.verifiedStableLocation()
    }

    /// Prefer an explicit progression; otherwise map `locations.position` to
    /// the matching entry in `positionsByReadingOrder`.
    private func resolvePageTurnLocatorForRestore(_ locator: Locator) -> Locator {
        resolveLocatorProgression(locator) ?? locator
    }

    /// Fills in progression from `positionsByReadingOrder` when the locator
    /// has a position but no progression. Pure position locators return `nil`
    /// when they cannot be mapped. Locators that already have a precise DOM
    /// target keep the original locator so navigation can still proceed.
    func resolveLocatorProgression(_ locator: Locator) -> Locator? {
        if locator.locations.progression != nil {
            return locator
        }
        guard locator.locations.position != nil else {
            return locator
        }
        if locatorHasPreciseDOMTarget(locator) {
            return locator
        }
        if
            let expectedPosition = locator.locations.position,
            let resourceIndex = readingOrder.firstIndexWithHREF(locator.href),
            let positions = positionsByReadingOrder.getOrNil(resourceIndex),
            let match = positions.first(where: { $0.locations.position == expectedPosition }),
            let progression = match.locations.progression
        {
            return locator.copy { locations in
                locations.progression = progression
            }
        }
        return nil
    }

    private func locatorHasPreciseDOMTarget(_ locator: Locator) -> Bool {
        locator.text.highlight != nil
            || !locator.locations.fragments.isEmpty
            || locator.locations.cssSelector != nil
            || locator.locations.domRange != nil
    }

    private func runPageTurn(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        let beginning = await beginPageTurn(to: direction, operation: operation)
        guard case let .applied(session) = beginning else {
            return .rejected(
                beginning.result,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        guard !Task.isCancelled else {
            finishPageTurn(session)
            return .rejected(
                .cancelled,
                mayHaveMutated: false,
                stage: .preflight
            )
        }

        return await commitPageTurn(
            session,
            options: options,
            operation: operation
        )
    }

    private func turnWithPageSurface(
        to direction: EPUBSpreadView.Direction,
        style: EPUBPageTurnStyle,
        target: Locator? = nil,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        let beginning = await beginPageTurn(to: direction, operation: operation)
        guard case let .applied(session) = beginning else {
            return .rejected(
                beginning.result,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        guard !Task.isCancelled else {
            finishPageTurn(session)
            return .rejected(
                .cancelled,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        let transaction = PageTurnTransaction(
            session: session,
            style: style,
            target: target
        )
        pageTurnTransaction = transaction
        transaction.start()
        // Discrete path: user intent is already a full page turn. Resolve
        // commit before prepare so a failed surface overlay still navigates.
        transaction.didResolveCommitBeforePrepare = true
        transaction.resolve(.commit)
        return await Self.runPageTurnTransaction(
            transaction,
            operation: operation
        ) { self }
    }

    private func pageTurnRootView(for style: EPUBPageTurnStyle) -> UIView? {
        guard style == .simulation else {
            return delegate?.pageTurnRootView(for: self)
        }
        guard
            let container = delegate?.pageTurnContainerViewController(for: self),
            let liveSurface = delegate?.pageTurnLiveSurfaceViewController(for: self),
            container === liveSurface,
            let containerView = container.viewIfLoaded,
            view.isDescendant(of: containerView)
        else {
            return nil
        }
        return containerView
    }

    private func installPageTurnSurface(
        _ session: PageTurnSession,
        style: EPUBPageTurnStyle
    ) async -> Bool {
        // A previous hard-failure / selection-interrupt path may have left an
        // orphan surface (any style). Never block the next turn on it — and do
        // not require the controller to already be idle (stuck half-page).
        if pageTurnSurfaceAnimator != nil {
            if pageTurnTransaction?.isRunning == true {
                return false
            }
            hardAbortInFlightPageTurn(
                restorePreparedLocation: false,
                reason: "install-orphan-animator"
            )
        }
        for _ in 0 ..< 3 {
            guard !Task.isCancelled else { return false }
            isInstallingPageTurnSurface = true
            let animator = EPUBPageTurnSurfaceAnimator(
                rootViewProvider: { [weak self] in
                    guard let self else { return nil }
                    return self.pageTurnRootView(for: style)
                },
                documentView: view,
                style: style,
                physicalCompletionDirection: session.physicalCompletionDirection,
                isForward: session.isForward
            )
            isInstallingPageTurnSurface = false
            if let animator {
                pageTurnSurfaceAnimator = animator
                pageTurnSurfaceDidPrepareTarget = false
                pageTurnSurfaceOriginalPreview = nil
                pageTurnSurfaceTargetPreview = nil
                return true
            }
            await waitForPageTurnDisplayFrame()
        }
        return false
    }

    /// Drops a retained snapshot when no live transaction owns it.
    private func forceReleaseOrphanPageTurnSurface() {
        pageTurnSurfaceAnimator?.remove()
        pageTurnSurfaceAnimator = nil
        pageTurnSurfaceOriginalPreview = nil
        pageTurnSurfaceTargetPreview = nil
        coldPageTurnTargetIndexForTesting = nil
        isColdPageTurnArmedForTesting = false
    }

    private func pageTurnPreviewCalculation() -> (
        () async -> (Locator?, NavigatorViewport?)
    ) {
        pageTurnPreviewCalculationForTesting
            ?? currentLocationCalculation()
    }

    private static func waitForPageTurnPreview(
        calculating: @escaping () async -> (Locator?, NavigatorViewport?),
        displayFrameWaiter: (() async -> Void)?,
        operation: NavigationOperationToken,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) async -> PageTurnPreview? {
        for _ in 0 ..< 60 {
            guard !isCancelled(), operation.check() == nil else { return nil }
            let calculation = await NavigationOperationWaiter<(
                Locator?, NavigatorViewport?
            )>().wait(
                operation: operation,
                work: calculating
            )
            guard case let .applied(result) = calculation else { return nil }
            guard !isCancelled(), operation.check() == nil else { return nil }
            if let location = result.0, let viewport = result.1 {
                return PageTurnPreview(location: location, viewport: viewport)
            }
            let frame = await NavigationOperationWaiter<Void>().wait(
                operation: operation,
                work: { await waitForPageTurnDisplayFrame(displayFrameWaiter) }
            )
            guard frame.result.isApplied else { return nil }
        }
        return nil
    }

    private static func waitForPageTurnDisplayFrame(
        _ displayFrameWaiter: (() async -> Void)?
    ) async {
        if let displayFrameWaiter {
            await displayFrameWaiter()
        } else {
            await PageTurnAnimationFrameWaiter.wait()
        }
    }

    private func waitForPageTurnDisplayFrame() async {
        guard isActive else {
            await Task.yield()
            return
        }
        if let pageTurnDisplayFrameWaiterForTesting {
            await pageTurnDisplayFrameWaiterForTesting()
            return
        }
        if let pageTurnDisplayFrameSchedulerForTesting {
            await PageTurnAnimationFrameWaiter.wait(
                scheduleDisplayFrame: pageTurnDisplayFrameSchedulerForTesting,
                registerWaiter: { self.pageTurnDisplayFrameWaiter = $0 }
            )
        } else {
            await PageTurnAnimationFrameWaiter.wait(
                registerWaiter: { self.pageTurnDisplayFrameWaiter = $0 }
            )
        }
        pageTurnDisplayFrameWaiter = nil
    }

    private func waitForPageTurnDisplayFrame(
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        if let result = operation.check() { return result }
        let cancellationTask = Task { @MainActor [weak self] in
            _ = await operation.waitForCancellation()
            self?.pageTurnDisplayFrameWaiter?.cancel()
            self?.pageTurnDisplayFrameWaiter = nil
        }
        await waitForPageTurnDisplayFrame()
        cancellationTask.cancel()
        return operation.check() ?? .applied
    }

    private func waitForPageTurnDisplayFrames() async {
        await waitForPageTurnDisplayFrame()
        await waitForPageTurnDisplayFrame()
    }

    private func waitForPageTurnDisplayFrames(
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        let first = await waitForPageTurnDisplayFrame(operation: operation)
        guard first.isApplied else { return first }
        return await waitForPageTurnDisplayFrame(operation: operation)
    }

    private static func waitForPageTurnDisplayFrames(
        _ displayFrameWaiter: (() async -> Void)?
    ) async {
        await waitForPageTurnDisplayFrame(displayFrameWaiter)
        await waitForPageTurnDisplayFrame(displayFrameWaiter)
    }

    private func startPageTurnTransaction(
        _ transaction: PageTurnTransaction
    ) {
        guard
            pageTurnTransaction === transaction,
            !transaction.isRunning
        else {
            return
        }
        transaction.start()
        let relativeDirection: NavigationRelativeDirection =
            transaction.session.direction == .left ? .backward : .forward
        let executor = navigationExecutor
        let timeout = navigationOperationTimeout
        let owner = WeakNavigationOwner(self)
        pageTurnTransactionTask = Task { @MainActor [owner, transaction] in
            let result = await executor.submit(
                intent: .relative(relativeDirection),
                timeout: timeout
            ) { [owner, transaction] operation in
                let stableLocator = owner.value?.currentLocation
                let mutation = await Self.runPageTurnTransaction(
                    transaction,
                    operation: operation
                ) {
                    owner.value
                }
                let terminalMutation = operation.check().map {
                    mutation.replacingResult(
                        $0,
                        stableLocator: mutation.stableLocator ?? stableLocator,
                        failureStage: mutation.failureStage ?? .pageViewMutation
                    )
                } ?? mutation
                guard let navigator = owner.value else {
                    return terminalMutation.result
                }
                return await navigator.finalizeNavigationMutation(
                    terminalMutation,
                    stableLocator: stableLocator,
                    operation: operation
                )
            }
            return result.isApplied
        }
    }

    private static func runPageTurnTransaction(
        _ transaction: PageTurnTransaction,
        operation: NavigationOperationToken,
        navigator: @escaping @MainActor () -> EPUBNavigatorViewController?
    ) async -> NavigationMutationResult {
        if Task.isCancelled {
            transaction.resolve(.cancel)
        }
        let prepared: Bool
        if transaction.terminalIntent == .cancel {
            // Preserve a diagnostic when cancel won before prepare could run.
            if navigator()?.pageTurnLastPrepareFailureForTesting == nil {
                navigator()?.pageTurnLastPrepareFailureForTesting =
                    "terminal-cancel-before-prepare"
            }
            prepared = false
        } else if transaction.style == .none {
            prepared = true
        } else {
            prepared = await preparePageTurnSurface(
                transaction,
                operation: operation,
                navigator: navigator
            )
        }
        transaction.preparationState = prepared ? .ready : .failed
        if Task.isCancelled {
            transaction.resolve(.cancel)
        }
        guard let intent = await transaction.waitForTerminalIntent(
            operation: operation
        ) else {
            let result = transaction.mutationResult.replacingResult(
                operation.check() ?? .cancelled,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .preflight
            )
            transaction.complete(with: result)
            return result
        }
        guard
            let owner = navigator(),
            owner.pageTurnTransaction === transaction
        else {
            let result = transaction.mutationResult.replacingResult(
                operation.check() ?? .cancelled,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .preflight
            )
            transaction.complete(with: result)
            return result
        }
        let result: NavigationMutationResult
        if transaction.style == .none {
            if intent == .commit {
                result = await owner.commitPageTurn(
                    transaction.session,
                    options: .none,
                    operation: operation
                )
            } else {
                owner.finishPageTurn(transaction.session)
                result = transaction.mutationResult.replacingResult(
                    .cancelled,
                    stableLocator: transaction.mutationResult.stableLocator
                        ?? transaction.originalLocator,
                    failureStage: .preflight
                )
            }
        } else if intent == .commit, transaction.isPrepared {
            result = await owner.commitPageTurnSurface(
                transaction,
                progress: transaction.progress,
                operation: operation
            )
        } else if intent == .commit {
            // Committed intent with a failed surface prepare (interactive pan,
            // discrete tap, resumed reverse, missing/default nil root, capture
            // failure mid-prepare). Always degrade to instant navigation rather
            // than cancel-restore and swallow the page turn.
            result = await owner.commitPageTurnAfterFailedSurfacePrepare(
                transaction,
                operation: operation
            )
        } else {
            var stableVerified = false
            await owner.runPageTurnRecovery(
                for: transaction,
                operation: operation
            ) { owner, transaction, generation in
                let restored = await owner.restorePageTurnSurface(
                    transaction.session,
                    recoveryTransaction: transaction,
                    recoveryGeneration: generation,
                    operation: operation
                )
                guard owner.isCurrentPageTurnRecovery(
                    transaction,
                    generation: generation
                ) else {
                    return
                }
                if restored {
                    stableVerified = true
                } else {
                    stableVerified = await owner.releaseFailedPageTurnRestore(
                        transaction.session,
                        operation: operation
                    )
                }
            }
            let rejected = NavigationMutationResult.rejected(
                operation.check() ?? .cancelled,
                mayHaveMutated: transaction.mutationResult.mayHaveMutated,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                stage: .stableLocationRestore
            )
            result = stableVerified
                ? rejected.verifiedStableLocation()
                : rejected
        }

        transaction.complete(with: result)
        guard owner.pageTurnTransaction === transaction else {
            owner.finishPageTurnRecovery(for: transaction)
            return result
        }
        // Always detach this transaction and attempt pending reverse resume.
        // Do not require isIdle first: a failed restore can leave the controller
        // non-idle, which previously skipped resume and dropped the reverse.
        if owner.pageTurnTransaction === transaction {
            owner.pageTurnTransactionTask = nil
            owner.pageTurnTransaction = nil
        }
        if owner.pageTurnTransaction == nil, owner.pageTurnSurfaceAnimator != nil {
            owner.forceReleaseOrphanPageTurnSurface()
        }
        if !owner.pageTurnController.isIdle,
           let stranded = owner.pageTurnController.activeSession
        {
            owner.finishPageTurn(stranded)
        }
        owner.releasePageTurnNavigatorNavigationLock()
        owner.applyDeferredPageTurnInteractionMode()
        owner.finishPageTurnRecovery(for: transaction)
        await owner.resumePendingPageTurnGesture()
        return result
    }

    private static func isPageTurnPrepareActive(
        _ transaction: PageTurnTransaction
    ) -> Bool {
        !Task.isCancelled && !transaction.isPrepareCancelled
    }

    /// Keeps a strong navigator reference scoped to surface installation. A
    /// task which later waits on navigation/WebKit/test gates must only retain
    /// the weak provider closure so deinit can cancel that task.
    private static func installPageTurnSurface(
        _ transaction: PageTurnTransaction,
        navigator: @escaping @MainActor () -> EPUBNavigatorViewController?
    ) async -> Bool {
        guard let owner = navigator() else { return false }
        var style = transaction.style
        var didInstall = await owner.installPageTurnSurface(
            transaction.session,
            style: style
        )
        if !didInstall, style == .simulation, isPageTurnPrepareActive(transaction) {
            style = .push
            didInstall = await owner.installPageTurnSurface(
                transaction.session,
                style: style
            )
            if didInstall {
                transaction.style = .push
            } else if isPageTurnPrepareActive(transaction) {
                transaction.style = .none
                owner.forceReleaseOrphanPageTurnSurface()
                return true
            }
        }
        return didInstall
            && owner.pageTurnTransaction === transaction
            && owner.pageTurnController.isTracking(transaction.session)
            && isPageTurnPrepareActive(transaction)
    }

    private static func preparePageTurnSurface(
        _ transaction: PageTurnTransaction,
        operation: NavigationOperationToken,
        navigator: @escaping @MainActor () -> EPUBNavigatorViewController?
    ) async -> Bool {
        let session = transaction.session
        navigator()?.isPreparingPageTurnSurface = true
        defer { navigator()?.isPreparingPageTurnSurface = false }
        func fail(_ stage: String) -> Bool {
            navigator()?.pageTurnLastPrepareFailureForTesting = stage
            return false
        }
        if Task.isCancelled {
            return fail("task-cancelled-before-prepare")
        }
        guard
            isPageTurnPrepareActive(transaction),
            navigator()?.pageTurnTransaction === transaction,
            navigator()?.pageTurnController.isTracking(session) == true
        else {
            return fail("precondition")
        }
        let installed = await installPageTurnSurface(
            transaction,
            navigator: navigator
        )
        guard installed else {
            return fail("install")
        }
        guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-after-install") }
        guard navigator()?.pageTurnSurfaceAnimator?.hasMatchingCurrentRootIdentity == true
            || navigator()?.pageTurnSurfaceAnimator?.recaptureCurrent() == true
        else {
            return fail("current-identity")
        }
        guard
            let originalCalculation = navigator()?.pageTurnPreviewCalculation(),
            let originalPreview = await waitForPageTurnPreview(
                calculating: originalCalculation,
                displayFrameWaiter: navigator()?.pageTurnDisplayFrameWaiterForTesting,
                operation: operation,
                isCancelled: { !isPageTurnPrepareActive(transaction) }
            )
        else {
            return fail("original-preview")
        }
        guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-after-original-preview") }
        navigator()?.pageTurnSurfaceOriginalPreview = originalPreview
        transaction.originalLocator = originalPreview.location
        transaction.didObserveSurface = navigator()?.pageTurnSurfaceAnimator?.hasMountedSurface == true
        guard let navigation = navigator()?.pageTurnNavigation(
            session,
            options: .none,
            target: transaction.target,
            operation: operation
        )
        else {
            return fail("navigation-missing")
        }
        if let coldTarget = navigator()?.coldPageTurnTargetIndexForTesting {
            navigator()?.didBeginWithColdTargetForTesting =
                navigator()?.paginationView?.loadedViews[coldTarget] == nil
        }
        let mutation = await navigation()
        transaction.mutationResult = mutation.preservingStableLocator(
            transaction.originalLocator
        )
        let moved = mutation.result.isApplied
        // Mark as soon as navigation succeeds so cancel landing between this
        // return and the guards below still triggers reverse restore.
        if moved {
            transaction.didPrepareTarget = true
        }
        // Keep pageTurnTransactionTask so cooperative cancel still works after
        // navigation (capture / preview / identity still run on this task).
        guard
            isPageTurnPrepareActive(transaction),
            navigator()?.pageTurnTransaction === transaction,
            moved,
            navigator()?.pageTurnController.isTracking(session) == true
        else {
            return fail(moved ? "cancelled-after-navigation" : "navigation-failed")
        }

        guard
            let targetCalculation = navigator()?.pageTurnPreviewCalculation(),
            var targetPreview = await waitForPageTurnPreview(
                calculating: targetCalculation,
                displayFrameWaiter: navigator()?.pageTurnDisplayFrameWaiterForTesting,
                operation: operation,
                isCancelled: { !isPageTurnPrepareActive(transaction) }
            )
        else {
            return fail("target-preview")
        }
        guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-after-target-preview") }
        if let coldTarget = navigator()?.coldPageTurnTargetIndexForTesting {
            navigator()?.didNavigateColdTargetForTesting =
                navigator()?.didBeginWithColdTargetForTesting == true
                    && navigator()?.paginationView?.currentIndex == coldTarget
                    && navigator()?.paginationView?.loadedViews[coldTarget] != nil
        }
        var isTargetPreviewStable = false
        for _ in 0 ..< 3 {
            guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-during-preview-stable") }
            guard publishPageTurnTargetPreview(
                targetPreview,
                transaction: transaction,
                navigator: navigator
            ) else {
                return fail("publish-target-preview")
            }
            await waitForPageTurnDisplayFrames(
                navigator()?.pageTurnDisplayFrameWaiterForTesting
            )
            guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-after-preview-frame") }
            guard
                let refreshedCalculation = navigator()?.pageTurnPreviewCalculation(),
                let refreshedPreview = await waitForPageTurnPreview(
                    calculating: refreshedCalculation,
                    displayFrameWaiter: navigator()?.pageTurnDisplayFrameWaiterForTesting,
                    operation: operation,
                    isCancelled: { !isPageTurnPrepareActive(transaction) }
                )
            else {
                return fail("refresh-target-preview")
            }
            if refreshedPreview == targetPreview {
                isTargetPreviewStable = true
                break
            }
            targetPreview = refreshedPreview
        }
        guard isTargetPreviewStable else { return fail("target-preview-unstable") }
        guard
            isPageTurnPrepareActive(transaction),
            navigator()?.pageTurnTransaction === transaction,
            navigator()?.pageTurnController.isTracking(session) == true,
            navigator()?.hasLostPageTurnSurface(transaction) == false
        else {
            return fail("pre-capture-guard")
        }
        guard navigator()?.capturePageTurnTargetSurface() == true else {
            return fail("capture-target")
        }
        if navigator()?.isColdPageTurnArmedForTesting == true {
            navigator()?.didCaptureAfterColdNavigationForTesting =
                navigator()?.didNavigateColdTargetForTesting == true
                    && navigator()?.pageTurnSurfaceAnimator?.hasTarget == true
        }
        await waitForPageTurnDisplayFrames(
            navigator()?.pageTurnDisplayFrameWaiterForTesting
        )
        guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-after-capture") }
        guard navigator()?.hasLostPageTurnSurface(
            navigator()?.pageTurnTransaction
        ) == false else {
            return fail("lost-surface-after-capture")
        }
        guard await matchPageTurnSurfaceIdentities(navigator: navigator) else {
            return fail("match-identities")
        }
        guard isPageTurnPrepareActive(transaction) else { return fail("cancelled-after-match") }
        navigator()?.pageTurnLastPrepareFailureForTesting = nil
        navigator()?.pageTurnSurfaceAnimator?.render(
            progress: transaction.progress
        )
        // Prepare finished: drop the opaque freeze so swipe tracking / discrete
        // animation can use the real turn surfaces. Live content remains under
        // current/target snapshots until cleanup.
        navigator()?.pageTurnSurfaceAnimator?.dismissPrepareShield()
        return true
    }

    private static func publishPageTurnTargetPreview(
        _ preview: PageTurnPreview,
        transaction: PageTurnTransaction,
        navigator: @escaping @MainActor () -> EPUBNavigatorViewController?
    ) -> Bool {
        guard
            isPageTurnPrepareActive(transaction),
            let owner = navigator(),
            owner.pageTurnTransaction === transaction
        else {
            return false
        }
        owner.pageTurnSurfaceTargetPreview = preview
        owner.delegate?.navigator(
            owner,
            previewLocationDidChange: preview.location,
            viewport: preview.viewport
        )
        return true
    }

    private func capturePageTurnTargetSurface() -> Bool {
        isInstallingPageTurnSurface = true
        defer { isInstallingPageTurnSurface = false }
        guard pageTurnSurfaceAnimator?.captureTarget() == true else {
            return false
        }
        pageTurnSurfaceAnimator?.render(progress: pageTurnSurfaceProgress)
        return true
    }

    private func matchPageTurnSurfaceIdentities() async -> Bool {
        guard let animator = pageTurnSurfaceAnimator else { return false }
        guard !hasLostPageTurnSurface(pageTurnTransaction) else { return false }
        guard animator.hasMatchingCurrentRootIdentity else { return false }
        for _ in 0 ..< 3 {
            guard !Task.isCancelled else { return false }
            guard !animator.hasMatchingTargetRootIdentity else { return true }
            guard animator.recaptureTarget() else { return false }
            await waitForPageTurnDisplayFrames()
            guard animator.hasMatchingCurrentRootIdentity else { return false }
        }
        return animator.hasMatchingTargetRootIdentity
    }

    private static func matchPageTurnSurfaceIdentities(
        navigator: @escaping @MainActor () -> EPUBNavigatorViewController?
    ) async -> Bool {
        guard navigator()?.hasLostPageTurnSurface(
            navigator()?.pageTurnTransaction
        ) == false else {
            return false
        }
        guard navigator()?.pageTurnSurfaceAnimator?.hasMatchingCurrentRootIdentity == true else {
            return false
        }
        for _ in 0 ..< 3 {
            guard !Task.isCancelled else { return false }
            guard navigator()?.pageTurnSurfaceAnimator?.hasMatchingTargetRootIdentity != true else {
                return true
            }
            guard navigator()?.pageTurnSurfaceAnimator?.recaptureTarget() == true else {
                return false
            }
            await waitForPageTurnDisplayFrames(
                navigator()?.pageTurnDisplayFrameWaiterForTesting
            )
            guard navigator()?.pageTurnSurfaceAnimator?.hasMatchingCurrentRootIdentity == true else {
                return false
            }
        }
        return navigator()?.pageTurnSurfaceAnimator?.hasMatchingTargetRootIdentity == true
    }

    private func matchCommittedPageTurnSurfaceIdentity() async -> Bool {
        guard let animator = pageTurnSurfaceAnimator else { return false }
        guard !hasLostPageTurnSurface(pageTurnTransaction) else { return false }
        for _ in 0 ..< 3 {
            guard !Task.isCancelled else { return false }
            guard !animator.hasMatchingTargetRootIdentity else { return true }
            guard animator.recaptureCommittedTarget() else { return false }
            await waitForPageTurnDisplayFrames()
        }
        return animator.hasMatchingTargetRootIdentity
    }

    private func commitPageTurnSurface(
        _ transaction: PageTurnTransaction,
        progress: CGFloat,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        let session = transaction.session
        guard let animator = pageTurnSurfaceAnimator else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: transaction.mutationResult.mayHaveMutated,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                stage: .publication
            )
        }
        pageTurnWillValidateCommitForTesting?()
        guard await matchPageTurnSurfaceIdentities() else {
            _ = await cancelPageTurnSurface(session, operation: operation)
            return .rejected(
                operation.check() ?? .spreadNotLoaded,
                mayHaveMutated: transaction.mutationResult.mayHaveMutated,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                stage: .stableLocationRestore
            )
        }
        guard
            pageTurnTransaction === transaction,
            !transaction.isInvalidated,
            transaction.terminalIntent == .commit,
            pageTurnController.isTracking(session)
        else {
            _ = await cancelPageTurnSurface(session, operation: operation)
            return .rejected(
                operation.check() ?? .cancelled,
                mayHaveMutated: transaction.mutationResult.mayHaveMutated,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                stage: .stableLocationRestore
            )
        }
        let remaining = 1 - min(max(progress, 0), 1)
        let committed = await pageTurnController.commit(session) { [self] in
            var canCleanup = false
            defer {
                if canCleanup {
                    cleanupPageTurnSurface(session)
                }
                finishPageTurn(session)
            }
            let didAnimate = await animator.animate(
                to: 1,
                duration: 0.32 * remaining,
                scheduleDisplayFrame: pageTurnDisplayFrameSchedulerForTesting,
                shouldContinue: { !transaction.isInvalidated }
            )
            guard didAnimate, !transaction.isInvalidated else {
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                // Always release the surface after a failed commit so the next
                // turn is not blocked by an orphan animator.
                canCleanup = true
                return false
            }
            await waitForPageTurnDisplayFrames()
            guard !transaction.isInvalidated else {
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                canCleanup = true
                return false
            }
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Page-turn surface identity changed after commit; recovering then releasing the surface.")
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                canCleanup = true
                return false
            }
            guard let targetPreview = pageTurnSurfaceTargetPreview else {
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                canCleanup = true
                return false
            }
            delegate?.navigator(
                self,
                previewLocationDidChange: targetPreview.location,
                viewport: targetPreview.viewport
            )
            await waitForPageTurnDisplayFrames()
            guard !transaction.isInvalidated else {
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                canCleanup = true
                return false
            }
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Page-turn surface identity changed before publication; recovering then releasing the surface.")
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                canCleanup = true
                return false
            }
            guard
                pageTurnTransaction === transaction,
                !transaction.isInvalidated,
                transaction.terminalIntent == .commit
            else {
                _ = await recoverOriginalPageTurnAfterCommitFailure(
                    animator,
                    operation: operation
                )
                canCleanup = true
                return false
            }
            if pageTurnSurfaceTargetLocator == nil {
                let published = await publishPageTurnLocation(
                    transaction,
                    operation: operation
                )
                guard published else {
                    log(.error, "Failed to publish the committed page-turn location.")
                    _ = await recoverOriginalPageTurnAfterCommitFailure(
                        animator,
                        operation: operation
                    )
                    canCleanup = true
                    return false
                }
                // Publication is the final irreversible commit for a relative
                // surface turn. All frame and identity checks must happen
                // before it; a deadline firing during cosmetic cleanup cannot
                // negate a location notification which was already delivered.
                canCleanup = true
                return true
            }
            await waitForPageTurnDisplayFrames()
            if transaction.isInvalidated {
                canCleanup = true
                return true
            }
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                // Location is already published at the target. Drop the stale
                // snapshot so the session cannot stay half-dead with an
                // orphan animator that blocks the next install.
                log(.error, "Page-turn surface identity changed before cleanup; releasing the published target surface.")
                canCleanup = true
                return true
            }
            canCleanup = true
            return true
        }
        guard committed else {
            return .rejected(
                operation.check() ?? .spreadNotLoaded,
                mayHaveMutated: transaction.mutationResult.mayHaveMutated,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                stage: .stableLocationRestore
            )
        }
        return transaction.mutationResult
    }

    private func recoverOriginalPageTurnAfterCommitFailure(
        _ animator: EPUBPageTurnSurfaceAnimator,
        operation: NavigationOperationToken
    ) async -> Bool {
        guard
            let originalPreview = pageTurnSurfaceOriginalPreview,
            let originalLocator = pageTurnTransaction?.originalLocator
        else {
            failPageTurnRecovery(with: .spreadNotLoaded)
            return false
        }
        let restore = await restorePageTurnLocator(
            originalLocator,
            operation: operation
        )
        let restored = restore.result.isApplied && restore.stableVerified
            ? await isLiveViewAtPageTurnOriginalLocator(
                originalPreview.location,
                operation: operation
            )
            : false
        if !restored {
            guard await reloadPageTurnOriginalLocation(
                originalLocator,
                operation: operation
            ) else {
                failPageTurnRecovery(with: operation.check() ?? .spreadNotLoaded)
                return false
            }
        }
        delegate?.navigator(
            self,
            previewLocationDidChange: originalPreview.location,
            viewport: originalPreview.viewport
        )
        guard await waitForPageTurnDisplayFrames(operation: operation).isApplied else {
            failPageTurnRecovery(with: operation.check() ?? .cancelled)
            return false
        }
        animator.render(progress: 0)
        // Snapshot recapture is best-effort. Cancel/failure recovery already
        // restored the live page; callers cleanup the surface either way.
        // Requiring recapture fails hard in headless tests / unrendered roots
        // and blocks pending reverse gestures.
        _ = animator.recaptureCurrent()
        return true
    }

    private func restorePageTurnSurface(
        _ session: PageTurnSession,
        recoveryTransaction: PageTurnTransaction? = nil,
        recoveryGeneration: UInt64? = nil,
        operation: NavigationOperationToken
    ) async -> Bool {
        let recoveryIsCurrent: @MainActor () -> Bool = { [self] in
            guard
                let recoveryTransaction,
                let recoveryGeneration
            else {
                return true
            }
            return isCurrentPageTurnRecovery(
                recoveryTransaction,
                generation: recoveryGeneration
            )
        }
        guard recoveryIsCurrent() else { return false }
        let animator = pageTurnSurfaceAnimator
        return await pageTurnController.restoreCover(
            session,
            rebound: { [self] _ in
                guard recoveryIsCurrent() else { return false }
                _ = await animator?.animate(to: 0, duration: 0.18)
                guard recoveryIsCurrent() else { return false }
                var restored = true
                if pageTurnSurfaceDidPrepareTarget {
                    if let pageTurnPreparedPageRestoreForTesting {
                        restored = await pageTurnPreparedPageRestoreForTesting()
                        guard recoveryIsCurrent() else { return false }
                    } else {
                        let inverse = PageTurnSession(
                            direction: session.direction == .left ? .right : .left,
                            readingProgression: session.readingProgression
                        )
                        restored = await pageTurnController.restorePreparedPage(
                            inverse: { [self] in
                                guard recoveryIsCurrent() else { return false }
                                let result = await performPageTurn(
                                    inverse,
                                    options: .none,
                                    operation: operation
                                )
                                return recoveryIsCurrent() && result.result.isApplied
                            },
                            validateOriginalLocation: { [self] in
                                guard recoveryIsCurrent() else { return false }
                                let result = await isLiveViewAtPageTurnOriginalLocator(
                                    pageTurnSurfaceOriginalPreview?.location
                                        ?? pageTurnTransaction?.originalLocator,
                                    operation: operation
                                )
                                return recoveryIsCurrent() && result
                            },
                            originalLocation: { [self] in
                                guard recoveryIsCurrent() else { return false }
                                guard
                                    let originalLocation = pageTurnTransaction?.originalLocator
                                    ?? pageTurnSurfaceOriginalPreview?.location
                                else {
                                    return false
                                }
                                let result = await restorePageTurnLocator(
                                    originalLocation,
                                    operation: operation
                                )
                                return recoveryIsCurrent()
                                    && result.result.isApplied
                                    && result.stableVerified
                            }
                        )
                        guard recoveryIsCurrent() else { return false }
                    }
                    if !restored {
                        log(.error, "Failed to restore the original page-turn location.")
                    }
                }
                if restored, let originalPreview = pageTurnSurfaceOriginalPreview {
                    delegate?.navigator(
                        self,
                        previewLocationDidChange: originalPreview.location,
                        viewport: originalPreview.viewport
                    )
                    guard await waitForPageTurnDisplayFrames(operation: operation).isApplied else {
                        return false
                    }
                    guard recoveryIsCurrent() else { return false }
                } else if restored {
                    guard await waitForPageTurnDisplayFrames(operation: operation).isApplied else {
                        return false
                    }
                    guard recoveryIsCurrent() else { return false }
                }
                // Recapture is cosmetic for the cancel path: cleanup removes
                // the surface immediately after a successful rebound. Do not
                // fail location restore when snapshotView is unavailable.
                if restored {
                    _ = animator?.recaptureCurrent()
                }
                return restored
            },
            cleanup: { [self] in
                guard recoveryIsCurrent() else { return }
                cleanupPageTurnSurface(session)
            },
            finish: { [self] session in
                guard recoveryIsCurrent() else { return }
                finishPageTurn(session)
            }
        )
    }

    private func cancelPageTurnSurface(
        _ session: PageTurnSession,
        operation: NavigationOperationToken
    ) async -> Bool {
        operation.beginRecovery()
        let task = Task.detached { @MainActor in
            await Self.restoreCancelledPageTurn(
                self,
                session: session,
                operation: operation
            )
        }
        let recoveryTaskID = operation.registerRecoveryTask(task)
        await task.value
        operation.unregisterRecoveryTask(recoveryTaskID)
        return false
    }

    private static func restoreCancelledPageTurn(
        _ navigator: EPUBNavigatorViewController,
        session: PageTurnSession,
        operation: NavigationOperationToken
    ) async {
        if await !navigator.restorePageTurnSurface(
            session,
            operation: operation
        ) {
            _ = await navigator.releaseFailedPageTurnRestore(
                session,
                operation: operation
            )
        }
    }

    private struct PageTurnLiveGeometry: Equatable {
        let rootFrame: CGRect
        let rootBounds: CGRect
        let documentFrame: CGRect
        let contentOffset: CGPoint
    }

    private func waitForStablePageTurnLiveView(
        at location: Locator?,
        operation: NavigationOperationToken
    ) async -> Bool {
        guard let location else { return false }
        var previous: PageTurnLiveGeometry?
        for _ in 0 ..< 60 {
            guard await waitForPageTurnDisplayFrame(operation: operation).isApplied else {
                return false
            }
            let calculation = await NavigationOperationWaiter<(
                Locator?, NavigatorViewport?
            )>().wait(
                operation: operation,
                work: computeCurrentLocationAndViewport,
                onAbandon: { [weak self] result in
                    self?.failPageTurnRecovery(with: result)
                }
            )
            guard case let .applied((current, _)) = calculation else {
                return false
            }
            guard
                current?.href.isEquivalentTo(location.href) == true,
                current?.locations == location.locations
            else {
                previous = nil
                continue
            }
            guard let rootView = pageTurnRootView(
                for: pageTurnTransaction?.style ?? currentEffectivePageTurnStyle()
            ) else {
                return false
            }
            rootView.layoutIfNeeded()
            let geometry = PageTurnLiveGeometry(
                rootFrame: rootView.frame,
                rootBounds: rootView.bounds,
                documentFrame: view.convert(view.bounds, to: rootView),
                contentOffset: (paginationView?.currentView as? EPUBSpreadView)?
                    .scrollView.contentOffset ?? .zero
            )
            if geometry == previous {
                return true
            }
            previous = geometry
        }
        return false
    }

    private func cancelActivePageTurn(reason: String = "cancelActivePageTurn") {
        pendingPageTurnGesture = nil
        if pageTurnTransaction != nil || !pageTurnController.isIdle {
            // Always tag the latest cancel reason during an active turn.
            pageTurnLastPrepareFailureForTesting = reason
        }
        if pageTurnController.isCommitting {
            // Surface styles interrupt via cancelAnimation + isInvalidated;
            // `.none` interrupts via isInvalidated checks in commitPageTurn.
            guard let transaction = pageTurnTransaction else {
                return
            }
            transaction.invalidate()
            pageTurnSurfaceAnimator?.cancelAnimation()
            pageTurnDisplayFrameWaiter?.cancel()
            pageTurnDisplayFrameWaiter = nil
            return
        }
        guard let transaction = pageTurnTransaction else {
            if
                !pageTurnController.isIdle,
                let session = pageTurnController.activeSession,
                pageTurnSurfaceAnimator != nil
            {
                cleanupPageTurnSurface(session)
                finishPageTurn(session)
                return
            }
            guard
                let session = pageTurnController.activeSession,
                pageTurnController.invalidatePreCommitSession()?.id == session.id
            else {
                return
            }
            on(.moved)
            return
        }
        let session = transaction.session
        if
            transaction.style == .none,
            pageTurnSurfaceAnimator == nil,
            pageTurnController.invalidatePreCommitSession()?.id == session.id
        {
            transaction.resolve(.cancel)
            transaction.complete(with: transaction.mutationResult.replacingResult(
                .cancelled,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .preflight
            ))
            pageTurnTransactionTask?.cancel()
            pageTurnTransactionTask = nil
            pageTurnTransaction = nil
            applyDeferredPageTurnInteractionMode()
            on(.moved)
            return
        }
        transaction.resolve(.cancel)
        pageTurnTransactionTask?.cancel()
    }

    /// Hard-stop any in-flight page turn (simulation / cover / push / none).
    /// Soft `cancelActivePageTurn` alone can leave snapshot or curl surfaces
    /// mid-transform (half previous / half next) when selection UI interrupts.
    private func hardAbortInFlightPageTurn(
        restorePreparedLocation: Bool,
        reason: String = "hardAbort",
        snapDocuments: Bool = true
    ) {
        let originalLocator = pageTurnTransaction?.originalLocator
            ?? pageTurnSurfaceOriginalPreview?.location
        let needsLocationRestore = restorePreparedLocation
            && (
                pageTurnSurfaceDidPrepareTarget
                    || pageTurnTransaction?.didPrepareTarget == true
            )

        // Mandatory recovery must be visible to the executor before cancelling
        // the active transaction can let its operation release the lease.
        if needsLocationRestore, let originalLocator {
            queueHardAbortLocationRestore(
                originalLocator,
                snapAfterRestore: snapDocuments
            )
        } else if snapDocuments {
            // Snapping mutates pagination and spread offsets, so even a
            // restore-free hard abort must serialize it with user navigation.
            queueHardAbortLocationRestore(nil, snapAfterRestore: true)
        }

        cancelActivePageTurn(reason: reason)
        pageTurnDisplayFrameWaiter?.cancel()
        pageTurnDisplayFrameWaiter = nil
        let isDrainingRecovery = pageTurnRecoverySessionID != nil
        pageTurnRecoveryTask?.cancel()
        pageTurnTransactionTask?.cancel()
        if !isDrainingRecovery {
            pageTurnTransactionTask = nil
        }
        if let transaction = pageTurnTransaction {
            transaction.invalidate()
            transaction.resolve(.cancel)
            transaction.complete(with: transaction.mutationResult.replacingResult(
                .cancelled,
                stableLocator: transaction.mutationResult.stableLocator
                    ?? transaction.originalLocator,
                failureStage: .stableLocationRestore
            ))
            pageTurnTransaction = nil
        }
        // A recovery lease ends only when the old runner has actually
        // unwound. Ownership checks retire its state commits immediately, but
        // new navigation must keep waiting for the in-flight WebKit work.
        if isDrainingRecovery {
            poisonVisibleSpreads(with: .cancelled)
            pageTurnRecoveryGeneration &+= 1
        }
        pendingPageTurnGesture = nil
        pageTurnSurfaceAnimator?.cancelAnimation()
        // Covers push/cover snapshot pairs and simulation curl render views.
        forceReleaseOrphanPageTurnSurface()
        pageTurnSurfaceProgress = 0
        pageTurnSurfaceDidPrepareTarget = false
        if let session = pageTurnController.activeSession {
            _ = pageTurnController.finish(session)
        }
        releasePageTurnNavigatorNavigationLock()
        applyDeferredPageTurnInteractionMode()
    }

    private func poisonVisibleSpreads(with result: NavigationResult) {
        guard let loadedViews = paginationView?.loadedViews.values else { return }
        for view in loadedViews {
            (view as? EPUBSpreadView)?.poison(with: result)
        }
    }

    /// Replaces every poisoned WebView generation and restores the last
    /// published stable locator before the executor releases its lease.
    private func replacePoisonedPagination(
        stableLocator: Locator?,
        replacementLocator: Locator? = nil,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard let paginationView else { return .spreadNotLoaded }
        if deferredPoisonedPaginationReplacement == nil {
            let hasPoisonedView = paginationView.loadedViews.values.contains {
                ($0 as? EPUBSpreadView)?.isPoisoned == true
            }
            guard hasPoisonedView else { return .applied }
            deferredPoisonedPaginationReplacement = .init(
                stableLocator: stableLocator ?? currentLocation
            )
            paginationView.isolateForDeferredReload()
        }
        guard let deferred = deferredPoisonedPaginationReplacement else {
            return .applied
        }
        if let result = operation.check() { return result }

        let rawStableLocator = replacementLocator ?? deferred.stableLocator
        let locator = rawStableLocator.flatMap { resolveLocatorProgression($0) }
        if rawStableLocator != nil, locator == nil {
            paginationView.isolateForDeferredReload()
            pageTurnPoisonReloadLocatorForTesting = nil
            return .spreadNotLoaded
        }
        pageTurnPoisonReloadLocatorForTesting = locator
        let targetIndex: Int
        if
            let href = locator?.href,
            let resourceIndex = readingOrder.firstIndexWithHREF(href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex)
        {
            targetIndex = spreadIndex
        } else {
            targetIndex = min(currentSpreadIndex, max(0, spreads.count - 1))
        }
        operation.rebindPaginationGenerationForRecovery(paginationView.generation)
        let replacementMutation = await paginationView.goToIndexWithMutation(
            targetIndex,
            location: PageLocation(locator),
            options: .none,
            operation: operation
        )
        guard replacementMutation.result.isApplied else {
            paginationView.isolateForDeferredReload()
            return replacementMutation.result
        }
        guard
            let replacement = paginationView.loadedViews[targetIndex] as? EPUBSpreadView,
            !replacement.isPoisoned
        else {
            paginationView.isolateForDeferredReload()
            return .spreadNotLoaded
        }
        guard paginationView.currentIndex == targetIndex else {
            paginationView.isolateForDeferredReload()
            return .superseded
        }
        if let locator {
            let verified = await verifyLocatorNavigation(
                locator,
                moved: true,
                expectedSpreadIndex: targetIndex,
                operation: operation
            )
            guard verified.isApplied else {
                paginationView.isolateForDeferredReload()
                return verified
            }
        }
        if let result = operation.check() {
            paginationView.isolateForDeferredReload()
            return result
        }
        deferredPoisonedPaginationReplacement = nil
        return .applied
    }

    private func recoverPoisonedSpreadsIfNeeded(
        after result: NavigationResult,
        stableLocator: Locator?,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard deferredPoisonedPaginationReplacement != nil
            || paginationView?.loadedViews.values.contains(where: {
                ($0 as? EPUBSpreadView)?.isPoisoned == true
            }) == true
        else {
            return result
        }
        if deferredPoisonedPaginationReplacement == nil {
            deferredPoisonedPaginationReplacement = .init(
                stableLocator: stableLocator ?? currentLocation
            )
            paginationView?.isolateForDeferredReload()
        }
        operation.beginRecovery()
        let task = Task.detached { @MainActor [weak self] in
            guard let self else { return NavigationResult.cancelled }
            return await self.replacePoisonedPagination(
                stableLocator: stableLocator,
                operation: operation
            )
        }
        let recoveryTaskID = operation.registerRecoveryTask(task)
        let recovery = await task.value
        operation.unregisterRecoveryTask(recoveryTaskID)
        return recovery.isApplied ? result : recovery
    }

    private func recoverPoisonedSpreadsIfNeeded(
        after mutation: NavigationMutationResult,
        stableLocator: Locator?,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        let result = await recoverPoisonedSpreadsIfNeeded(
            after: mutation.result,
            stableLocator: mutation.stableLocator ?? stableLocator,
            operation: operation
        )
        guard result.isApplied else {
            return mutation.replacingResult(
                result,
                stableLocator: stableLocator,
                failureStage: mutation.failureStage ?? .settleRecovery
            )
        }
        return mutation
    }

    /// Closes the transaction only after a partial mutation has either restored
    /// and verified its stable locator or isolated the untrusted generation.
    private func finalizeNavigationMutation(
        _ mutation: NavigationMutationResult,
        stableLocator fallbackStableLocator: Locator?,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        let stableLocator = mutation.stableLocator ?? fallbackStableLocator
        if !mutation.result.isApplied,
           mutation.mayHaveMutated,
           !mutation.stableVerified
        {
            var restored = false
            if operation.check() == nil, let stableLocator {
                let restore = await restorePageTurnLocator(
                    stableLocator,
                    operation: operation
                )
                restored = restore.result.isApplied && restore.stableVerified
            }
            if !restored {
                poisonVisibleSpreads(with: mutation.result)
            }
        }
        return await recoverPoisonedSpreadsIfNeeded(
            after: mutation.result,
            stableLocator: stableLocator,
            operation: operation
        )
    }

    /// Retires a poisoned generation before the next user mutation. Running
    /// this only after that mutation could restore the old stable locator over
    /// a newly applied target while the public API still returned success.
    private func replacePoisonedPaginationIfNeeded(
        stableLocator: Locator?,
        replacementLocator: Locator? = nil,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard deferredPoisonedPaginationReplacement != nil
            || paginationView?.loadedViews.values.contains(where: {
                ($0 as? EPUBSpreadView)?.isPoisoned == true
            }) == true
        else {
            return .applied
        }
        operation.beginRecovery()
        return await replacePoisonedPagination(
            stableLocator: deferredPoisonedPaginationReplacement?.stableLocator
                ?? stableLocator,
            replacementLocator: replacementLocator,
            operation: operation
        )
    }

    private func abortPageTurnInterruptedBySelection(snapDocuments: Bool = true) {
        // Discrete edge taps often land on selectable text. WebKit can arm a
        // native selection on the same touch that started a commit-before-prepare
        // turn. Hard-aborting that turn swallows the deliberate page-turn input
        // (first-tap cancel / second-tap works). Keep preparing the discrete
        // turn; selection UI is cleared when the turn finishes if needed.
        if isPreparingPageTurnSurface,
           pageTurnTransaction?.didResolveCommitBeforePrepare == true
        {
            pageTurnLastPrepareFailureForTesting = "selection-ignored-during-discrete-prepare"
            return
        }
        hardAbortInFlightPageTurn(
            restorePreparedLocation: true,
            reason: "selection-interrupt",
            snapDocuments: snapDocuments
        )
        updatePageTurnInteractionMode()
    }

    /// Fixes half/half presentation after selection or a cancelled surface turn.
    /// Outer chrome stays full-width because it is outside the navigator; the
    /// split is almost always a mid-page `contentOffset` on the reflowable
    /// web scroll view (or outer pagination).
    private func snapVisibleDocumentToPageBoundaries() {
        pageTurnSnapDocumentCountForTesting += 1
        paginationView?.snapToNearestHorizontalPage()
        guard let loadedViews = paginationView?.loadedViews.values else { return }
        for view in loadedViews {
            (view as? EPUBSpreadView)?.snapToNearestHorizontalPage()
        }
    }

    /// Test seam: times `snapVisibleDocumentToPageBoundaries` ran (selection
    /// clear / hard-abort with snap, etc.).
    private(set) var pageTurnSnapDocumentCountForTesting = 0

    private var hasInFlightPageTurnWorkExcludingPendingGesture: Bool {
        pageTurnTransaction != nil
            || pageTurnRecoverySessionID != nil
            || !pageTurnController.isIdle
            || pageTurnSurfaceAnimator != nil
            || hardAbortLocationRestorePending
    }

    private var hasInFlightPageTurnWork: Bool {
        hasInFlightPageTurnWorkExcludingPendingGesture
            || pendingPageTurnGesture != nil
    }

    private func releaseFailedPageTurnRestore(
        _ session: PageTurnSession,
        operation: NavigationOperationToken
    ) async -> Bool {
        guard pageTurnController.isTracking(session) else { return false }
        if
            pageTurnSurfaceDidPrepareTarget,
            let animator = pageTurnSurfaceAnimator,
            await !recoverOriginalPageTurnAfterCommitFailure(
                animator,
                operation: operation
            )
        {
            // A real pagination failure is allowed to use the navigator's
            // existing loading/error path, but a transaction may never leave
            // input permanently captured behind a retained snapshot.
            cleanupPageTurnSurface(session)
            finishPageTurn(session, didMove: false)
            return false
        }
        guard await waitForPageTurnDisplayFrames(operation: operation).isApplied else {
            failPageTurnRecovery(with: operation.check() ?? .cancelled)
            return false
        }
        cleanupPageTurnSurface(session)
        finishPageTurn(session)
        return true
    }

    private func hasLostPageTurnSurface(
        _ transaction: PageTurnTransaction?
    ) -> Bool {
        transaction?.didObserveSurface == true
            && pageTurnSurfaceAnimator?.hasMountedSurface == false
    }

    private func reloadPageTurnOriginalLocation(
        _ locator: Locator,
        operation: NavigationOperationToken
    ) async -> Bool {
        guard let paginationView, on(.load(locator)) else { return false }
        spreads = EPUBSpread.makeSpreads(
            for: publication,
            readingOrder: readingOrder,
            readingProgression: viewModel.readingProgression,
            spread: viewModel.spreadEnabled,
            offsetFirstPage: viewModel.offsetFirstPage
        )
        guard
            let resourceIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex)
        else {
            return false
        }
        paginationView.reloadAtIndex(
            spreadIndex,
            location: .locator(locator),
            pageCount: spreads.count,
            readingProgression: viewModel.readingProgression
        )
        guard await waitForStablePageTurnLiveView(
            at: locator,
            operation: operation
        ) else {
            failPageTurnRecovery(with: operation.check() ?? .spreadNotLoaded)
            return false
        }
        return on(.loaded)
    }

    private func cleanupPageTurnSurface(_ session: PageTurnSession) {
        guard pageTurnController.activeSession?.id == session.id else { return }
        delegate?.navigator(
            self,
            previewLocationDidChange: nil,
            viewport: nil
        )
        pageTurnSurfaceAnimator?.remove()
        pageTurnSurfaceAnimator = nil
        pageTurnSurfaceProgress = 0
        pageTurnSurfaceDidPrepareTarget = false
        pageTurnSurfaceOriginalPreview = nil
        pageTurnSurfaceTargetPreview = nil
        coldPageTurnTargetIndexForTesting = nil
        isColdPageTurnArmedForTesting = false
    }

    private func goUsingExistingPath(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        guard
            let paginationView,
            on(.move(direction))
        else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: false,
                stage: .preflight
            )
        }

        if let spreadView = paginationView.currentView as? EPUBSpreadView {
            let withinSpread = await spreadView.go(
                to: direction,
                options: options,
                operation: operation
            )
            if withinSpread.result.isApplied || withinSpread.mayHaveMutated {
                on(.moved)
                return withinSpread
            }
        }

        let isRTL = (viewModel.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        let mutation: NavigationMutationResult = await {
            switch direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndexWithMutation(
                    currentSpreadIndex - delta,
                    location: location,
                    options: options,
                    operation: operation
                )
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndexWithMutation(
                    currentSpreadIndex + delta,
                    location: location,
                    options: options,
                    operation: operation
                )
            }
        }()

        on(.moved)
        return mutation
    }

    /// Goes to the next or previous page in the given scroll direction.
    private func go(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions
    ) async -> Bool {
        invalidateCurrentLocationRefresh()
        let relativeDirection: NavigationRelativeDirection = direction == .left
            ? .backward
            : .forward
        let result = await navigationExecutor.submit(
            intent: .relative(relativeDirection),
            timeout: navigationOperationTimeout
        ) { [weak self] operation in
            guard let self else { return .cancelled }
            let stableLocator = currentLocation
            let mutation = await performRelativeNavigation(
                to: direction,
                options: options,
                operation: operation
            )
            return await finalizeNavigationMutation(
                mutation,
                stableLocator: stableLocator,
                operation: operation
            )
        }
        return result.isApplied
    }

    private func performRelativeNavigation(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        let stableLocator = currentLocation
        if let result = operation.check() {
            return .rejected(
                result,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .preflight
            )
        }
        let snapshotSettle = await snapshotProvider.settleCapture(operation: operation)
        guard snapshotSettle.isApplied else {
            return .rejected(
                snapshotSettle,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .settleRecovery
            )
        }
        let recovery = await replacePoisonedPaginationIfNeeded(
            stableLocator: currentLocation,
            operation: operation
        )
        guard recovery.isApplied else {
            return .rejected(
                recovery,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .stableLocationRestore
            )
        }
        if let result = operation.check() {
            return .rejected(
                result,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .preflight
            )
        }
        let accessibilityStatus = accessibilityStatusProvider()
        let style = effectivePageTurnStyle(
            userStyle: pageTurnStyle,
            isReduceMotionEnabled: accessibilityStatus.isReduceMotionEnabled,
            isVoiceOverRunning: accessibilityStatus.isVoiceOverRunning
        )
        snapshotProvider.invalidate()
        let mutation = await routePageTurn(
            to: direction,
            options: options,
            axis: paginationView?.axis,
            isReduceMotionEnabled: accessibilityStatus.isReduceMotionEnabled,
            isVoiceOverRunning: accessibilityStatus.isVoiceOverRunning,
            usingExistingPath: { [self] direction, options in
                await goUsingExistingPath(
                    to: direction,
                    options: options,
                    operation: operation
                )
            },
            usingPageTurn: { [self] direction, options in
                if style == .none {
                    return await turnWithPageSurface(
                        to: direction,
                        style: .none,
                        operation: operation
                    )
                }
                if style == .simulation, options.animated {
                    return await turnWithPageSurface(
                        to: direction,
                        style: .simulation,
                        operation: operation
                    )
                }
                if style == .push, options.animated {
                    return await turnWithPageSurface(
                        to: direction,
                        style: .push,
                        operation: operation
                    )
                }
                return await runPageTurn(
                    to: direction,
                    options: options,
                    operation: operation
                )
            },
            usingCover: { [self] direction, options in
                if options.animated {
                    return await turnWithPageSurface(
                        to: direction,
                        style: .cover,
                        operation: operation
                    )
                }
                return await runPageTurn(
                    to: direction,
                    options: options,
                    operation: operation
                )
            }
        )
        if let result = operation.check() {
            return mutation.replacingResult(
                result,
                stableLocator: stableLocator,
                failureStage: mutation.failureStage ?? .pageViewMutation
            )
        }
        return mutation.preservingStableLocator(stableLocator)
    }

    func routePageTurn<Result>(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        axis: PaginationView.Axis?,
        isReduceMotionEnabled: Bool,
        isVoiceOverRunning: Bool,
        usingExistingPath: (EPUBSpreadView.Direction, NavigatorGoOptions) async -> Result,
        usingPageTurn: (EPUBSpreadView.Direction, NavigatorGoOptions) async -> Result,
        usingCover: (EPUBSpreadView.Direction, NavigatorGoOptions) async -> Result
    ) async -> Result {
        var routedOptions = options
        if isReduceMotionEnabled || isVoiceOverRunning {
            routedOptions.animated = false
        }

        guard axis == .horizontalPaged else {
            return await usingExistingPath(direction, routedOptions)
        }

        let style = effectivePageTurnStyle(
            userStyle: pageTurnStyle,
            isReduceMotionEnabled: isReduceMotionEnabled,
            isVoiceOverRunning: isVoiceOverRunning
        )
        switch style {
        case .push:
            return await usingPageTurn(direction, routedOptions)
        case .simulation:
            return await usingPageTurn(direction, routedOptions)
        case .none:
            return await usingPageTurn(direction, .none)
        case .cover:
            return await usingCover(direction, routedOptions)
        }
    }

    // MARK: - Pagination and spreads

    private struct PendingPaginationTransition {
        let oldPaginationView: PaginationView
        let replacementPaginationView: PaginationView
        let oldSpreads: [EPUBSpread]
        let previousPreferences: EPUBPreferences
    }

    private var paginationView: PaginationView?
    private var pendingPaginationTransition: PendingPaginationTransition?
    private var paginationRollbackPreferences: EPUBPreferences?
    private var isPaginationPreferenceTransitionActive = false
    private var queuedPaginationPreferences: EPUBPreferences?
    private var viewportPropagationTask: Task<Void, Never>?
    private var pendingSnapshotViewSize: CGSize?
    private var needsSnapshotPaginationInvalidation = false
    private var needsSnapshotReload = false
    private var pendingSnapshotPaginationCompletion: PaginationView?
    private var pendingSnapshotPaginationRollback: (paginationView: PaginationView, index: Int)?
    private var isDrainingSnapshotMutations = false

    private var pendingReplacementPaginationView: PaginationView? {
        pendingPaginationTransition?.replacementPaginationView
    }

    private var paginationAxis: PaginationView.Axis {
        if
            settings.scroll,
            !settings.verticalText,
            publication.metadata.layout == .reflowable
        {
            return .verticalContinuous
        }
        return .horizontalPaged
    }

    private func makePaginationView(hasPositions: Bool) -> PaginationView {
        let axis = paginationAxis
        let view = PaginationView(
            frame: .zero,
            preloadPreviousPositionCount: hasPositions ? config.preloadPreviousPositionCount : 0,
            preloadNextPositionCount: hasPositions ? config.preloadNextPositionCount : 0,
            isScrollEnabled: isPaginationViewScrollingEnabled(for: axis),
            axis: axis
        )
        view.allowsNativeHorizontalPaging = pageTurnInteractionPolicy(for: axis)
            .allowsNativeHorizontalPaging
        view.delegate = self
        view.backgroundColor = .clear
        return view
    }

    private func invalidatePaginationView() {
        snapshotProvider.invalidate()
        needsSnapshotPaginationInvalidation = true
        scheduleSnapshotMutationDrain()
    }

    private func invalidatePaginationViewAfterSnapshotCapture() {
        guard let oldPaginationView = paginationView else {
            return
        }

        if oldPaginationView.axis != paginationAxis {
            viewportPropagationTask?.cancel()
            viewportPropagationTask = nil
            oldPaginationView.isUserInteractionEnabled = false

            let replacement = makePaginationView(
                hasPositions: !positionsByReadingOrder.isEmpty
            )
            replacement.frame = oldPaginationView.frame
            replacement.autoresizingMask = oldPaginationView.autoresizingMask
            replacement.isUserInteractionEnabled = false
            view.insertSubview(replacement, aboveSubview: oldPaginationView)
            paginationView = replacement
            pendingPaginationTransition = PendingPaginationTransition(
                oldPaginationView: oldPaginationView,
                replacementPaginationView: replacement,
                oldSpreads: spreads,
                previousPreferences: paginationRollbackPreferences
                    ?? viewModel.preferences
            )
            paginationRollbackPreferences = nil
            updatePaginationContentInset()
        }

        if let paginationView {
            paginationView.isScrollEnabled = isPaginationViewScrollingEnabled(for: paginationView.axis)
            updatePageTurnInteractionMode()
        }
        reloadSpreadsAfterSnapshotCapture()
    }

    private var spreads: [EPUBSpread] = []

    /// Index of the currently visible spread.
    private var currentSpreadIndex: Int {
        paginationView?.currentIndex ?? 0
    }

    private var needsReloadSpreadsOnActive = false
    private var scheduledReloadMutationTask: Task<Void, Never>?

    private func reloadSpreads() {
        snapshotProvider.invalidate()
        needsSnapshotReload = true
        scheduleSnapshotMutationDrain()
    }

    private func reloadSpreadsAfterSnapshotCapture() {
        guard
            state != .initializing,
            isViewLoaded
        else {
            return
        }

        guard isActive else {
            // If we reload the spreads while the app is in the background, the
            // web view will reset to progression 0 instead of the current one.
            // We need to wait for the application to return to the foreground
            // to maintain the current location.
            needsReloadSpreadsOnActive = true
            return
        }

        scheduleExecutorReload(reason: "spread-reload")
    }

    private func scheduleExecutorReload(reason: String) {
        scheduledReloadMutationTask?.cancel()
        scheduledReloadMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stableLocator = currentLocation
            _ = await navigationExecutor.submit(
                intent: .reload(reason),
                timeout: navigationOperationTimeout
            ) { [weak self] operation in
                guard let self else { return .cancelled }
                if let result = operation.check() { return result }
                _reloadSpreads()
                guard let paginationView else { return .spreadNotLoaded }
                let targetIndex = currentSpreadIndex
                while paginationView.loadedViews[targetIndex] == nil {
                    if let result = operation.check() {
                        poisonVisibleSpreads(with: result)
                        return await recoverPoisonedSpreadsIfNeeded(
                            after: result,
                            stableLocator: stableLocator,
                            operation: operation
                        )
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return .applied
            }
        }
    }

    private func _reloadSpreads() {
        let locator = currentLocation

        guard
            let paginationView = paginationView,
            on(.load(locator))
        else {
            return
        }

        spreads = EPUBSpread.makeSpreads(
            for: publication,
            readingOrder: readingOrder,
            readingProgression: viewModel.readingProgression,
            spread: viewModel.spreadEnabled,
            offsetFirstPage: viewModel.offsetFirstPage
        )

        let initialIndex: ReadingOrder.Index = {
            if
                let href = locator?.href,
                let index = readingOrder.firstIndexWithHREF(href),
                let foundIndex = self.spreads.firstIndexWithReadingOrderIndex(index)
            {
                return foundIndex
            } else {
                return 0
            }
        }()

        paginationView.reloadAtIndex(
            initialIndex,
            location: PageLocation(locator),
            pageCount: spreads.count,
            readingProgression: viewModel.readingProgression
        )

        if paginationView !== pendingReplacementPaginationView {
            on(.loaded)
        }
    }

    private func completePendingPaginationTransition(_ paginationView: PaginationView) {
        guard
            let transition = pendingPaginationTransition,
            paginationView === transition.replacementPaginationView
        else {
            return
        }

        snapshotProvider.invalidate()
        pendingSnapshotPaginationCompletion = paginationView
        scheduleSnapshotMutationDrain()
    }

    private func completePendingPaginationTransitionAfterSnapshotCapture(_ paginationView: PaginationView) {
        guard
            let transition = pendingPaginationTransition,
            paginationView === transition.replacementPaginationView
        else {
            return
        }

        pendingPaginationTransition = nil
        transition.oldPaginationView.removeFromSuperview()
        on(.loaded)
        finishPaginationPreferenceTransition()
    }

    private func rollbackPendingPaginationTransition(
        _ paginationView: PaginationView,
        failedCurrentIndex index: Int
    ) {
        guard
            let transition = pendingPaginationTransition,
            paginationView === transition.replacementPaginationView,
            index == paginationView.currentIndex
        else {
            return
        }

        snapshotProvider.invalidate()
        pendingSnapshotPaginationCompletion = nil
        pendingSnapshotPaginationRollback = (paginationView, index)
        scheduleSnapshotMutationDrain()
    }

    private func rollbackPendingPaginationTransitionAfterSnapshotCapture(
        _ paginationView: PaginationView,
        failedCurrentIndex index: Int
    ) {
        guard
            let transition = pendingPaginationTransition,
            paginationView === transition.replacementPaginationView,
            index == paginationView.currentIndex
        else {
            return
        }

        viewportPropagationTask?.cancel()
        viewportPropagationTask = nil
        pendingPaginationTransition = nil
        self.paginationView = transition.oldPaginationView
        spreads = transition.oldSpreads

        paginationView.removeFromSuperview()
        viewModel.restorePreferencesAfterFailedPaginationTransition(
            transition.previousPreferences
        )
        applySettings()
        on(.loaded)
        paginationViewDidUpdateViewport(transition.oldPaginationView)
        delegate?.navigator(self, presentationDidChange: presentation)
        finishPaginationPreferenceTransition()
    }

    private var hasPendingSnapshotMutations: Bool {
        pendingSnapshotViewSize != nil
            || needsSnapshotPaginationInvalidation
            || needsSnapshotReload
            || pendingSnapshotPaginationCompletion != nil
            || pendingSnapshotPaginationRollback != nil
    }

    private func deferViewSizeChangeUntilSnapshotRestored(_ size: CGSize) {
        snapshotProvider.invalidate()
        pendingSnapshotViewSize = size
        scheduleSnapshotMutationDrain()
    }

    private func scheduleSnapshotMutationDrain() {
        guard !isDrainingSnapshotMutations else { return }
        snapshotProvider.deferReload { [weak self] in
            self?.scheduleExecutorSnapshotMutationDrain()
        }
    }

    private func scheduleExecutorSnapshotMutationDrain() {
        snapshotProvider.performDeferredMutation { [weak self] in
            guard let self else { return }
            _ = await navigationExecutor.submit(
                intent: .reload("snapshot-mutation"),
                timeout: navigationOperationTimeout
            ) { [weak self] operation in
                guard let self else { return .cancelled }
                if let result = operation.check() { return result }
                drainSnapshotMutations()
                if let result = operation.check() {
                    poisonVisibleSpreads(with: result)
                    return await recoverPoisonedSpreadsIfNeeded(
                        after: result,
                        stableLocator: currentLocation,
                        operation: operation
                    )
                }
                return .applied
            }
        }
    }

    private func drainSnapshotMutations() {
        guard !isDrainingSnapshotMutations else { return }
        isDrainingSnapshotMutations = true
        defer { isDrainingSnapshotMutations = false }

        while hasPendingSnapshotMutations {
            let viewSize = pendingSnapshotViewSize
            let completion = pendingSnapshotPaginationCompletion
            let rollback = pendingSnapshotPaginationRollback
            var shouldInvalidatePagination = needsSnapshotPaginationInvalidation
            var shouldReload = needsSnapshotReload

            pendingSnapshotViewSize = nil
            pendingSnapshotPaginationCompletion = nil
            pendingSnapshotPaginationRollback = nil
            needsSnapshotPaginationInvalidation = false
            needsSnapshotReload = false

            if let viewSize {
                viewModel.viewSizeWillChange(viewSize)
            }
            if let rollback {
                rollbackPendingPaginationTransitionAfterSnapshotCapture(
                    rollback.paginationView,
                    failedCurrentIndex: rollback.index
                )
            } else if let completion {
                completePendingPaginationTransitionAfterSnapshotCapture(completion)
            }

            viewModel.flushPendingPaginationInvalidation()
            shouldInvalidatePagination = shouldInvalidatePagination || needsSnapshotPaginationInvalidation
            shouldReload = shouldReload || needsSnapshotReload
            needsSnapshotPaginationInvalidation = false
            needsSnapshotReload = false

            if shouldInvalidatePagination {
                invalidatePaginationViewAfterSnapshotCapture()
            } else if shouldReload {
                reloadSpreadsAfterSnapshotCapture()
            }
        }
    }

    private func finishPaginationPreferenceTransition() {
        guard isPaginationPreferenceTransitionActive else {
            return
        }

        isPaginationPreferenceTransitionActive = false
        let preferences = queuedPaginationPreferences
        queuedPaginationPreferences = nil

        if let preferences, preferences != viewModel.preferences {
            submitPreferences(preferences)
        }
    }

    private func loadedSpreadViewForHREF<T: URLConvertible>(_ href: T) -> EPUBSpreadView? {
        guard
            let loadedViews = paginationView?.loadedViews,
            let index = readingOrder.firstIndexWithHREF(href)
        else {
            return nil
        }

        return loadedViews
            .compactMap { _, view in view as? EPUBSpreadView }
            .first { $0.spread.contains(index: index) }
    }

    func captureAdjacentPageSnapshotForTesting(
        to direction: EPUBSpreadView.Direction
    ) async throws -> UIImage? {
        guard
            snapshotProvider.isInputEnabled,
            currentSelection == nil,
            let currentSpread = paginationView?.currentView as? EPUBSpreadView,
            !currentSpread.hasActiveMedia
        else {
            return nil
        }

        let left = pageTurnSnapshotTarget(to: .left)
        let right = pageTurnSnapshotTarget(to: .right)
        snapshotProvider.retainSnapshots(
            previous: left?.identity,
            current: currentPageTurnSnapshotIdentity(),
            next: right?.identity
        )
        let target: PageTurnSnapshotTarget?
        switch direction {
        case .left:
            target = left
        case .right:
            target = right
        }
        guard let target else { return nil }

        return try await capturePageTurnSnapshot(target)
    }

    private func capturePageTurnSnapshot(
        _ target: PageTurnSnapshotTarget
    ) async throws -> UIImage? {
        var spreadContext: EPUBPageTurnSnapshotCaptureContext?
        var paginationContext: PaginationPageTurnSnapshotExposureContext?
        return try await snapshotProvider.capture(
            target: target.identity,
            sourceIdentity: { [weak self] in
                guard
                    let self,
                    self.pageTurnSnapshotTargetIsStillReady(target)
                else {
                    return nil
                }
                return target.identity
            },
            isBlocked: { [weak self, weak spread = target.spread] in
                guard let self, let spread else { return true }
                return self.currentSelection != nil
                    || spread.hasActiveMedia
                    || ((self.paginationView?.currentView as? EPUBSpreadView)?.hasActiveMedia ?? false)
            },
            capture: { [pagination = target.pagination, spread = target.spread] in
                guard
                    let captureContext = spread.beginPageTurnSnapshotCapture(at: target.offset)
                else {
                    throw PageTurnSnapshotError.unavailable
                }
                spreadContext = captureContext
                if target.index != target.currentIndex {
                    guard let context = await pagination.exposeReadyViewForPageTurnSnapshot(
                        at: target.index
                    ) else {
                        throw PageTurnSnapshotError.unavailable
                    }
                    paginationContext = context
                }
                return try await spread.capturePageTurnSnapshot()
            },
            restore: { [pagination = target.pagination, spread = target.spread] in
                if let spreadContext {
                    await spread.restorePageTurnSnapshotCapture(spreadContext)
                }
                if let paginationContext {
                    await pagination.restorePageTurnSnapshotExposure(paginationContext)
                }
            }
        )
    }

    var currentSpreadHasActiveMediaForTesting: Bool {
        (paginationView?.currentView as? EPUBSpreadView)?.hasActiveMedia ?? false
    }

    func beginCoverPageTurnForTesting(
        to direction: EPUBSpreadView.Direction
    ) async -> Bool {
        guard
            pageTurnTransaction == nil,
            let session = await beginPageTurn(to: direction)
        else {
            return false
        }
        let transaction = PageTurnTransaction(
            session: session,
            style: .cover,
            target: nil
        )
        pageTurnTransaction = transaction
        isInstallingPageTurnSurface = true
        defer { isInstallingPageTurnSurface = false }
        guard let rootView = delegate?.pageTurnRootView(for: self),
              let animator = EPUBPageTurnSurfaceAnimator(
                  rootView: rootView,
                  documentView: view,
                  style: .cover,
                  physicalCompletionDirection: session.physicalCompletionDirection,
                  isForward: session.isForward
              )
        else {
            pageTurnTransaction = nil
            finishPageTurn(session)
            return false
        }
        pageTurnSurfaceAnimator = animator
        _ = capturePageTurnTargetSurface()
        return true
    }

    func beginPreparingPageTurnForTesting(
        to direction: EPUBSpreadView.Direction
    ) -> Bool {
        beginPageTurnPan(to: direction)
    }

    func beginPageTurnForTesting(
        to direction: EPUBSpreadView.Direction
    ) async -> Bool {
        await beginPageTurn(to: direction) != nil
    }

    func beginPageTurnForTesting(
        to direction: EPUBSpreadView.Direction,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        let beginning = await beginPageTurn(to: direction, operation: operation)
        if case let .applied(session) = beginning {
            finishPageTurn(session)
        }
        return beginning.result
    }

    func awaitPageTurnNavigationLeaseForTesting(
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        await awaitPageTurnNavigationLease(operation: operation)
    }

    /// Queues a hard-abort location restore without aborting a live turn.
    /// Used to unit-test begin-time drain serialization.
    func queueHardAbortRestoreForTesting(_ locator: Locator) {
        queueHardAbortLocationRestore(locator, snapAfterRestore: true)
    }

    var hasPendingHardAbortRestoreForTesting: Bool {
        hardAbortLocationRestorePending
    }

    func awaitPendingHardAbortLocationRestoreForTesting() async {
        await awaitHardAbortLocationRestoreIfNeeded()
    }

    func abortPageTurnInterruptedBySelectionForTesting(snap: Bool) {
        abortPageTurnInterruptedBySelection(snapDocuments: snap)
    }

    var isPageTurnIdleForTesting: Bool {
        pageTurnController.isIdle
            && pageTurnTransaction == nil
            && pageTurnSurfaceAnimator == nil
            && !hardAbortLocationRestorePending
            && hardAbortPanResumeTask == nil
            && pendingPageTurnGesture == nil
    }

    var isNavigationQuiescentForTesting: Bool {
        isPageTurnIdleForTesting
            && pageTurnRecoverySessionID == nil
            && pageTurnRecoveryOperationWaiters.isEmpty
            && hardAbortOperationWaiters.isEmpty
            && navigationExecutor.activeOperationCountForTesting == 0
            && navigationExecutor.pendingOperationCountForTesting == 0
            && navigationExecutor.waiterCountForTesting == 0
            && snapshotProvider.isIdle
    }

    func setNavigationOperationTimeoutForTesting(
        _ timeout: NavigationOperationTimeout
    ) {
        navigationOperationTimeout = timeout
    }

    var navigationQuiescenceDiagnosticsForTesting: String {
        [
            "executorActive=\(navigationExecutor.activeOperationCountForTesting)",
            "executorPending=\(navigationExecutor.pendingOperationCountForTesting)",
            "executorWaiters=\(navigationExecutor.waiterCountForTesting)",
            "recovery=\(pageTurnRecoverySessionID == nil ? 0 : 1)",
            "recoveryWaiters=\(pageTurnRecoveryOperationWaiters.count)",
            "hardAbortPending=\(pendingHardAbortRecoveryIDs.count)",
            "hardAbortWaiters=\(hardAbortOperationWaiters.count)",
            "snapshotIdle=\(snapshotProvider.isIdle ? 1 : 0)",
        ].joined(separator: ",")
    }

    var isPageTurnControllerIdleForTesting: Bool {
        pageTurnController.isIdle && pageTurnTransaction == nil
    }

    var isPageTurnCommittingForTesting: Bool {
        pageTurnController.isCommitting
    }

    func isLiveViewAtPageTurnOriginalLocatorForTesting(
        _ locator: Locator?
    ) async -> Bool {
        let operation = NavigationOperation(
            operationID: 0,
            intent: .absolute("test-live-location-verification"),
            timeout: navigationOperationTimeout
        )
        return await isLiveViewAtPageTurnOriginalLocator(
            locator,
            operation: operation
        )
    }

    func isLiveViewAtPageTurnOriginalLocatorForTesting(
        _ locator: Locator?,
        operation: NavigationOperationToken
    ) async -> Bool {
        await isLiveViewAtPageTurnOriginalLocator(
            locator,
            operation: operation
        )
    }

    func restorePageTurnLocatorForTesting(_ locator: Locator) async -> Bool {
        let result = await navigationExecutor.submit(
            intent: .reload("test-page-turn-locator-restore"),
            timeout: navigationOperationTimeout
        ) { [weak self] operation in
            guard let self else { return .cancelled }
            return await restorePageTurnLocator(
                locator,
                operation: operation
            ).result
        }
        return result.isApplied
    }

    func resolvePageTurnLocatorForRestoreForTesting(_ locator: Locator) -> Locator {
        resolvePageTurnLocatorForRestore(locator)
    }

    func resolveLocatorProgressionForTesting(_ locator: Locator) -> Locator? {
        resolveLocatorProgression(locator)
    }

    func replacePoisonedPaginationForTesting(
        stableLocator: Locator?,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        deferredPoisonedPaginationReplacement = .init(stableLocator: stableLocator)
        return await replacePoisonedPagination(
            stableLocator: stableLocator,
            operation: operation
        )
    }

    func verifyLocatorNavigationForTesting(
        _ locator: Locator,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        await verifyLocatorNavigation(
            locator,
            moved: true,
            operation: operation
        )
    }

    func recaptureCurrentPageTurnSurfaceForTesting() -> Bool {
        pageTurnSurfaceAnimator?.recaptureCurrent() == true
    }

    struct PageTurnSurfaceTransactionEvidenceForTesting {
        let isCold: Bool
        let hasPreparedTarget: Bool
        let didBeginWithColdTarget: Bool
        let didNavigateColdTarget: Bool
        let didCaptureAfterColdNavigation: Bool
    }

    var pageTurnSurfaceTransactionEvidenceForTesting: PageTurnSurfaceTransactionEvidenceForTesting {
        let hasPreparedTarget = pageTurnSurfaceAnimator?.hasTarget == true
        let coldTargetIsUnloaded = coldPageTurnTargetIndexForTesting.map {
            paginationView?.loadedViews[$0] == nil
        } ?? false
        return PageTurnSurfaceTransactionEvidenceForTesting(
            isCold: isColdPageTurnArmedForTesting && coldTargetIsUnloaded,
            hasPreparedTarget: hasPreparedTarget,
            didBeginWithColdTarget: didBeginWithColdTargetForTesting,
            didNavigateColdTarget: didNavigateColdTargetForTesting,
            didCaptureAfterColdNavigation: didCaptureAfterColdNavigationForTesting
        )
    }

    func armColdForwardPageTurnTargetForTesting() -> Bool {
        guard
            let paginationView,
            paginationView.axis == .horizontalPaged
        else {
            return false
        }
        let targetIndex = paginationView.currentIndex + 1
        guard paginationView.discardLoadedAdjacentViewForTesting(at: targetIndex) else {
            return false
        }
        coldPageTurnTargetIndexForTesting = targetIndex
        isColdPageTurnArmedForTesting = true
        didBeginWithColdTargetForTesting = false
        didNavigateColdTargetForTesting = false
        didCaptureAfterColdNavigationForTesting = false
        return paginationView.loadedViews[targetIndex] == nil
    }

    var isInstallingPageTurnSurfaceForTesting: Bool {
        isInstallingPageTurnSurface
    }

    func canBeginPageTurnPanForTesting(
        to direction: EPUBSpreadView.Direction = .right
    ) -> Bool {
        shouldBeginPageTurnPan(to: direction)
    }

    var isPageTurnSnapshotInputEnabledForTesting: Bool {
        snapshotProvider.isInputEnabled
    }

    private struct PageTurnSnapshotTarget {
        let pagination: PaginationView
        let spread: EPUBSpreadView
        let index: Int
        let currentIndex: Int
        let resourceIndex: Int
        let pageIndex: Int
        let offset: CGPoint

        var identity: EPUBPageTurnSnapshotTargetIdentity {
            EPUBPageTurnSnapshotTargetIdentity(
                pagination: pagination,
                spread: spread,
                resourceIndex: resourceIndex,
                pageIndex: pageIndex
            )
        }
    }

    private enum PageTurnSnapshotError: Error {
        case unavailable
    }

    private func currentPageTurnSnapshotIdentity() -> EPUBPageTurnSnapshotTargetIdentity? {
        currentPageTurnSnapshotTarget()?.identity
    }

    private func currentPageTurnSnapshotTarget() -> PageTurnSnapshotTarget? {
        guard
            let paginationView,
            paginationView.axis == .horizontalPaged,
            let spread = paginationView.currentView as? EPUBSpreadView,
            spread.isSpreadLoaded,
            !spread.isTerminated,
            !spread.webView.bounds.isEmpty
        else {
            return nil
        }
        let offset = spread.scrollView.contentOffset
        return PageTurnSnapshotTarget(
            pagination: paginationView,
            spread: spread,
            index: paginationView.currentIndex,
            currentIndex: paginationView.currentIndex,
            resourceIndex: spread.spread.first.index,
            pageIndex: spread.pageTurnSnapshotPageIndex(at: offset),
            offset: offset
        )
    }

    private func pageTurnSnapshotTarget(
        to direction: EPUBSpreadView.Direction
    ) -> PageTurnSnapshotTarget? {
        guard
            let paginationView,
            paginationView.axis == .horizontalPaged,
            let currentSpread = paginationView.currentView as? EPUBSpreadView,
            currentSpread.isSpreadLoaded,
            !currentSpread.isTerminated,
            !currentSpread.webView.bounds.isEmpty
        else {
            return nil
        }

        if let offset = currentSpread.adjacentPageTurnSnapshotOffset(to: direction) {
            return PageTurnSnapshotTarget(
                pagination: paginationView,
                spread: currentSpread,
                index: paginationView.currentIndex,
                currentIndex: paginationView.currentIndex,
                resourceIndex: currentSpread.spread.first.index,
                pageIndex: currentSpread.pageTurnSnapshotPageIndex(at: offset),
                offset: offset
            )
        }

        let targetIndex: Int
        switch (viewModel.readingProgression, direction) {
        case (.ltr, .left), (.rtl, .right):
            targetIndex = paginationView.currentIndex - 1
        case (.ltr, .right), (.rtl, .left):
            targetIndex = paginationView.currentIndex + 1
        }
        guard
            let spread = paginationView.readyAdjacentView(at: targetIndex) as? EPUBSpreadView,
            spread.isSpreadLoaded,
            !spread.isTerminated,
            !spread.webView.bounds.isEmpty
        else {
            return nil
        }
        let offset = spread.scrollView.contentOffset
        return PageTurnSnapshotTarget(
            pagination: paginationView,
            spread: spread,
            index: targetIndex,
            currentIndex: paginationView.currentIndex,
            resourceIndex: spread.spread.first.index,
            pageIndex: spread.pageTurnSnapshotPageIndex(at: offset),
            offset: offset
        )
    }

    private func pageTurnSnapshotTargetIsStillReady(
        _ target: PageTurnSnapshotTarget
    ) -> Bool {
        paginationView === target.pagination
            && target.pagination.stillContainsReadyView(
                target.spread,
                at: target.index,
                currentIndex: target.currentIndex
            )
            && target.spread.isSpreadLoaded
            && !target.spread.isTerminated
    }

    // MARK: - Navigator

    private func isPaginationViewScrollingEnabled(for axis: PaginationView.Axis) -> Bool {
        axis == .verticalContinuous
            || !(config.disablePageTurnsWhileScrolling && settings.scroll)
    }

    private func pageTurnInteractionPolicy(
        for axis: PaginationView.Axis
    ) -> EPUBPageTurnInteraction.Policy {
        EPUBPageTurnInteraction.policy(axis: axis)
    }

    private func accessibilityStatusDidChange() {
        cancelActivePageTurn(reason: "accessibilityStatus")
        // The status change is synchronous on the main actor. Mark the active
        // transaction again after any cancellation callbacks/re-entrant state
        // transitions, closing the identity-validation publication window.
        pageTurnTransaction?.invalidate()
        updatePageTurnInteractionMode()
    }

    private func updatePageTurnInteractionMode() {
        guard
            !hasDeferredPageTurnInteractionModeUpdate
            || (pageTurnTransaction == nil && pageTurnController.isIdle)
        else {
            return
        }
        pageTurnInteractionModeUpdateCountForTesting += 1
        guard let paginationView else { return }
        let policy = pageTurnInteractionPolicy(for: paginationView.axis)
        paginationView.allowsNativeHorizontalPaging = policy.allowsNativeHorizontalPaging
        for view in paginationView.loadedViews.values {
            (view as? EPUBSpreadView)?.allowsNativeHorizontalPaging = policy.allowsNativeHorizontalPaging
        }
        let usesPageTurnPan = paginationView.axis == .horizontalPaged
        if usesPageTurnPan {
            if pageTurnPanGestureRecognizer.view == nil {
                view.addGestureRecognizer(pageTurnPanGestureRecognizer)
            }
            // Shared by simulation / cover / push / none. Keep it off while a
            // native text selection exists so handle drags cannot start a turn.
            pageTurnPanGestureRecognizer.isEnabled = currentSelection == nil
        } else {
            cancelActivePageTurn(reason: "interactionMode-nonPaged")
            if pageTurnPanGestureRecognizer.view != nil {
                view.removeGestureRecognizer(pageTurnPanGestureRecognizer)
            }
        }
    }

    /// A style change must not reconfigure UIKit recognizers until the page
    /// transaction has restored its captured hierarchy and reached its own
    /// terminal state.
    private func applyDeferredPageTurnInteractionMode() {
        guard
            hasDeferredPageTurnInteractionModeUpdate,
            pageTurnTransaction == nil,
            pageTurnController.isIdle
        else {
            return
        }
        hasDeferredPageTurnInteractionModeUpdate = false
        updatePageTurnInteractionMode()
    }

    private func currentEffectivePageTurnStyle() -> EPUBPageTurnStyle {
        let status = accessibilityStatusProvider()
        return effectivePageTurnStyle(
            userStyle: pageTurnStyle,
            isReduceMotionEnabled: status.isReduceMotionEnabled,
            isVoiceOverRunning: status.isVoiceOverRunning
        )
    }

    @objc private func handlePageTurnPan(_ gestureRecognizer: UIPanGestureRecognizer) {
        handlePageTurnPan(
            state: gestureRecognizer.state,
            translationX: gestureRecognizer.translation(in: view).x,
            velocityX: gestureRecognizer.velocity(in: view).x
        )
    }

    private func shouldBeginPageTurnPan(
        to direction: EPUBSpreadView.Direction
    ) -> Bool {
        guard
            let paginationView,
            paginationView.axis == .horizontalPaged,
            currentSelection == nil,
            !((paginationView.currentView as? EPUBSpreadView)?.hasActiveMedia ?? false),
            !((paginationView.currentView as? EPUBSpreadView)?.hasActiveInteractivePointer ?? false),
            (paginationView.currentView as? EPUBSpreadView)?.allowsPageTurn != false
        else {
            return false
        }

        if let transaction = pageTurnTransaction {
            return transaction.isRunning
                && !pageTurnController.isCommitting
                && pendingPageTurnGesture == nil
                && transaction.session.direction != direction
        }
        return state == .idle && pageTurnController.isIdle
    }

    private func beginPageTurnPan(
        to direction: EPUBSpreadView.Direction,
        velocityX: CGFloat = 0
    ) -> Bool {
        // While hard-abort restore is running, buffer the pan into
        // `pendingPageTurnGesture` so changed/ended are not dropped. A bare
        // async begin without that buffer would open a transaction after the
        // finger already lifted and leave it without a terminal intent.
        if hardAbortLocationRestorePending {
            return bufferPageTurnPanDuringHardAbortRestore(
                to: direction,
                velocityX: velocityX
            )
        }
        return beginPageTurnPanAssumingRestoreDrained(
            to: direction,
            velocityX: velocityX
        )
    }

    /// Stores a pan that began (or continued) while location restore is still
    /// running. `updatePendingPageTurnGesture` receives changed/ended; after
    /// restore drains, `resumePendingPageTurnGesture` applies the terminal.
    private func bufferPageTurnPanDuringHardAbortRestore(
        to direction: EPUBSpreadView.Direction,
        velocityX: CGFloat
    ) -> Bool {
        if var existing = pendingPageTurnGesture {
            existing = PendingPageTurnGesture(
                direction: direction,
                translationX: existing.translationX,
                velocityX: velocityX,
                terminalState: existing.terminalState
            )
            pendingPageTurnGesture = existing
        } else {
            pendingPageTurnGesture = PendingPageTurnGesture(
                direction: direction,
                translationX: 0,
                velocityX: velocityX,
                terminalState: nil
            )
            pageTurnPendingQueueCountForTesting += 1
        }
        schedulePendingPanResumeAfterHardAbortRestore()
        return true
    }

    private func beginPageTurnPanAssumingRestoreDrained(
        to direction: EPUBSpreadView.Direction,
        velocityX: CGFloat = 0
    ) -> Bool {
        if pageTurnRecoverySessionID != nil {
            return bufferPageTurnPanDuringHardAbortRestore(
                to: direction,
                velocityX: velocityX
            )
        }
        guard shouldBeginPageTurnPan(to: direction) else {
            return false
        }
        if let transaction = pageTurnTransaction {
            pendingPageTurnGesture = PendingPageTurnGesture(
                direction: direction,
                translationX: 0,
                velocityX: velocityX,
                terminalState: nil
            )
            pageTurnPendingQueueCountForTesting += 1
            transaction.resolve(.cancel)
            pageTurnTransactionTask?.cancel()
            return true
        }
        // Orphan recovery may queue a restore; buffer the pan rather than
        // opening a session that cannot see later ended events.
        if hasInFlightPageTurnWork, pageTurnTransaction?.isRunning != true {
            hardAbortInFlightPageTurn(
                restorePreparedLocation: true,
                reason: "beginPageTurnPan-orphan"
            )
            if hardAbortLocationRestorePending {
                return bufferPageTurnPanDuringHardAbortRestore(
                    to: direction,
                    velocityX: velocityX
                )
            }
        }
        guard let session = openPageTurnSession(to: direction) else {
            return false
        }
        let style = currentEffectivePageTurnStyle()
        let transaction = PageTurnTransaction(
            session: session,
            style: style,
            target: nil
        )
        pageTurnTransaction = transaction
        startPageTurnTransaction(transaction)
        return true
    }

    private func updatePendingPageTurnGesture(
        state: UIGestureRecognizer.State,
        translationX: CGFloat,
        velocityX: CGFloat
    ) -> Bool {
        guard var pending = pendingPageTurnGesture else { return false }
        pending.translationX = translationX
        pending.velocityX = velocityX
        if state == .ended || state == .cancelled || state == .failed {
            pending.terminalState = state
        }
        pendingPageTurnGesture = pending
        return true
    }

    /// Test seam: number of times a queued reverse gesture was successfully
    /// restarted after the previous transaction finished.
    private(set) var pageTurnPendingResumeCountForTesting = 0
    /// Test seam: times a reverse gesture was queued against an active turn.
    private(set) var pageTurnPendingQueueCountForTesting = 0
    /// Test seam: times resumePending was entered with a non-nil pending gesture.
    private(set) var pageTurnPendingResumeAttemptCountForTesting = 0
    /// Test seam: last surface-prepare failure stage (module-internal only).
    private(set) var pageTurnLastPrepareFailureForTesting: String?

    private func resumePendingPageTurnGesture() async {
        guard pageTurnTransaction == nil else { return }
        guard let pending = pendingPageTurnGesture else { return }
        pageTurnPendingResumeAttemptCountForTesting += 1
        guard
            pending.terminalState != .cancelled,
            pending.terminalState != .failed
        else {
            pendingPageTurnGesture = nil
            return
        }
        // Force a clean idle boundary before replaying the queued reverse.
        if !pageTurnController.isIdle,
           let stranded = pageTurnController.activeSession
        {
            finishPageTurn(stranded)
        }
        releasePageTurnNavigatorNavigationLock()
        // Bypass shouldBeginPageTurnPan: this is a deferred user gesture that
        // already passed begin rules when it was queued. Re-checking can fail
        // spuriously after cancel restore (transient media/selection/axis).
        guard
            pageTurnTransaction == nil,
            pageTurnController.isIdle,
            let session = await beginPageTurn(
                to: pending.direction,
                ownsPendingGesture: true
            )
        else {
            if pageTurnTransaction == nil, pageTurnController.isIdle {
                pendingPageTurnGesture = nil
            }
            return
        }
        let style = currentEffectivePageTurnStyle()
        let transaction = PageTurnTransaction(
            session: session,
            style: style,
            target: nil
        )
        transaction.isResumedPendingGesture = true
        pageTurnTransaction = transaction
        pageTurnPendingResumeCountForTesting += 1
        pendingPageTurnGesture = nil
        startPageTurnTransaction(transaction)
        if pending.translationX != 0 {
            if pageTurnSurfaceStyle == EPUBPageTurnStyle.none {
                _ = pageTurnController.track(
                    session,
                    translationX: pending.translationX,
                    viewportWidth: view.bounds.width
                )
            } else if let progress = pageTurnController.trackCover(
                session,
                translationX: pending.translationX,
                viewportWidth: view.bounds.width
            ) {
                pageTurnSurfaceProgress = progress
                pageTurnSurfaceAnimator?.render(progress: progress)
            }
        }
        if let terminalState = pending.terminalState,
           terminalState == .ended
        {
            let shouldCommit = if pageTurnSurfaceStyle == EPUBPageTurnStyle.none {
                EPUBPageTurnInteraction.shouldCommit(
                    translationX: pending.translationX,
                    viewportWidth: view.bounds.width,
                    velocityX: pending.velocityX,
                    session: session
                )
            } else {
                EPUBPageTurnInteraction.coverShouldCommit(
                    translationX: pending.translationX,
                    viewportWidth: view.bounds.width,
                    velocityX: pending.velocityX,
                    session: session
                )
            }
            resolvePageTurnTransaction(session, shouldCommit: shouldCommit)
        } else if pending.terminalState == .cancelled
            || pending.terminalState == .failed
        {
            resolvePageTurnTransaction(session, shouldCommit: false)
        }
    }

    private func resolvePageTurnTransaction(
        _ session: PageTurnSession,
        shouldCommit: Bool
    ) {
        guard
            let transaction = pageTurnTransaction,
            transaction.session.id == session.id
        else {
            return
        }
        transaction.resolve(shouldCommit ? .commit : .cancel)
    }

    private func handlePageTurnPan(
        state: UIGestureRecognizer.State,
        translationX: CGFloat,
        velocityX: CGFloat
    ) {
        // Selection handle drags can look like horizontal pans. Never keep a
        // page-turn in flight while a native selection is active, and never
        // snap mid-drag (that would fight the selection handles).
        if currentSelection != nil {
            if hasInFlightPageTurnWork {
                abortPageTurnInterruptedBySelection(snapDocuments: false)
            }
            return
        }

        switch state {
        case .began:
            let velocity = CGPoint(x: velocityX, y: 0)
            let direction = if currentEffectivePageTurnStyle() == .none {
                EPUBPageTurnInteraction.direction(for: velocity)
            } else {
                EPUBPageTurnInteraction.coverDirection(for: velocity)
            }
            guard let direction else { return }
            _ = beginPageTurnPan(to: direction, velocityX: velocityX)

        case .changed:
            if updatePendingPageTurnGesture(
                state: state,
                translationX: translationX,
                velocityX: velocityX
            ) {
                return
            }
            guard let session = pageTurnPanSession else { return }
            if pageTurnSurfaceStyle == EPUBPageTurnStyle.none {
                _ = pageTurnController.track(
                    session,
                    translationX: translationX,
                    viewportWidth: view.bounds.width
                )
            } else if let progress = pageTurnController.trackCover(
                session,
                translationX: translationX,
                viewportWidth: view.bounds.width
            ) {
                pageTurnSurfaceProgress = progress
                pageTurnSurfaceAnimator?.render(progress: progress)
            }

        case .ended:
            if updatePendingPageTurnGesture(
                state: state,
                translationX: translationX,
                velocityX: velocityX
            ) {
                return
            }
            guard let session = pageTurnPanSession else { return }
            let shouldCommit = if pageTurnSurfaceStyle == EPUBPageTurnStyle.none {
                EPUBPageTurnInteraction.shouldCommit(
                    translationX: translationX,
                    viewportWidth: view.bounds.width,
                    velocityX: velocityX,
                    session: session
                )
            } else {
                EPUBPageTurnInteraction.coverShouldCommit(
                    translationX: translationX,
                    viewportWidth: view.bounds.width,
                    velocityX: velocityX,
                    session: session
                )
            }
            resolvePageTurnTransaction(session, shouldCommit: shouldCommit)

        case .cancelled, .failed:
            if updatePendingPageTurnGesture(
                state: state,
                translationX: translationX,
                velocityX: velocityX
            ) {
                return
            }
            guard let session = pageTurnPanSession else { return }
            resolvePageTurnTransaction(session, shouldCommit: false)

        default:
            break
        }
    }

    func handlePageTurnPanForTesting(
        state: UIGestureRecognizer.State,
        translationX: CGFloat,
        velocityX: CGFloat
    ) {
        handlePageTurnPan(
            state: state,
            translationX: translationX,
            velocityX: velocityX
        )
    }

    public var presentation: VisualNavigatorPresentation {
        VisualNavigatorPresentation(
            readingProgression: settings.readingProgression,
            scroll: settings.scroll,
            axis: paginationAxis == .verticalContinuous ? .vertical : .horizontal
        )
    }

    private func currentLocationCalculation(
        ignoringPendingLocator: Bool = false
    ) -> (
        () async -> (Locator?, NavigatorViewport?)
    ) {
        if case .initializing = state {
            assertionFailure("Cannot update current location when initializing the navigator")
            return { (nil, nil) }
        }

        // Returns any pending locator to prevent returning invalid locations
        // while loading it.
        if !ignoringPendingLocator, let pendingLocator = state.pendingLocator {
            return { (pendingLocator, nil) }
        }

        guard let paginationView else {
            return { (nil, nil) }
        }

        if paginationView.axis == .verticalContinuous {
            var progressions: [ReadingOrder.Index: ClosedRange<Double>] = [:]

            for spreadIndex in paginationView.visibleIndices {
                guard
                    let spreadView = paginationView.loadedViews[spreadIndex] as? EPUBReflowableSpreadView,
                    let visibleFrame = paginationView.visibleFrame(at: spreadIndex)
                else {
                    continue
                }

                let progression = spreadView.progression(in: visibleFrame)
                for readingOrderIndex in spreadView.spread.readingOrderIndices {
                    progressions[readingOrderIndex] = progression
                }
            }

            guard
                let firstIndex = progressions.keys.min(),
                let lastIndex = progressions.keys.max()
            else {
                return { (nil, nil) }
            }

            let readingOrder = readingOrder
            let positionsByReadingOrder = positionsByReadingOrder
            let tableOfContentsTitleByHrefTask = tableOfContentsTitleByHrefTask
            return { [publication] in
                let tableOfContentsTitleByHref =
                    await tableOfContentsTitleByHrefTask.value
                return await EPUBViewportAndLocationCalculator.compute(
                    readingOrderIndices: firstIndex ... lastIndex,
                    progression: { progressions[$0] ?? 0 ... 0 },
                    readingOrder: readingOrder,
                    positionsByReadingOrder: positionsByReadingOrder,
                    tableOfContentsTitleByHref: tableOfContentsTitleByHref,
                    fallbackLocator: { await publication.locate($0) }
                )
            }
        }

        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return { (nil, nil) }
        }

        let readingOrder = readingOrder
        let positionsByReadingOrder = positionsByReadingOrder
        let tableOfContentsTitleByHrefTask = tableOfContentsTitleByHrefTask
        return { [publication] in
            let tableOfContentsTitleByHref =
                await tableOfContentsTitleByHrefTask.value
            return await EPUBViewportAndLocationCalculator.compute(
                readingOrderIndices: spreadView.spread.readingOrderIndices,
                progression: { spreadView.progression(in: $0) },
                readingOrder: readingOrder,
                positionsByReadingOrder: positionsByReadingOrder,
                tableOfContentsTitleByHref: tableOfContentsTitleByHref,
                fallbackLocator: { await publication.locate($0) }
            )
        }
    }

    private func computeCurrentLocationAndViewport() async -> (Locator?, NavigatorViewport?) {
        await currentLocationCalculation()()
    }

    private func publishLiveCurrentLocationIgnoringPendingLocator(
        operation: NavigationOperationToken
    ) async -> Bool {
        let calculate = pageTurnLocationCalculationForTesting
            ?? currentLocationCalculation(ignoringPendingLocator: true)
        return await publishCurrentLocation(
            calculating: calculate,
            operation: operation
        )
    }

    public func firstVisibleElementLocator() async -> Locator? {
        await firstVisibleSpreadAndLocator()?.locator
    }

    private func firstVisibleSpreadAndLocator() async -> (
        spreadView: EPUBSpreadView,
        locator: Locator,
        visibleFrame: CGRect?
    )? {
        guard let paginationView else {
            return nil
        }

        if paginationView.axis == .verticalContinuous {
            for index in paginationView.visibleIndices {
                guard
                    let spreadView = paginationView.loadedViews[index] as? EPUBReflowableSpreadView,
                    let visibleFrame = paginationView.visibleFrame(at: index),
                    let locator = await spreadView.findFirstVisibleElementLocator(in: visibleFrame)
                else {
                    continue
                }
                return (spreadView, locator, visibleFrame)
            }
            return nil
        }

        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return nil
        }
        guard let locator = await spreadView.findFirstVisibleElementLocator() else {
            return nil
        }
        return (spreadView, locator, nil)
    }

    /// Returns a locator targeting the first visible character in the current spread.
    ///
    /// The locator keeps the containing CSS block and stores the full prefix in
    /// `text.before`, so a text-to-speech client can start within a paragraph.
    public func firstVisibleTextLocator() async -> Locator? {
        guard
            let visible = await firstVisibleSpreadAndLocator(),
            let cssSelector = visible.locator.locations.cssSelector,
            let cssSelectorJSON = try? JSONValue.string(cssSelector).jsonString(),
            let locatorJSON = try? JSONValue.object(visible.locator.jsonObject).jsonString()
        else {
            return nil
        }
        let visibleRectJSON = visible.visibleFrame.flatMap { frame in
            try? JSONValue.object([
                "x": .double(Double(frame.minX)),
                "y": .double(Double(frame.minY)),
                "width": .double(Double(frame.width)),
                "height": .double(Double(frame.height)),
            ]).jsonString()
        } ?? "null"
        let script = """
        (() => {
          const locator = \(locatorJSON);
          locator.locations.cssSelector = \(cssSelectorJSON);
          const visibleRect = \(visibleRectJSON) ?? { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight };
          const block = document.querySelector(locator.locations.cssSelector);
          if (!block) return null;
          const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
          let textNodeIndex = 0;
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const currentTextNodeIndex = textNodeIndex++;
            const length = node.textContent.length;
            if (!length) continue;
            const range = document.createRange();
            const reachesViewport = (end) => {
              range.setStart(node, 0);
              range.setEnd(node, end);
              return Array.from(range.getClientRects()).some((rect) =>
                rect.right > visibleRect.x && rect.left < visibleRect.x + visibleRect.width &&
                rect.bottom > visibleRect.y && rect.top < visibleRect.y + visibleRect.height
              );
            };
            if (!reachesViewport(length)) continue;
            let lower = 1;
            let upper = length;
            while (lower < upper) {
              const middle = Math.floor((lower + upper) / 2);
              if (reachesViewport(middle)) upper = middle;
              else lower = middle + 1;
            }
            const index = lower - 1;
            range.setStart(node, index);
            range.setEnd(node, index + 1);
            const rect = range.getBoundingClientRect();
            if (rect.right <= visibleRect.x || rect.left >= visibleRect.x + visibleRect.width || rect.bottom <= visibleRect.y || rect.top >= visibleRect.y + visibleRect.height) continue;
            const before = document.createRange();
            before.selectNodeContents(block);
            before.setEnd(node, index);
            const after = document.createRange();
            after.selectNodeContents(block);
            after.setStart(node, index);
            locator.text = { before: before.toString(), highlight: after.toString() };
            locator.locations.domRange = {
              start: {
                cssSelector: locator.locations.cssSelector,
                textNodeIndex: currentTextNodeIndex,
                charOffset: index,
              },
            };
            return locator;
          }
          return null;
        })()
        """
        guard
            case let .success(value) = await visible.spreadView.evaluateScript(script),
            let json = JSONValue(value),
            let locator = try? Locator(json: json)
        else {
            return nil
        }
        return locator.copy(
            href: visible.locator.href,
            mediaType: visible.locator.mediaType,
            title: visible.locator.title
        )
    }

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?

    private func publishPageTurnLocation(
        _ transaction: PageTurnTransaction,
        operation: NavigationOperationToken
    ) async -> Bool {
        let calculate = pageTurnLocationCalculationForTesting
            ?? computeCurrentLocationAndViewport
        let calculation = await calculateCurrentLocationAndViewport(
            calculating: calculate,
            operation: operation
        )
        guard case let .applied((location, newViewport)) = calculation else {
            return false
        }
        guard
            pageTurnTransaction === transaction,
            !transaction.isInvalidated,
            operation.check() == nil
        else {
            return false
        }
        return publishCurrentLocation(location: location, viewport: newViewport)
    }

    @discardableResult
    private func publishCurrentLocation(
        operation: NavigationOperationToken
    ) async -> Bool {
        await publishCurrentLocation(
            calculating: computeCurrentLocationAndViewport,
            operation: operation
        )
    }

    @discardableResult
    func publishCurrentLocation(
        calculating calculate: @escaping () async -> (Locator?, NavigatorViewport?)
    ) async -> Bool {
        let (location, viewport) = await calculate()
        return publishCurrentLocation(location: location, viewport: viewport)
    }

    @discardableResult
    func publishCurrentLocation(
        calculating calculate: @escaping () async -> (Locator?, NavigatorViewport?),
        operation: NavigationOperationToken
    ) async -> Bool {
        let calculation = await calculateCurrentLocationAndViewport(
            calculating: calculate,
            operation: operation
        )
        guard case let .applied((location, newViewport)) = calculation else {
            return false
        }
        guard operation.check() == nil else { return false }
        return publishCurrentLocation(location: location, viewport: newViewport)
    }

    private func calculateCurrentLocationAndViewport(
        calculating calculate: @escaping () async -> (Locator?, NavigatorViewport?),
        operation: NavigationOperationToken
    ) async -> NavigationValueResult<(Locator?, NavigatorViewport?)> {
        let location: Locator?
        let newViewport: NavigatorViewport?
        switch await NavigationOperationWaiter<(Locator?, NavigatorViewport?)>().wait(
            operation: operation,
            work: calculate
        ) {
        case let .applied(calculation):
            (location, newViewport) = calculation
        case .rejected:
            return .rejected(operation.check() ?? .cancelled)
        }
        return .applied((location, newViewport))
    }

    private func publishCurrentLocation(
        location: Locator?,
        viewport newViewport: NavigatorViewport?
    ) -> Bool {
        guard let location else {
            log(.error, "Failed to compute the current location")
            return false
        }

        viewport = newViewport
        currentLocation = location
        guard location != notifiedCurrentLocation else { return true }
        notifiedCurrentLocation = location
        delegate?.navigator(self, locationDidChange: location)
        return true
    }

    private var currentLocationRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCurrentLocationRefreshRunning = false
    private var currentLocationRefreshRevision: UInt64 = 0

    private func invalidateCurrentLocationRefresh() {
        currentLocationRefreshRevision &+= 1
    }

    private lazy var updateCurrentLocation = execute(
        // If we're not in an `idle` state, we postpone the notification.
        // A released navigator must also stop the polling loop; otherwise the
        // weak nil owner can keep rescheduling this closure forever and prevent
        // the test runner (or host process) from becoming quiescent.
        when: { [weak self] in
            guard let self else { return true }
            return state == .idle
        },
        pollingInterval: 0.1
    ) { [weak self] in
        guard let self else { return }
        await performCurrentLocationRefresh()
    }

    private func performCurrentLocationRefresh() async {
        await performCurrentLocationRefresh(calculating: computeCurrentLocationAndViewport)
    }

    func performCurrentLocationRefresh(
        calculating calculate: @escaping () async -> (Locator?, NavigatorViewport?)
    ) async {
        guard !isCurrentLocationRefreshRunning else { return }
        isCurrentLocationRefreshRunning = true
        defer {
            isCurrentLocationRefreshRunning = false
            let waiters = currentLocationRefreshWaiters
            currentLocationRefreshWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let refreshRevision = currentLocationRefreshRevision
        let targetStamp = currentLocationCommitTargetStamp()
        let operation = NavigationOperation(
            operationID: 0,
            intent: .reload("idle-location-refresh"),
            timeout: navigationOperationTimeout
        )
        let deadline = operation.remainingNanoseconds
        let deadlineTask = Task { @MainActor in
            if deadline > 0 {
                try? await Task.sleep(nanoseconds: deadline)
            }
            guard !Task.isCancelled else { return }
            operation.cancel(as: .timedOut)
        }
        defer { deadlineTask.cancel() }
        let calculation = await NavigationOperationWaiter<(
            Locator?, NavigatorViewport?
        )>().wait(
            operation: operation,
            work: calculate
        )
        guard case let .applied((location, viewport)) = calculation else {
            return
        }
        if
            refreshRevision == currentLocationRefreshRevision,
            targetStamp == currentLocationCommitTargetStamp()
        {
            // Validation and publication form one synchronous commit point.
            _ = publishCurrentLocation(location: location, viewport: viewport)
        }
    }

    private func awaitCurrentLocationRefresh() async {
        await awaitCurrentLocationRefresh(request: updateCurrentLocation)
    }

    func awaitCurrentLocationRefresh(request: () -> Void) async {
        await withCheckedContinuation { continuation in
            currentLocationRefreshWaiters.append(continuation)
            request()
        }
    }

    public func settlePageTurn() async {
        var waitedSessionIDs = Set<UUID>()
        for _ in 0 ..< 2 {
            guard
                let transaction = pageTurnTransaction,
                transaction.isRunning,
                waitedSessionIDs.insert(transaction.session.id).inserted
            else {
                break
            }
            if
                !pageTurnController.isCommitting,
                transaction.terminalIntent == nil
            {
                cancelActivePageTurn(reason: "settlePageTurn")
            }
            _ = await transaction.waitForCompletion()
        }
        await awaitPageTurnRecoveryDrainIfNeeded()
        _ = await navigationExecutor.submit(
            intent: .reload("settle-page-turn-recovery"),
            timeout: navigationOperationTimeout
        ) { [weak self] operation in
            guard let self else { return .cancelled }
            let snapshotSettle = await snapshotProvider.settle(operation: operation)
            guard snapshotSettle.isApplied else { return snapshotSettle }
            operation.beginRecovery()
            var recoveryResult = NavigationResult.applied
            await pageTurnController.settleRecovering(
                refreshCurrentLocation: false
            ) { [weak self] session in
                guard let self else {
                    recoveryResult = .cancelled
                    return false
                }
                if await !restorePageTurnSurface(
                    session,
                    operation: operation
                ) {
                    let released = await releaseFailedPageTurnRestore(
                        session,
                        operation: operation
                    )
                    recoveryResult = operation.check()
                        ?? (released ? .applied : .spreadNotLoaded)
                    return released
                }
                return true
            }
            if let result = operation.check() { return result }
            guard recoveryResult.isApplied else { return recoveryResult }
            return await publishCurrentLocation(operation: operation)
                ? .applied
                : .spreadNotLoaded
        }
        await awaitHardAbortLocationRestoreIfNeeded()
        if let panResume = hardAbortPanResumeTask {
            await panResume.value
        }
        await navigationExecutor.waitUntilIdle()
    }

    private func pageTurnDirection(from options: NavigatorGoOptions) -> EPUBSpreadView.Direction? {
        guard case let .string(value)? = options.otherOptions["readium.epub.pageTurnDirection"] else {
            return nil
        }
        switch (value, viewModel.readingProgression) {
        case ("forward", .ltr), ("backward", .rtl):
            return .right
        case ("backward", .ltr), ("forward", .rtl):
            return .left
        default:
            return nil
        }
    }

    public func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        await navigate(to: locator, options: options).isApplied
    }

    public func navigate(
        to locator: Locator,
        options: NavigatorGoOptions
    ) async -> NavigationOutcome {
        invalidateCurrentLocationRefresh()
        let normalized = publication.normalizeLocator(locator)
        var mutation: NavigationMutationResult?
        let result = await navigationExecutor.submit(
            intent: .absolute(normalized.href.string),
            timeout: navigationOperationTimeout
        ) { [weak self] operation in
            guard let self else { return .cancelled }
            let stableLocator = currentLocation
            let navigation = await performLocatorNavigation(
                to: normalized,
                options: options,
                operation: operation,
                stableLocator: stableLocator
            )
            let recovered = await recoverPoisonedSpreadsIfNeeded(
                after: navigation,
                stableLocator: stableLocator,
                operation: operation
            )
            mutation = recovered
            return recovered.result
        }
        let completed: NavigationMutationResult
        if result.isApplied {
            completed = mutation ?? .init(
                result: result,
                mayHaveMutated: false,
                failureStage: .preflight
            )
        } else if let mutation {
            completed = mutation.replacingResult(
                result,
                failureStage: mutation.failureStage ?? .settleRecovery
            )
        } else {
            completed = .rejected(
                result,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        return NavigationOutcome(completed)
    }

    func performLocatorNavigationForTesting(
        to locator: Locator,
        options: NavigatorGoOptions = .init(animated: false),
        operation: NavigationOperationToken,
        stableLocator: Locator? = nil
    ) async -> NavigationResult {
        await performLocatorNavigation(
            to: locator,
            options: options,
            operation: operation,
            stableLocator: stableLocator
        ).result
    }

    func performLocatorNavigationMutationForTesting(
        to locator: Locator,
        options: NavigatorGoOptions = .init(animated: false),
        operation: NavigationOperationToken,
        stableLocator: Locator? = nil
    ) async -> NavigationMutationResult {
        await performLocatorNavigation(
            to: locator,
            options: options,
            operation: operation,
            stableLocator: stableLocator
        )
    }

    private func performLocatorNavigation(
        to locator: Locator,
        options: NavigatorGoOptions,
        operation: NavigationOperationToken,
        stableLocator: Locator?
    ) async -> NavigationMutationResult {
        if let result = operation.check() {
            return .rejected(
                result,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .preflight
            )
        }
        let settleResult = await snapshotProvider.settleCapture(operation: operation)
        guard settleResult.isApplied else {
            return .rejected(
                settleResult,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .settleRecovery
            )
        }
        // `settle()` can suspend while gestures and recovery callbacks run.
        // Acquire the navigation lease afterwards so it is still valid when
        // the jump starts mutating pagination/WebView state.
        let leaseResult = await awaitPageTurnNavigationLease(operation: operation)
        guard leaseResult.isApplied else {
            return .rejected(
                leaseResult,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .preflight
            )
        }
        guard let locator = resolveLocatorProgression(locator) else {
            return .rejected(
                .failed(EPUBNavigatorViewController.EPUBError.spreadNotLoaded),
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .linkResolution
            )
        }
        let recovery = await replacePoisonedPaginationIfNeeded(
            stableLocator: currentLocation,
            replacementLocator: locator,
            operation: operation
        )
        guard recovery.isApplied else {
            return .rejected(
                recovery,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .settleRecovery
            )
        }
        if let result = operation.check() {
            return .rejected(
                result,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .preflight
            )
        }
        snapshotProvider.invalidate()
        let options = EPUBPageTurnInteraction.discreteNavigationOptions(
            options,
            axis: paginationView?.axis,
            style: currentEffectivePageTurnStyle()
        )

        if options.animated,
           paginationView?.axis == .horizontalPaged,
           let direction = pageTurnDirection(from: options)
        {
            switch currentEffectivePageTurnStyle() {
            case .push:
                let mutation = await turnWithPageSurface(
                    to: direction,
                    style: .push,
                    target: locator,
                    operation: operation
                )
                return await finishLocatorNavigation(
                    locator,
                    mutation: mutation,
                    operation: operation,
                    stableLocator: stableLocator
                )
            case .cover:
                let mutation = await turnWithPageSurface(
                    to: direction,
                    style: .cover,
                    target: locator,
                    operation: operation
                )
                return await finishLocatorNavigation(
                    locator,
                    mutation: mutation,
                    operation: operation,
                    stableLocator: stableLocator
                )
            case .simulation:
                let mutation = await turnWithPageSurface(
                    to: direction,
                    style: .simulation,
                    target: locator,
                    operation: operation
                )
                return await finishLocatorNavigation(
                    locator,
                    mutation: mutation,
                    operation: operation,
                    stableLocator: stableLocator
                )
            case .none:
                break
            }
        }

        guard
            let paginationView = paginationView,
            let index = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(index),
            on(.jump(locator))
        else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: false,
                stableLocator: stableLocator,
                stage: .targetLoad
            )
        }

        let mutation: NavigationMutationResult
        if let goToIndex = pageTurnGoToIndexForTesting {
            // This hook replaces the mutation itself, so its result is always
            // treated as potentially having changed the visible position.
            let result = await goToIndex(locator)
            mutation = .init(
                result: result,
                mayHaveMutated: true,
                failureStage: result.isApplied ? nil : .pageViewMutation
            )
        } else {
            mutation = await paginationView.goToIndexWithMutation(
                spreadIndex,
                location: .locator(locator),
                options: options,
                operation: operation
            )
        }
        return await finishLocatorNavigation(
            locator,
            mutation: mutation,
            expectedSpreadIndex: spreadIndex,
            operation: operation,
            stableLocator: stableLocator,
            emitJumped: true
        )
    }

    private func finishLocatorNavigation(
        _ locator: Locator,
        mutation: NavigationMutationResult,
        expectedSpreadIndex: Int? = nil,
        operation: NavigationOperationToken,
        stableLocator: Locator?,
        emitJumped: Bool = false
    ) async -> NavigationMutationResult {
        let stableLocator = mutation.stableLocator ?? stableLocator
        let mutation = mutation.preservingStableLocator(stableLocator)
        let verified: NavigationMutationResult
        if !mutation.result.isApplied {
            verified = mutation
        } else {
            let result = await verifyLocatorNavigation(
                locator,
                moved: mutation.mayHaveMutated,
                expectedSpreadIndex: expectedSpreadIndex,
                operation: operation
            )
            verified = result.isApplied
                ? mutation
                : mutation.replacingResult(
                    result,
                    stableLocator: stableLocator,
                    failureStage: .verification
                )
        }
        if verified.result.isApplied {
            guard
                let pagination = paginationView,
                let spread = pagination.currentView as? EPUBSpreadView
            else {
                return await restoreAfterFailedLocatorNavigation(
                    verified.replacingResult(
                        .spreadNotLoaded,
                        stableLocator: stableLocator,
                        failureStage: .verification
                    ),
                    operation: operation,
                    emitJumped: emitJumped
                )
            }
            let commitIndex = pagination.currentIndex
            let paginationGeneration = pagination.generation
            let spreadGeneration = spread.spreadGeneration
            let targetStamp = LocatorCommitTargetStamp(
                pagination: ObjectIdentifier(pagination),
                paginationGeneration: paginationGeneration,
                paginationViewportRevision: pagination.viewportRevision,
                index: commitIndex,
                spread: ObjectIdentifier(spread),
                spreadGeneration: spreadGeneration,
                spreadViewportRevision: spread.viewportRevision
            )
            let calculate = locatorNavigationLocationCalculationForTesting
                ?? computeCurrentLocationAndViewport
            let calculation = await calculateCurrentLocationAndViewport(
                calculating: calculate,
                operation: operation
            )
            guard case let .applied((location?, newViewport)) = calculation else {
                return await restoreAfterFailedLocatorNavigation(
                    verified.replacingResult(
                        calculation.result,
                        stableLocator: stableLocator,
                        failureStage: .locationCalculation
                    ),
                    operation: operation,
                    emitJumped: emitJumped
                )
            }
            guard location.href.isEquivalentTo(locator.href) else {
                return await restoreAfterFailedLocatorNavigation(
                    verified.replacingResult(
                        .spreadNotLoaded,
                        stableLocator: stableLocator,
                        failureStage: .locationCalculation
                    ),
                    operation: operation,
                    emitJumped: emitJumped
                )
            }
            guard calculatedLocator(location, matchesNavigationTarget: locator) else {
                return await restoreAfterFailedLocatorNavigation(
                    verified.replacingResult(
                        .spreadNotLoaded,
                        stableLocator: stableLocator,
                        failureStage: .locationCalculation
                    ),
                    operation: operation,
                    emitJumped: emitJumped
                )
            }
            if locatorHasPreciseDOMTarget(locator) {
                let visibility = await verifyDOMTargetVisibility(
                    locator,
                    in: spread,
                    operation: operation
                )
                guard visibility.isApplied else {
                    return await restoreAfterFailedLocatorNavigation(
                        verified.replacingResult(
                            visibility,
                            stableLocator: stableLocator,
                            failureStage: .verification
                        ),
                        operation: operation,
                        emitJumped: emitJumped
                    )
                }
            }
            guard
                paginationView === pagination,
                pagination.generation == paginationGeneration,
                pagination.currentIndex == commitIndex,
                pagination.currentView === spread,
                spread.spreadGeneration == spreadGeneration,
                LocatorCommitTargetStamp(
                    pagination: ObjectIdentifier(pagination),
                    paginationGeneration: pagination.generation,
                    paginationViewportRevision: pagination.viewportRevision,
                    index: pagination.currentIndex,
                    spread: ObjectIdentifier(spread),
                    spreadGeneration: spread.spreadGeneration,
                    spreadViewportRevision: spread.viewportRevision
                ) == targetStamp,
                expectedSpreadIndex.map({ $0 == commitIndex }) ?? true,
                operation.check(
                    paginationGeneration: paginationGeneration
                ) == nil
            else {
                return await restoreAfterFailedLocatorNavigation(
                    verified.replacingResult(
                        operation.check(
                            paginationGeneration: paginationGeneration
                        ) ?? .superseded,
                        stableLocator: stableLocator,
                        failureStage: .verification
                    ),
                    operation: operation,
                    emitJumped: emitJumped
                )
            }
            // This is the final synchronous transaction commit. Delegate code
            // may re-enter navigation, so no later check can invalidate it.
            let committedLocation = location.preservingTargetAnchors(from: locator)
            guard publishCurrentLocation(location: committedLocation, viewport: newViewport) else {
                return await restoreAfterFailedLocatorNavigation(
                    verified.replacingResult(
                        .spreadNotLoaded,
                        stableLocator: stableLocator,
                        failureStage: .publication
                    ),
                    operation: operation,
                    emitJumped: emitJumped
                )
            }
            if emitJumped {
                on(.jumped)
            }
            delegate?.navigator(self, didJumpTo: locator)
            return .init(
                result: .applied,
                mayHaveMutated: verified.mayHaveMutated,
                stableLocator: committedLocation,
                stableVerified: true
            )
        }
        return await restoreAfterFailedLocatorNavigation(
            verified,
            operation: operation,
            emitJumped: emitJumped
        )
    }

    private struct LocatorCommitTargetStamp: Equatable {
        let pagination: ObjectIdentifier
        let paginationGeneration: UInt64
        let paginationViewportRevision: UInt64
        let index: Int
        let spread: ObjectIdentifier
        let spreadGeneration: UInt64
        let spreadViewportRevision: UInt64
    }

    private func currentLocationCommitTargetStamp() -> LocatorCommitTargetStamp? {
        guard
            let pagination = paginationView,
            let spread = pagination.currentView as? EPUBSpreadView
        else {
            return nil
        }
        return LocatorCommitTargetStamp(
            pagination: ObjectIdentifier(pagination),
            paginationGeneration: pagination.generation,
            paginationViewportRevision: pagination.viewportRevision,
            index: pagination.currentIndex,
            spread: ObjectIdentifier(spread),
            spreadGeneration: spread.spreadGeneration,
            spreadViewportRevision: spread.viewportRevision
        )
    }

    private func calculatedLocator(
        _ calculated: Locator,
        matchesNavigationTarget target: Locator
    ) -> Bool {
        guard calculated.href.isEquivalentTo(target.href) else { return false }

        if let expectedPosition = target.locations.position {
            let actualPosition = calculated.locations.position
                ?? calculated.locations.progression.flatMap {
                    pageTurnPosition(href: target.href, progression: $0)
                }
            guard actualPosition == expectedPosition else { return false }
        }

        if let expectedProgression = target.locations.progression {
            guard let actualProgression = calculated.locations.progression else {
                return false
            }
            if abs(actualProgression - expectedProgression) >= 0.001 {
                guard
                    paginationView?.axis == .horizontalPaged,
                    let spread = paginationView?.currentView as? EPUBReflowableSpreadView,
                    spread.scrollView.bounds.width > 0,
                    spread.scrollView.contentSize.width > 0
                else {
                    return false
                }
                let pageWidth = spread.scrollView.bounds.width
                let contentWidth = spread.scrollView.contentSize.width
                let snapsToPage = !(viewModel.scroll && viewModel.verticalText)
                let reachable = EPUBReflowableSpreadView.reachableHorizontalProgression(
                    requested: expectedProgression,
                    pageWidth: pageWidth,
                    contentWidth: contentWidth,
                    isRTL: viewModel.readingProgression == .rtl,
                    snapsToPage: snapsToPage
                )
                let tolerance = snapsToPage
                    ? max(Double(pageWidth / contentWidth) * 0.51, 0.001)
                    : max(
                        Double(EPUBReflowableSpreadView.settlementPixelTolerance / contentWidth),
                        0.000_001
                    )
                guard abs(actualProgression - reachable) <= tolerance else {
                    return false
                }
            }
        }

        if
            !target.locations.fragments.isEmpty,
            !calculated.locations.fragments.isEmpty,
            calculated.locations.fragments != target.locations.fragments
        {
            return false
        }
        if let expected = target.locations.domRange,
           let actual = calculated.locations.domRange,
           actual != expected
        {
            return false
        }
        if let expected = target.locations.cssSelector,
           let actual = calculated.locations.cssSelector,
           actual != expected
        {
            return false
        }
        if let expected = target.text.highlight,
           let actual = calculated.text.highlight,
           actual != expected
        {
            return false
        }
        return true
    }

    private func verifyDOMTargetVisibility(
        _ locator: Locator,
        in spread: EPUBSpreadView,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard let verifier = locatorNavigationDOMTargetVerifierForTesting else {
            return await spread.isLocatorVisible(locator, operation: operation)
        }
        let verification = await NavigationOperationWaiter<Bool>().wait(
            operation: operation,
            work: { await verifier(locator) }
        )
        if case .applied(true) = verification {
            return .applied
        }
        return verification.result.isApplied
            ? .spreadNotLoaded
            : verification.result
    }

    private func restoreAfterFailedLocatorNavigation(
        _ mutation: NavigationMutationResult,
        operation: NavigationOperationToken,
        emitJumped: Bool
    ) async -> NavigationMutationResult {
        let stableLocator = mutation.stableLocator
        let moved = mutation.mayHaveMutated
        var restored = false
        if moved, let stableLocator {
            let restore = await restorePageTurnLocator(
                stableLocator,
                operation: operation
            )
            restored = restore.result.isApplied && restore.stableVerified
            if restored {
                restored = await publishLiveCurrentLocationIgnoringPendingLocator(
                    operation: operation
                )
            }
        }
        if moved, !restored {
            // We cannot safely leave a partially mutated reading position live.
            // Defer a poisoned replacement to an executor-owned recovery; an
            // already-expired operation cannot extend its absolute deadline.
            poisonVisibleSpreads(with: mutation.result)
        }
        if emitJumped {
            on(.jumped)
        }
        return restored ? mutation.verifiedStableLocation() : mutation
    }

    private func verifyLocatorNavigation(
        _ locator: Locator,
        moved: Bool,
        expectedSpreadIndex: Int? = nil,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard moved else { return .spreadNotLoaded }
        if let result = operation.check() { return result }
        if let expectedSpreadIndex, currentSpreadIndex != expectedSpreadIndex {
            return .superseded
        }
        guard
            let index = readingOrder.firstIndexWithHREF(locator.href),
            spreads[currentSpreadIndex].contains(index: index)
        else {
            return .spreadNotLoaded
        }
        let hasDOMTarget = locator.text.highlight != nil
            || !locator.locations.fragments.isEmpty
            || locator.locations.otherLocations["cssSelector"] != nil
            || locator.locations.domRange != nil
        if hasDOMTarget,
           paginationView?.axis != .verticalContinuous,
           let spreadView = paginationView?.currentView as? EPUBSpreadView
        {
            let visibility = await verifyDOMTargetVisibility(
                locator,
                in: spreadView,
                operation: operation
            )
            guard visibility.isApplied else { return visibility }
            if let result = operation.check() { return result }
            return .applied
        }
        guard await isLiveViewAtPageTurnOriginalLocator(
            locator,
            operation: operation
        ) else {
            return .spreadNotLoaded
        }
        // Publish only while this operation still owns the executor lease and
        // target spread after reading live resource-local geometry.
        if let result = operation.check() { return result }
        return .applied
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        invalidateCurrentLocationRefresh()
        let result = await navigationExecutor.submit(
            intent: .absolute(link.href),
            timeout: navigationOperationTimeout
        ) { [weak self] operation in
            guard let self else { return .cancelled }
            let stableLocator = currentLocation
            let locate = linkLocatorForTesting ?? { [publication] link in
                await publication.locate(link)
            }
            let resolution = await NavigationOperationWaiter<Locator?>().wait(
                operation: operation,
                work: { await locate(link) }
            )
            guard case let .applied(locator?) = resolution else {
                return operation.check() ?? .spreadNotLoaded
            }
            let normalized = publication.normalizeLocator(locator)
            let navigation = await performLocatorNavigation(
                to: normalized,
                options: options,
                operation: operation,
                stableLocator: stableLocator
            )
            return await recoverPoisonedSpreadsIfNeeded(
                after: navigation.result,
                stableLocator: stableLocator,
                operation: operation
            )
        }
        return result.isApplied
    }

    @discardableResult
    public func goForward(options: NavigatorGoOptions) async -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .right
            case .rtl:
                return .left
            }
        }()
        return await go(to: direction, options: options)
    }

    @discardableResult
    public func goBackward(options: NavigatorGoOptions) async -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .left
            case .rtl:
                return .right
            }
        }()
        return await go(to: direction, options: options)
    }

    // MARK: - SelectableNavigator

    public var currentSelection: Selection? {
        viewModel.editingActions.selection
    }

    public func clearSelection() {
        guard let paginationView = paginationView else {
            return
        }

        for (_, pageView) in paginationView.loadedViews {
            (pageView as? EPUBSpreadView)?.webView.clearSelection()
        }
    }

    // MARK: - DecorableNavigator

    private var decorations: [DecorationGroup: [DiffableDecoration]] = [:]

    /// Decoration group callbacks, indexed by the group name.
    private var decorationCallbacks: [DecorationGroup: [DecorableNavigator.OnActivatedCallback]] = [:]

    /// Pending decoration tasks, indexed by group name. Stored to allow
    /// cancellation when a new `apply(decorations:in:)` call supersedes a
    /// previous one.
    private var decorationTasks: [DecorationGroup: Task<Void, Never>] = [:]

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        config.decorationTemplates.keys.contains(style)
    }

    public func apply(decorations: [Decoration], in group: DecorationGroup) {
        decorationTasks[group]?.cancel()
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            defer {
                if let self, self.decorationTasks[group] == task {
                    self.decorationTasks[group] = nil
                }
            }
            guard let self else { return }
            await self.initialized()

            guard
                !Task.isCancelled,
                let paginationView = self.paginationView
            else {
                return
            }

            await withTaskGroup(of: Void.self) { tasks in
                guard !Task.isCancelled else { return }

                let source = self.decorations[group] ?? []
                let target = decorations.map {
                    var d = $0
                    d.locator = self.publication.normalizeLocator(d.locator)
                    return DiffableDecoration(decoration: d)
                }
                self.decorations[group] = target

                if decorations.isEmpty {
                    for (_, pageView) in paginationView.loadedViews {
                        tasks.addTask {
                            guard !Task.isCancelled else { return }
                            await (pageView as? EPUBSpreadView)?.evaluateScript(
                                // The updates command are using `requestAnimationFrame()`, so we need it for
                                // `clear()` as well otherwise we might recreate a highlight after it has been
                                // cleared.
                                "requestAnimationFrame(function () { readium.getDecorations('\(group)').clear(); });"
                            )
                        }
                    }
                } else {
                    for (href, changes) in target.changesByHREF(from: source) {
                        guard let script = changes.javascript(forGroup: group, styles: self.config.decorationTemplates) else {
                            continue
                        }
                        tasks.addTask { @MainActor [weak self] in
                            guard
                                !Task.isCancelled,
                                let spreadView = self?.loadedSpreadViewForHREF(href),
                                spreadView.isSpreadLoaded
                            else {
                                return
                            }
                            await spreadView.evaluateScript(script, inHREF: href)
                        }
                    }
                }
            }
        }
        decorationTasks[group] = task
    }

    public func observeDecorationInteractions(inGroup group: DecorationGroup, onActivated: @escaping OnActivatedCallback) {
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            await withTaskGroup(of: Void.self) { tasks in
                for (_, view) in paginationView.loadedViews {
                    tasks.addTask {
                        await (view as? EPUBSpreadView)?.evaluateScript("readium.getDecorations('\(group)').setActivable();")
                    }
                }
            }
        }
    }

    // MARK: - Configurable

    public var settings: EPUBSettings {
        viewModel.settings
    }

    public func submitPreferences(_ preferences: EPUBPreferences) {
        if preferences.scroll != viewModel.preferences.scroll {
            cancelActivePageTurn(reason: "submitPreferences-layout")
        }
        snapshotProvider.invalidate()
        guard snapshotProvider.isIdle else {
            snapshotProvider.deferPreferences { [weak self] in
                self?.submitPreferencesAfterSnapshotCapture(preferences)
            }
            return
        }
        submitPreferencesAfterSnapshotCapture(preferences)
    }

    private func submitPreferencesAfterSnapshotCapture(_ preferences: EPUBPreferences) {
        guard !isPaginationPreferenceTransitionActive else {
            queuedPaginationPreferences = preferences
            return
        }

        let previousPreferences = viewModel.preferences
        viewModel.submitPreferences(preferences)
        if let paginationView, paginationView.axis != paginationAxis {
            isPaginationPreferenceTransitionActive = true
            paginationRollbackPreferences = previousPreferences
            paginationView.isUserInteractionEnabled = false
            _ = on(.load(currentLocation))
        }
        applySettings()

        delegate?.navigator(self, presentationDidChange: presentation)
        viewModel.flushPendingPaginationInvalidation()
    }

    public func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        viewModel.editor(of: preferences)
    }

    /// Applies user settings that require native configuration instead of
    /// CSS properties.
    private func applySettings() {
        guard isViewLoaded else {
            return
        }

        view.backgroundColor = settings.effectiveBackgroundColor.uiColor
        if let paginationView {
            paginationView.isScrollEnabled = isPaginationViewScrollingEnabled(for: paginationView.axis)
            updatePageTurnInteractionMode()
        }
        updatePaginationContentInset()
    }

    private func updatePaginationContentInset() {
        guard let paginationView else { return }
        paginationView.contentInset = paginationView.axis == .verticalContinuous
            ? resolvedContentInset()
            : .zero
    }

    // MARK: - EPUB-specific extensions

    /// Evaluates the given JavaScript on the currently visible HTML resource.
    @discardableResult
    public func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return .failure(EPUBError.spreadNotLoaded)
        }
        return await spreadView.evaluateScript(script)
    }

    // MARK: - UIAccessibilityAction

    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !super.accessibilityScroll(direction) else {
            return true
        }

        let options = NavigatorGoOptions(animated: false)

        Task {
            switch direction {
            case .right:
                await goLeft(options: options)
            case .left:
                await goRight(options: options)
            case .next, .down:
                await goForward(options: options)
            case .previous, .up:
                await goBackward(options: options)
            @unknown default:
                break
            }
        }
        return true
    }
}

extension EPUBNavigatorViewController: EPUBNavigatorViewModelDelegate {
    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {
        invalidatePaginationView()
    }

    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, runScript script: String, in scope: EPUBScriptScope) {
        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            switch scope {
            case .currentResource:
                await (paginationView.currentView as? EPUBSpreadView)?.evaluateScript(script)

            case .loadedResources:
                await withTaskGroup(of: Void.self) { tasks in
                    for (_, view) in paginationView.loadedViews {
                        tasks.addTask {
                            await (view as? EPUBSpreadView)?.evaluateScript(script)
                        }
                    }
                }

            case let .resource(href):
                for (_, view) in paginationView.loadedViews {
                    guard
                        let view = view as? EPUBSpreadView,
                        let index = readingOrder.firstIndexWithHREF(href),
                        view.spread.contains(index: index)
                    else {
                        continue
                    }
                    await view.evaluateScript(script, inHREF: href)
                    return
                }
            }
        }
    }
}

extension EPUBNavigatorViewController: EPUBSpreadViewDelegate {
    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets {
        if paginationView?.axis == .verticalContinuous {
            return .zero
        }
        return resolvedContentInset()
    }

    private func resolvedContentInset() -> UIEdgeInsets {
        if let inset = delegate?.navigatorContentInset(self) {
            return inset
        }

        // We use the window's safeAreaInsets instead of the view's because we
        // only want to take into account the device notch and status bar, not
        // the application's bars.
        var insets = view.window?.safeAreaInsets ?? .zero

        switch publication.metadata.epubLayout {
        case .fixed:
            // With iPadOS and macOS, we aim to display content edge-to-edge
            // since there are no physical notches or Dynamic Island like on the
            // iPhone.
            if UIDevice.current.userInterfaceIdiom != .phone {
                insets = .zero
            }

        case .reflowable:
            let configInset = config.contentInset(for: view.traitCollection.verticalSizeClass)
            insets.top = max(insets.top, configInset.top)
            insets.bottom = max(insets.bottom, configInset.bottom)
        }

        return insets
    }

    func spreadView(
        _ spreadView: EPUBSpreadView,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        guard
            let paginationView,
            let index = paginationView.loadedViews.first(where: {
                $0.value === spreadView
            })?.key,
            paginationView.loadedViews[index] === spreadView
        else {
            return
        }

        if paginationView.axis == .verticalContinuous {
            paginationView.setVerticalPageFailed(at: index)
        }
        rollbackPendingPaginationTransition(
            paginationView,
            failedCurrentIndex: index
        )
        delegate?.navigator(
            self,
            didFailToLoadResourceAt: href,
            withError: error
        )
    }

    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async {
        let templates = config.decorationTemplates.reduce(into: [String: JSONValue]()) { styles, item in
            styles[item.key.rawValue] = .object(item.value.jsonObject)
        }

        guard let stylesJSON = try? templates.jsonString() else {
            log(.error, "Can't serialize decoration styles to JSON")
            return
        }
        var script = "readium.registerDecorationTemplates(\(stylesJSON.replacingOccurrences(of: "\\n", with: " ")));\n"

        script += decorationCallbacks
            .compactMap { group, callbacks in
                guard !callbacks.isEmpty else {
                    return nil
                }
                return "readium.getDecorations('\(group)').setActivable();"
            }
            .joined(separator: "\n")

        let links = spreadView.spread.readingOrderIndices
            .compactMap { readingOrder.getOrNil($0) }

        for link in links {
            let href = link.url()
            for (group, decorations) in decorations {
                let decorations = decorations
                    .filter { $0.decoration.locator.href.isEquivalentTo(href) }
                    .map { DecorationChange.add($0.decoration) }

                guard let decorationsScript = decorations.javascript(forGroup: group, styles: config.decorationTemplates) else {
                    continue
                }
                script += decorationsScript
            }
        }

        await spreadView.evaluateScript("(function() {\n\(script)\n})();")

        guard
            let paginationView,
            let index = paginationView.loadedViews.first(where: { $0.value === spreadView })?.key,
            paginationView.loadedViews[index] === spreadView
        else {
            return
        }

        if paginationView.axis == .verticalContinuous {
            guard
                let spreadView = spreadView as? EPUBReflowableSpreadView,
                let contentHeight = spreadView.contentHeight
            else {
                return
            }
            paginationView.setVerticalPageHeight(contentHeight, isReady: true, at: index)
        }

        if
            paginationView === pendingReplacementPaginationView,
            index == paginationView.currentIndex
        {
            completePendingPaginationTransition(paginationView)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {
        Task {
            var event = event
            event.location = view.convert(event.location, from: spreadView)
            if let targetElement = event.targetElement {
                event.targetElement?.frame = view.convert(targetElement.frame, from: spreadView)
            }
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {
        Task {
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        guard state == .idle else { return }

        delegate?.navigator(self, presentExternalURL: url)
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {
        guard
            let url = AnyURL(string: href),
            var link = publication.linkWithHREF(url)
        else {
            log(.warning, "Cannot find link with HREF: \(href)")
            return
        }
        link.href = href

        Task {
            // Check to see if this was a noteref link and give delegate the
            // opportunity to display it.
            if
                let clickEvent = clickEvent,
                let interactive = clickEvent.interactiveElement,
                let (note, referrer) = await getNoteData(anchor: interactive, href: href),
                let delegate = delegate
            {
                if !delegate.navigator(
                    self,
                    shouldNavigateToNoteAt: link,
                    content: note,
                    referrer: referrer
                ) {
                    return
                }
            }

            // Ask if we should navigate to the link
            if let delegate = delegate, !delegate.navigator(self, shouldNavigateToLink: link) {
                return
            }

            await go(to: link)
        }
    }

    /// Checks if the internal link is a noteref, and retrieves both the referring text of the link and the body of the note.
    ///
    /// Uses the navigation href from didTapOnInternalLink because it is normalized to a path within the book,
    /// whereas the anchor tag may have just a hash fragment like `#abc123` which is hard to work with.
    /// We do at least validate to ensure that the two hrefs match.
    ///
    /// Uses `#id` when retrieving the body of the note, not `aside#id` because it may be a `<section>`.
    /// See https://idpf.github.io/epub-vocabs/structure/#footnotes
    /// and http://kb.daisy.org/publishing/docs/html/epub-type.html#ex
    func getNoteData(anchor: String, href: String) async -> (String, String)? {
        do {
            let doc = try parse(anchor)
            guard let link = try doc.select("a[epub:type=noteref]").first() else { return nil }

            let anchorHref = try link.attr("href")
            guard href.hasSuffix(anchorHref) else { return nil }

            guard
                let url = AnyURL(string: href),
                let id = url.fragment
            else {
                log(.warning, "Could not find hash in link \(href)")
                return nil
            }

            // Read the note's resource through the publication's resource API.
            guard let resource = publication.get(url.removingFragment()) else {
                log(.warning, "Could not open note resource: \(href)")
                return nil
            }
            let contents = try await resource.read().asString().get()
            let document = try parse(contents)

            guard let aside = try document.select("#\(id)").first() else {
                log(.warning, "Could not find the element '#\(id)' in document \(href)")
                return nil
            }

            return try (aside.html(), link.html())

        } catch {
            log(.warning, "Caught error while getting note content: \(error)")
            return nil
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?) {
        guard
            let callbacks = decorationCallbacks[group].takeIf({ !$0.isEmpty }),
            let decoration: Decoration = decorations[group]?
            .first(where: { $0.decoration.id == id })
            .map(\.decoration)
        else {
            return
        }

        for callback in callbacks {
            callback(OnDecorationActivatedEvent(
                decoration: decoration,
                group: group,
                rect: frame.map { view.convert($0, from: spreadView) },
                point: point.map { view.convert($0, from: spreadView) }
            ))
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange locator: Locator?, frame: CGRect) {
        if let locator {
            viewModel.editingActions.selection = Selection(
                locator: locator,
                frame: view.convert(frame, from: spreadView)
            )
            // Abort any turn that started under the selection gesture, but do
            // not snap mid-drag (that would fight the selection handles).
            if hasInFlightPageTurnWork {
                abortPageTurnInterruptedBySelection(snapDocuments: false)
            } else {
                updatePageTurnInteractionMode()
            }
            return
        }

        viewModel.editingActions.selection = nil
        // Selection cleared: hard-abort leftover turns and snap mid-page
        // web/pagination offsets back to whole pages for every style.
        if hasInFlightPageTurnWork {
            abortPageTurnInterruptedBySelection(snapDocuments: true)
        } else {
            queueHardAbortLocationRestore(nil, snapAfterRestore: true)
            updatePageTurnInteractionMode()
        }
    }

    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        if pageTurnSnapshotsRequireInvalidationForPagesDidChange(
            spreadView,
            in: paginationView
        ) {
            snapshotProvider.invalidate()
            updateCurrentLocation()
        }
    }

    func spreadViewScaleDidChange(_ spreadView: EPUBSpreadView) {
        snapshotProvider.invalidate()
    }

    func spreadViewActiveMediaDidChange(_ spreadView: EPUBSpreadView) {
        snapshotProvider.invalidate()
        if spreadView.hasActiveMedia {
            cancelActivePageTurn(reason: "activeMedia")
        } else if currentSelection == nil {}
    }

    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

    func spreadViewDidTerminate() {
        poisonVisibleSpreads(with: .webContentTerminated)
        scheduleExecutorReload(reason: "web-content-termination")
    }
}

extension EPUBNavigatorViewController: EditingActionsControllerDelegate {
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
    }

    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
        delegate?.navigator(self, shouldShowMenuForSelection: selection) ?? true
    }

    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        delegate?.navigator(self, canPerformAction: action, for: selection) ?? true
    }
}

extension EPUBNavigatorViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard
            let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer
        else {
            return false
        }
        guard gestureRecognizer === pageTurnPanGestureRecognizer else { return false }
        updatePageTurnInteractionMode()
        let velocity = panGestureRecognizer.velocity(in: view)
        let direction = if currentEffectivePageTurnStyle() == .none {
            EPUBPageTurnInteraction.direction(for: velocity)
        } else {
            EPUBPageTurnInteraction.coverDirection(for: velocity)
        }
        return direction.map(shouldBeginPageTurnPan(to:)) ?? false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === pageTurnPanGestureRecognizer else {
            return true
        }
        // Do not start a page-turn pan while native text selection is active
        // (including selection-handle drags that report selection slightly late).
        return currentSelection == nil
    }
}

extension EPUBNavigatorViewController: PaginationViewDelegate {
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
        let spread = spreads[index]
        let spreadViewType = (publication.metadata.layout == .fixed) ? EPUBFixedSpreadView.self : EPUBReflowableSpreadView.self
        let spreadView = spreadViewType.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [],
            animatedLoad: false
        )
        spreadView.delegate = self
        spreadView.allowsNativeHorizontalPaging = paginationView.allowsNativeHorizontalPaging

        if let spreadView = spreadView as? EPUBReflowableSpreadView {
            spreadView.contentHeightDidChange = { [weak paginationView, weak spreadView] height in
                guard
                    let paginationView,
                    let spreadView,
                    paginationView.loadedViews[index] === spreadView
                else {
                    return
                }
                paginationView.setVerticalPageHeight(height, isReady: false, at: index)
            }
        }

        let userContentController = spreadView.webView.configuration.userContentController
        delegate?.navigator(self, setupUserScripts: userContentController)

        return spreadView
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        snapshotProvider.invalidate()
        // Note that you should set the delegate before you load views
        // otherwise, when open the publication, you may miss the first
        // invocation.
        paginationViewDidUpdateViewport(paginationView)
    }

    func paginationViewDidUpdateViewport(_ paginationView: PaginationView) {
        guard paginationView === self.paginationView else { return }

        viewportPropagationTask?.cancel()

        if paginationView.axis == .verticalContinuous {
            let visibleFrames = Dictionary(uniqueKeysWithValues: paginationView.visibleIndices.compactMap { index in
                paginationView.visibleFrame(at: index).map { (index, $0) }
            })
            let updates: [(EPUBReflowableSpreadView, CGRect?)] = paginationView.loadedViews.compactMap { index, view in
                guard
                    let spreadView = view as? EPUBReflowableSpreadView,
                    spreadView.isSpreadLoaded
                else {
                    return nil
                }
                return (spreadView, visibleFrames[index])
            }

            viewportPropagationTask = Task { @MainActor in
                await withTaskGroup(of: Void.self) { tasks in
                    for (spreadView, visibleFrame) in updates {
                        tasks.addTask {
                            guard !Task.isCancelled else { return }
                            await spreadView.setContinuousViewport(visibleFrame)
                        }
                    }
                }
            }
        }

        updateCurrentLocation()
    }

    func paginationView(
        _ paginationView: PaginationView,
        verticalOffsetFor location: PageLocation,
        at index: Int
    ) async -> CGFloat? {
        guard
            paginationView === self.paginationView,
            let spreadView = paginationView.loadedViews[index] as? EPUBReflowableSpreadView
        else {
            return nil
        }
        return await spreadView.resolveVerticalOffset(for: location)
    }

    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int {
        spreads[index].positionCount(in: readingOrder, positionsByReadingOrder: positionsByReadingOrder)
    }
}

private extension Locator {
    func preservingTargetAnchors(from target: Locator) -> Locator {
        copy(
            locations: { locations in
                if !target.locations.fragments.isEmpty {
                    locations.fragments = target.locations.fragments
                }
                if let position = target.locations.position {
                    locations.position = position
                }
                for (key, value) in target.locations.otherLocations {
                    locations.otherLocations[key] = value
                }
            },
            text: { text in
                guard target.text.highlight != nil else { return }
                text = target.text
            }
        )
    }
}
