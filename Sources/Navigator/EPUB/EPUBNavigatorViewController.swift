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

@MainActor public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate,
    ViewportObservingNavigatorDelegate
{
    /// Root view representing one complete reader page, including app chrome.
    func pageTurnRootView(for navigator: EPUBNavigatorViewController) -> UIView?

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
    func pageTurnRootView(for navigator: EPUBNavigatorViewController) -> UIView? { nil }

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
    private var storedPageTurnStyle: EPUBPageTurnStyle
    public var pageTurnStyle: EPUBPageTurnStyle {
        get { storedPageTurnStyle }
        set {
            guard storedPageTurnStyle != newValue || !snapshotProvider.isIdle else { return }
            cancelActivePageTurn()
            snapshotProvider.invalidate()
            snapshotProvider.deferPageTurnStyle { [weak self] in
                guard let self else { return }
                self.storedPageTurnStyle = newValue
                self.updatePageTurnInteractionMode()
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
        pageTurnPreparationTask?.cancel()
        pageTurnResolutionTask?.cancel()
        MainActor.assumeIsolated {
            pageTurnSurfaceAnimator?.remove()
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

    private var isActive = true

    @objc private func willResignActive() {
        isActive = false
        cancelActivePageTurn()
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
        // `snapshotView(afterScreenUpdates:)` can synchronously propagate traits
        // through the replicated hierarchy. That callback is part of installing
        // the surface itself, not an external environment change, and must not
        // invalidate the session which owns the surface being installed.
        if !isInstallingPageTurnSurface {
            cancelActivePageTurn()
        }
        snapshotProvider.invalidate()
        updatePaginationContentInset()
    }

    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if isActive {
            cancelActivePageTurn()
            deferViewSizeChangeUntilSnapshotRestored(size)
        }
    }

    override open func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        cancelActivePageTurn()
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

    private lazy var tableOfContentsTitleByHrefTask: Task<[AnyURL: String], Never> = Task {
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

    private var pageTurnPanSession: PageTurnSession?
    private var pageTurnSurfaceAnimator: EPUBPageTurnSurfaceAnimator?
    private var pageTurnSurfaceStyle: EPUBPageTurnStyle?
    private var pageTurnSurfaceProgress: CGFloat = 0
    private var pageTurnSurfaceDidPrepareTarget = false
    private struct PageTurnPreview: Equatable {
        let location: Locator
        let viewport: NavigatorViewport
    }

    private var pageTurnSurfaceOriginalPreview: PageTurnPreview?
    private var pageTurnSurfaceTargetPreview: PageTurnPreview?
    private var pageTurnSurfaceTargetLocator: Locator?
    private var isInstallingPageTurnSurface = false
    private var pageTurnPreparationTask: Task<Bool, Never>?
    private var pageTurnResolutionTask: Task<Bool, Never>?
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
    private var coldPageTurnTargetIndexForTesting: Int?
    private var isColdPageTurnArmedForTesting = false
    private var didBeginWithColdTargetForTesting = false
    private var didNavigateColdTargetForTesting = false
    private var didCaptureAfterColdNavigationForTesting = false

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

    private func beginPageTurn(
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
        target: Locator? = nil
    ) async -> Bool {
        guard let navigation = pageTurnNavigation(
            session,
            options: options,
            target: target
        ) else {
            return false
        }
        return await navigation()
    }

    private func pageTurnNavigation(
        _ session: PageTurnSession,
        options: NavigatorGoOptions,
        target: Locator?
    ) -> (() async -> Bool)? {
        if let pageTurnNavigationForTesting {
            return {
                await pageTurnNavigationForTesting(session, target)
            }
        }
        guard let paginationView else { return nil }

        if let target,
           let resourceIndex = readingOrder.firstIndexWithHREF(target.href),
           let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex) {
            return {
                await paginationView.goToIndex(
                    spreadIndex,
                    location: .locator(target),
                    options: options
                )
            }
        }

        let spreadView = paginationView.currentView as? EPUBSpreadView
        let currentSpreadIndex = currentSpreadIndex
        let isRTL = (session.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        return {
            if let spreadView,
               await spreadView.go(to: session.direction, options: options) {
                return true
            }
            switch session.direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndex(
                    currentSpreadIndex - delta,
                    location: location,
                    options: options
                )
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndex(
                    currentSpreadIndex + delta,
                    location: location,
                    options: options
                )
            }
        }
    }

    private func finishPageTurn(_ session: PageTurnSession) {
        guard pageTurnController.finish(session) else { return }
        if pageTurnPanSession?.id == session.id {
            pageTurnPanSession = nil
        }
        on(.moved)
    }

    private func commitPageTurn(
        _ session: PageTurnSession,
        options: NavigatorGoOptions
    ) async -> Bool {
        await pageTurnController.commit(session) { [self] in
            defer { finishPageTurn(session) }
            let moved = await performPageTurn(session, options: options)
            guard moved else { return false }
            return await publishCurrentLocation()
        }
    }

    private func runPageTurn(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions
    ) async -> Bool {
        guard let session = beginPageTurn(to: direction) else { return false }
        guard !Task.isCancelled else {
            finishPageTurn(session)
            return false
        }

        return await commitPageTurn(session, options: options)
    }

    private func turnWithPageSurface(
        to direction: EPUBSpreadView.Direction,
        style: EPUBPageTurnStyle,
        target: Locator? = nil
    ) async -> Bool {
        guard let session = beginPageTurn(to: direction) else { return false }
        guard !Task.isCancelled else {
            finishPageTurn(session)
            return false
        }
        guard beginPageTurnSurface(session, style: style) else {
            finishPageTurn(session)
            return false
        }
        pageTurnSurfaceTargetLocator = target
        let preparation = Task { @MainActor [weak self] in
            await Self.preparePageTurnSurface(session) { [weak self] in self }
        }
        pageTurnPreparationTask = preparation
        let prepared = await preparation.value
        if let resolution = pageTurnResolutionTask {
            return await resolution.value
        }
        guard prepared else {
            return await cancelPageTurnSurface(session)
        }
        guard !Task.isCancelled else {
            return await cancelPageTurnSurface(session)
        }
        return await commitPageTurnSurface(session, progress: 0)
    }

    private func beginPageTurnSurface(
        _ session: PageTurnSession,
        style: EPUBPageTurnStyle
    ) -> Bool {
        guard pageTurnSurfaceAnimator == nil else { return false }
        isInstallingPageTurnSurface = true
        defer { isInstallingPageTurnSurface = false }
        guard
            let animator = EPUBPageTurnSurfaceAnimator(
                rootViewProvider: { [weak self] in
                    guard let self else { return nil }
                    return (self.delegate?.pageTurnRootView(for: self) ?? nil)
                        ?? self.view
                },
                documentView: view,
                style: style,
                physicalCompletionDirection: session.physicalCompletionDirection
            )
        else {
            return false
        }
        pageTurnSurfaceAnimator = animator
        pageTurnSurfaceStyle = style
        pageTurnSurfaceProgress = 0
        pageTurnSurfaceDidPrepareTarget = false
        pageTurnSurfaceOriginalPreview = nil
        pageTurnSurfaceTargetPreview = nil
        return true
    }

    private func calculatePageTurnPreview() async -> PageTurnPreview? {
        let result = if let pageTurnPreviewCalculationForTesting {
            await pageTurnPreviewCalculationForTesting()
        } else {
            await computeCurrentLocationAndViewport()
        }
        guard let location = result.0, let viewport = result.1 else {
            return nil
        }
        return PageTurnPreview(location: location, viewport: viewport)
    }

    private func waitForPageTurnPreview() async -> PageTurnPreview? {
        for _ in 0 ..< 60 {
            if let preview = await calculatePageTurnPreview() {
                return preview
            }
            await waitForPageTurnDisplayFrame()
        }
        return nil
    }

    private func waitForPageTurnDisplayFrame() async {
        if let pageTurnDisplayFrameWaiterForTesting {
            await pageTurnDisplayFrameWaiterForTesting()
        } else {
            await PageTurnAnimationFrameWaiter.wait()
        }
    }

    private func waitForPageTurnDisplayFrames() async {
        await waitForPageTurnDisplayFrame()
        await waitForPageTurnDisplayFrame()
    }

    private static func preparePageTurnSurface(
        _ session: PageTurnSession,
        navigator: @escaping @MainActor () -> EPUBNavigatorViewController?
    ) async -> Bool {
        guard navigator()?.pageTurnController.isTracking(session) == true else {
            return false
        }
        guard navigator()?.pageTurnSurfaceAnimator?.hasMatchingCurrentRootIdentity == true
            || navigator()?.pageTurnSurfaceAnimator?.recaptureCurrent() == true
        else {
            return false
        }
        guard let originalPreview = await navigator()?.waitForPageTurnPreview() else {
            return false
        }
        navigator()?.pageTurnSurfaceOriginalPreview = originalPreview
        guard let navigation = navigator()?.pageTurnNavigation(
            session,
            options: .none,
            target: navigator()?.pageTurnSurfaceTargetLocator
        )
        else {
            return false
        }
        if let owner = navigator(),
           let coldTarget = owner.coldPageTurnTargetIndexForTesting {
            owner.didBeginWithColdTargetForTesting =
                owner.paginationView?.loadedViews[coldTarget] == nil
        }
        let moved = await navigation()
        guard let owner = navigator() else { return false }
        owner.pageTurnPreparationTask = nil
        guard moved, owner.pageTurnController.isTracking(session) else { return false }
        owner.pageTurnSurfaceDidPrepareTarget = true

        guard let targetPreview = await owner.waitForPageTurnPreview() else {
            return false
        }
        if let coldTarget = owner.coldPageTurnTargetIndexForTesting {
            owner.didNavigateColdTargetForTesting =
                owner.didBeginWithColdTargetForTesting
                && owner.paginationView?.currentIndex == coldTarget
                && owner.paginationView?.loadedViews[coldTarget] != nil
        }
        owner.pageTurnSurfaceTargetPreview = targetPreview
        owner.delegate?.navigator(
            owner,
            previewLocationDidChange: targetPreview.location,
            viewport: targetPreview.viewport
        )
        await owner.waitForPageTurnDisplayFrames()
        guard owner.pageTurnController.isTracking(session) else { return false }
        guard owner.capturePageTurnTargetSurface() else { return false }
        if owner.isColdPageTurnArmedForTesting {
            owner.didCaptureAfterColdNavigationForTesting =
                owner.didNavigateColdTargetForTesting
                && owner.pageTurnSurfaceAnimator?.hasTarget == true
        }
        await owner.waitForPageTurnDisplayFrames()
        guard await owner.matchPageTurnSurfaceIdentities() else { return false }
        owner.pageTurnSurfaceAnimator?.render(progress: owner.pageTurnSurfaceProgress)
        return true
    }

    private func capturePageTurnTargetSurface() -> Bool {
        isInstallingPageTurnSurface = true
        defer { isInstallingPageTurnSurface = false }
        return pageTurnSurfaceAnimator?.captureTarget() == true
    }

    private func matchPageTurnSurfaceIdentities() async -> Bool {
        guard let animator = pageTurnSurfaceAnimator else { return false }
        guard animator.hasMatchingCurrentRootIdentity else { return false }
        for _ in 0 ..< 3 {
            guard !animator.hasMatchingTargetRootIdentity else { return true }
            guard animator.recaptureTarget() else { return false }
            await waitForPageTurnDisplayFrames()
            guard animator.hasMatchingCurrentRootIdentity else { return false }
        }
        return animator.hasMatchingTargetRootIdentity
    }

    private func matchCommittedPageTurnSurfaceIdentity() async -> Bool {
        guard let animator = pageTurnSurfaceAnimator else { return false }
        for _ in 0 ..< 3 {
            guard !animator.hasMatchingTargetRootIdentity else { return true }
            guard animator.recaptureCommittedTarget() else { return false }
            await waitForPageTurnDisplayFrames()
        }
        return animator.hasMatchingTargetRootIdentity
    }

    private func commitPageTurnSurface(
        _ session: PageTurnSession,
        progress: CGFloat
    ) async -> Bool {
        guard let animator = pageTurnSurfaceAnimator else { return false }
        guard await matchPageTurnSurfaceIdentities() else {
            return await cancelPageTurnSurface(session)
        }
        let remaining = 1 - min(max(progress, 0), 1)
        return await pageTurnController.commit(session) { [self] in
            var canCleanup = false
            defer {
                if canCleanup {
                    cleanupPageTurnSurface(session)
                }
                finishPageTurn(session)
            }
            await animator.animate(to: 1, duration: 0.32 * remaining)
            await waitForPageTurnDisplayFrames()
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Page-turn surface identity changed after commit; retaining the surface.")
                canCleanup = await recoverOriginalPageTurnAfterCommitFailure(animator)
                return false
            }
            guard let targetPreview = pageTurnSurfaceTargetPreview else {
                canCleanup = await recoverOriginalPageTurnAfterCommitFailure(animator)
                return false
            }
            delegate?.navigator(
                self,
                previewLocationDidChange: targetPreview.location,
                viewport: targetPreview.viewport
            )
            await waitForPageTurnDisplayFrames()
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Page-turn surface identity changed before publication; retaining the surface.")
                canCleanup = await recoverOriginalPageTurnAfterCommitFailure(animator)
                return false
            }
            let published = await publishPageTurnLocation()
            guard published else {
                log(.error, "Failed to publish the committed page-turn location.")
                canCleanup = await recoverOriginalPageTurnAfterCommitFailure(animator)
                return false
            }
            if let target = pageTurnSurfaceTargetLocator {
                delegate?.navigator(self, didJumpTo: target)
            }
            await waitForPageTurnDisplayFrames()
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Page-turn surface identity changed before cleanup; retaining the published target surface.")
                return false
            }
            canCleanup = true
            return true
        }
    }

    private func recoverOriginalPageTurnAfterCommitFailure(
        _ animator: EPUBPageTurnSurfaceAnimator
    ) async -> Bool {
        guard
            let originalPreview = pageTurnSurfaceOriginalPreview,
            await restorePageTurnOriginalLocation(),
            await waitForStablePageTurnLiveView(at: originalPreview.location)
        else {
            animator.render(progress: 0)
            return false
        }
        delegate?.navigator(
            self,
            previewLocationDidChange: originalPreview.location,
            viewport: originalPreview.viewport
        )
        await waitForPageTurnDisplayFrames()
        animator.render(progress: 0)
        guard animator.recaptureCurrent() else {
            return false
        }
        return animator.hasMatchingCurrentRootIdentity
    }

    private func restorePageTurnSurface(_ session: PageTurnSession) async -> Bool {
        let animator = pageTurnSurfaceAnimator
        return await pageTurnController.restoreCover(
            session,
            rebound: { [self] _ in
                await animator?.animate(to: 0, duration: 0.18)
                var restored = true
                if pageTurnSurfaceDidPrepareTarget {
                    let inverse = PageTurnSession(
                        direction: session.direction == .left ? .right : .left,
                        readingProgression: session.readingProgression
                    )
                    restored = await pageTurnController.restorePreparedPage(
                        inverse: { [self] in
                            await performPageTurn(inverse, options: .none)
                        },
                        validateOriginalLocation: { [self] in
                            await waitForStablePageTurnLiveView(
                                at: pageTurnSurfaceOriginalPreview?.location
                            )
                        },
                        originalLocation: { [self] in
                            await restorePageTurnOriginalLocation()
                        }
                    )
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
                    await waitForPageTurnDisplayFrames()
                } else if restored {
                    await waitForPageTurnDisplayFrames()
                }
                if restored {
                    restored = animator?.recaptureCurrent() == true
                }
                return restored
            },
            cleanup: { [self] in
                cleanupPageTurnSurface(session)
            },
            finish: { [self] session in
                finishPageTurn(session)
            }
        )
    }

    private func cancelPageTurnSurface(_ session: PageTurnSession) async -> Bool {
        if !(await restorePageTurnSurface(session)) {
            await releaseFailedPageTurnRestore(session)
        }
        return false
    }

    private func restorePageTurnOriginalLocation() async -> Bool {
        guard
            let originalLocation = pageTurnSurfaceOriginalPreview?.location,
            let paginationView,
            let resourceIndex = readingOrder.firstIndexWithHREF(originalLocation.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(resourceIndex)
        else {
            return false
        }
        return await paginationView.goToIndex(
            spreadIndex,
            location: .locator(originalLocation),
            options: .none
        )
    }

    private struct PageTurnLiveGeometry: Equatable {
        let rootFrame: CGRect
        let rootBounds: CGRect
        let documentFrame: CGRect
        let contentOffset: CGPoint
    }

    private func waitForStablePageTurnLiveView(at location: Locator?) async -> Bool {
        guard let location else { return false }
        var previous: PageTurnLiveGeometry?
        for _ in 0 ..< 60 {
            await PageTurnAnimationFrameWaiter.wait()
            let (current, _) = await computeCurrentLocationAndViewport()
            guard
                current?.href.isEquivalentTo(location.href) == true,
                current?.locations == location.locations
            else {
                previous = nil
                continue
            }
            guard let rootView = (delegate?.pageTurnRootView(for: self) ?? nil) ?? view else {
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

    private func cancelActivePageTurn() {
        guard let session = pageTurnPanSession ?? pageTurnController.activeSession else { return }
        if pageTurnSurfaceAnimator == nil,
           pageTurnPreparationTask == nil,
           pageTurnController.invalidatePreCommitSession()?.id == session.id {
            pageTurnPanSession = nil
            pageTurnSurfaceStyle = nil
            on(.moved)
            return
        }
        startPageTurnResolution(session, shouldCommit: false)
    }

    private func releaseFailedPageTurnRestore(_ session: PageTurnSession) async {
        guard pageTurnController.isTracking(session) else { return }
        guard
            pageTurnSurfaceDidPrepareTarget,
            let animator = pageTurnSurfaceAnimator,
            let targetPreview = pageTurnSurfaceTargetPreview
        else {
            if
                pageTurnSurfaceDidPrepareTarget,
                let animator = pageTurnSurfaceAnimator,
                !(await recoverOriginalPageTurnAfterCommitFailure(animator))
            {
                animator.render(progress: 0)
                finishPageTurn(session)
                return
            }
            await waitForPageTurnDisplayFrames()
            cleanupPageTurnSurface(session)
            finishPageTurn(session)
            return
        }
        _ = await pageTurnController.commit(session) { [self] in
            var canCleanup = false
            defer {
                if canCleanup {
                    cleanupPageTurnSurface(session)
                }
                finishPageTurn(session)
            }
            await animator.animate(to: 1, duration: 0.18)
            delegate?.navigator(
                self,
                previewLocationDidChange: targetPreview.location,
                viewport: targetPreview.viewport
            )
            await waitForPageTurnDisplayFrames()
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Failed to recover the target page-turn surface identity.")
                return false
            }
            let published = await publishPageTurnLocation()
            guard published else {
                log(.error, "Failed to publish the recovered page-turn location.")
                canCleanup = await recoverOriginalPageTurnAfterCommitFailure(animator)
                return false
            }
            if let target = pageTurnSurfaceTargetLocator {
                delegate?.navigator(self, didJumpTo: target)
            }
            await waitForPageTurnDisplayFrames()
            guard await matchCommittedPageTurnSurfaceIdentity() else {
                log(.error, "Recovered page-turn identity changed before cleanup.")
                return false
            }
            canCleanup = true
            return true
        }
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
        pageTurnSurfaceStyle = nil
        pageTurnSurfaceProgress = 0
        pageTurnSurfaceDidPrepareTarget = false
        pageTurnSurfaceOriginalPreview = nil
        pageTurnSurfaceTargetPreview = nil
        pageTurnSurfaceTargetLocator = nil
        pageTurnPreparationTask = nil
        pageTurnResolutionTask = nil
        coldPageTurnTargetIndexForTesting = nil
        isColdPageTurnArmedForTesting = false
    }

    private func goUsingExistingPath(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions
    ) async -> Bool {
        guard
            let paginationView,
            on(.move(direction))
        else {
            return false
        }

        if
            let spreadView = paginationView.currentView as? EPUBSpreadView,
            await spreadView.go(to: direction, options: options)
        {
            on(.moved)
            return true
        }

        let isRTL = (viewModel.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        let moved: Bool = await {
            switch direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndex(currentSpreadIndex - delta, location: location, options: options)
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndex(currentSpreadIndex + delta, location: location, options: options)
            }
        }()

        on(.moved)
        return moved
    }

    /// Goes to the next or previous page in the given scroll direction.
    private func go(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions
    ) async -> Bool {
        let accessibilityStatus = accessibilityStatusProvider()
        let style = effectivePageTurnStyle(
            userStyle: pageTurnStyle,
            isReduceMotionEnabled: accessibilityStatus.isReduceMotionEnabled,
            isVoiceOverRunning: accessibilityStatus.isVoiceOverRunning
        )
        snapshotProvider.invalidate()
        return await routePageTurn(
            to: direction,
            options: options,
            axis: paginationView?.axis,
            isReduceMotionEnabled: accessibilityStatus.isReduceMotionEnabled,
            isVoiceOverRunning: accessibilityStatus.isVoiceOverRunning,
            usingExistingPath: { [self] direction, options in
                await goUsingExistingPath(to: direction, options: options)
            },
            usingPageTurn: { [self] direction, options in
                if style == .push, options.animated {
                    return await turnWithPageSurface(to: direction, style: .push)
                }
                return await runPageTurn(to: direction, options: options)
            },
            usingCover: { [self] direction, options in
                if options.animated {
                    return await turnWithPageSurface(to: direction, style: .cover)
                }
                return await runPageTurn(to: direction, options: options)
            }
        )
    }

    func routePageTurn(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        axis: PaginationView.Axis?,
        isReduceMotionEnabled: Bool,
        isVoiceOverRunning: Bool,
        usingExistingPath: (EPUBSpreadView.Direction, NavigatorGoOptions) async -> Bool,
        usingPageTurn: (EPUBSpreadView.Direction, NavigatorGoOptions) async -> Bool,
        usingCover: (EPUBSpreadView.Direction, NavigatorGoOptions) async -> Bool
    ) async -> Bool {
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
        case .none, .simulation:
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

        _reloadSpreads()
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
            self?.drainSnapshotMutations()
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
    ) -> Bool {
        guard
            pageTurnPanSession == nil,
            let session = beginPageTurn(to: direction)
        else {
            return false
        }
        pageTurnPanSession = session
        guard beginPageTurnSurface(session, style: .cover) else {
            finishPageTurn(session)
            return false
        }
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
    ) -> Bool {
        beginPageTurn(to: direction) != nil
    }

    var isPageTurnIdleForTesting: Bool {
        pageTurnController.isIdle
            && pageTurnPanSession == nil
            && pageTurnSurfaceAnimator == nil
    }

    var isPageTurnControllerIdleForTesting: Bool {
        pageTurnController.isIdle && pageTurnPanSession == nil
    }

    var isPageTurnCommittingForTesting: Bool {
        pageTurnController.isCommitting
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

    func canBeginPageTurnPanForTesting() -> Bool {
        shouldBeginPageTurnPan()
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
        let accessibilityStatus = accessibilityStatusProvider()
        let style = effectivePageTurnStyle(
            userStyle: pageTurnStyle,
            isReduceMotionEnabled: accessibilityStatus.isReduceMotionEnabled,
            isVoiceOverRunning: accessibilityStatus.isVoiceOverRunning
        )
        return EPUBPageTurnInteraction.policy(axis: axis, style: style)
    }

    private func accessibilityStatusDidChange() {
        cancelActivePageTurn()
        updatePageTurnInteractionMode()
    }

    private func updatePageTurnInteractionMode() {
        guard let paginationView else { return }
        let policy = pageTurnInteractionPolicy(for: paginationView.axis)
        paginationView.allowsNativeHorizontalPaging = policy.allowsNativeHorizontalPaging
        for view in paginationView.loadedViews.values {
            (view as? EPUBSpreadView)?.allowsNativeHorizontalPaging = policy.allowsNativeHorizontalPaging
        }
        let usesPageTurnPan = paginationView.axis == .horizontalPaged
            && currentEffectivePageTurnStyle() != .simulation
        if usesPageTurnPan {
            if pageTurnPanGestureRecognizer.view == nil {
                view.addGestureRecognizer(pageTurnPanGestureRecognizer)
            }
        } else {
            cancelActivePageTurn()
            if pageTurnPanGestureRecognizer.view != nil {
                view.removeGestureRecognizer(pageTurnPanGestureRecognizer)
            }
        }
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

    private func shouldBeginPageTurnPan() -> Bool {
        guard
            let paginationView,
            paginationView.axis == .horizontalPaged,
            currentEffectivePageTurnStyle() != .simulation,
            pageTurnPanSession == nil,
            state == .idle,
            pageTurnController.isIdle,
            currentSelection == nil,
            !((paginationView.currentView as? EPUBSpreadView)?.hasActiveMedia ?? false),
            !((paginationView.currentView as? EPUBSpreadView)?.hasActiveInteractivePointer ?? false),
            (paginationView.currentView as? EPUBSpreadView)?.allowsPageTurn != false
        else {
            return false
        }

        return true
    }

    private func beginPageTurnPan(
        to direction: EPUBSpreadView.Direction
    ) -> Bool {
        guard
            shouldBeginPageTurnPan(),
            let session = beginPageTurn(to: direction)
        else {
            return false
        }
        let style = currentEffectivePageTurnStyle()
        pageTurnPanSession = session
        pageTurnSurfaceStyle = style
        guard style == .none || beginPageTurnSurface(session, style: style) else {
            finishPageTurn(session)
            return false
        }
        if style != .none {
            pageTurnPreparationTask = Task { @MainActor [weak self] in
                await Self.preparePageTurnSurface(session) { [weak self] in self }
            }
        }
        return true
    }

    private func startPageTurnResolution(
        _ session: PageTurnSession,
        shouldCommit: Bool
    ) {
        guard pageTurnResolutionTask == nil else { return }
        let preparation = pageTurnPreparationTask
        let style = pageTurnSurfaceStyle ?? .none
        pageTurnResolutionTask = Task { @MainActor [weak self] in
            let preparationResult: Bool? = if style == .none {
                nil
            } else {
                await preparation?.value
            }
            guard let self else { return false }
            self.pageTurnResolutionTask = nil
            let result: Bool
            if style == .none {
                if shouldCommit {
                    result = await self.commitPageTurn(session, options: .none)
                } else {
                    self.finishPageTurn(session)
                    result = false
                }
            } else {
                let prepared = preparationResult
                    ?? self.pageTurnSurfaceAnimator?.hasTarget == true
                if shouldCommit, prepared {
                    result = await self.commitPageTurnSurface(
                        session,
                        progress: self.pageTurnSurfaceProgress
                    )
                } else {
                    let restored = await self.restorePageTurnSurface(session)
                    if !restored {
                        await self.releaseFailedPageTurnRestore(session)
                    }
                    result = false
                }
            }
            return result
        }
    }

    private func handlePageTurnPan(
        state: UIGestureRecognizer.State,
        translationX: CGFloat,
        velocityX: CGFloat
    ) {
        switch state {
        case .began:
            let velocity = CGPoint(x: velocityX, y: 0)
            let direction = if currentEffectivePageTurnStyle() == .none {
                EPUBPageTurnInteraction.direction(
                    for: velocity,
                    readingProgression: viewModel.readingProgression
                )
            } else {
                EPUBPageTurnInteraction.coverDirection(for: velocity)
            }
            guard let direction else { return }
            _ = beginPageTurnPan(to: direction)

        case .changed:
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
            startPageTurnResolution(session, shouldCommit: shouldCommit)

        case .cancelled, .failed:
            guard let session = pageTurnPanSession else { return }
            startPageTurnResolution(session, shouldCommit: false)

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

    private func computeCurrentLocationAndViewport() async -> (Locator?, NavigatorViewport?) {
        if case .initializing = state {
            assertionFailure("Cannot update current location when initializing the navigator")
            return (nil, nil)
        }

        // Returns any pending locator to prevent returning invalid locations
        // while loading it.
        if let pendingLocator = state.pendingLocator {
            return (pendingLocator, nil)
        }

        guard let paginationView else {
            return (nil, nil)
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
                return (nil, nil)
            }

            return await EPUBViewportAndLocationCalculator.compute(
                readingOrderIndices: firstIndex ... lastIndex,
                progression: { progressions[$0] ?? 0 ... 0 },
                readingOrder: readingOrder,
                positionsByReadingOrder: positionsByReadingOrder,
                tableOfContentsTitleByHref: tableOfContentsTitleByHref,
                fallbackLocator: { [publication] in await publication.locate($0) }
            )
        }

        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return (nil, nil)
        }

        let (locator, viewport) = await EPUBViewportAndLocationCalculator.compute(
            readingOrderIndices: spreadView.spread.readingOrderIndices,
            progression: { spreadView.progression(in: $0) },
            readingOrder: readingOrder,
            positionsByReadingOrder: positionsByReadingOrder,
            tableOfContentsTitleByHref: tableOfContentsTitleByHref,
            fallbackLocator: { [publication] in await publication.locate($0) }
        )
        return (locator, viewport)
    }

    public func firstVisibleElementLocator() async -> Locator? {
        guard let paginationView else {
            return nil
        }

        if paginationView.axis == .verticalContinuous {
            for index in paginationView.visibleIndices {
                guard
                    let spreadView = paginationView.loadedViews[index] as? EPUBReflowableSpreadView,
                    let visibleFrame = paginationView.visibleFrame(at: index)
                else {
                    continue
                }
                return await spreadView.findFirstVisibleElementLocator(in: visibleFrame)
            }
            return nil
        }

        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return nil
        }
        return await spreadView.findFirstVisibleElementLocator()
    }

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?

    private func publishPageTurnLocation() async -> Bool {
        if let pageTurnLocationCalculationForTesting {
            return await publishCurrentLocation(
                calculating: pageTurnLocationCalculationForTesting
            )
        }
        return await publishCurrentLocation()
    }

    @discardableResult
    private func publishCurrentLocation() async -> Bool {
        await publishCurrentLocation(calculating: computeCurrentLocationAndViewport)
    }

    @discardableResult
    func publishCurrentLocation(
        calculating calculate: () async -> (Locator?, NavigatorViewport?)
    ) async -> Bool {
        let (location, newViewport) = await calculate()

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

    private lazy var updateCurrentLocation = execute(
        // If we're not in an `idle` state, we postpone the notification.
        when: { [weak self] in self?.state == .idle },
        pollingInterval: 0.1
    ) { [weak self] in
        guard let self else { return }
        await performCurrentLocationRefresh()
    }

    private func performCurrentLocationRefresh() async {
        await performCurrentLocationRefresh(calculating: computeCurrentLocationAndViewport)
    }

    func performCurrentLocationRefresh(
        calculating calculate: () async -> (Locator?, NavigatorViewport?)
    ) async {
        guard !isCurrentLocationRefreshRunning else { return }
        isCurrentLocationRefreshRunning = true
        await publishCurrentLocation(calculating: calculate)
        isCurrentLocationRefreshRunning = false
        let waiters = currentLocationRefreshWaiters
        currentLocationRefreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
        if !pageTurnController.isCommitting {
            cancelActivePageTurn()
        }
        if let resolution = pageTurnResolutionTask {
            _ = await resolution.value
        }
        await pageTurnController.settle { [weak self] session in
            guard let self else { return }
            if !(await restorePageTurnSurface(session)) {
                await releaseFailedPageTurnRestore(session)
            }
        }
        await snapshotProvider.settle()
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
        await snapshotProvider.settle()
        snapshotProvider.invalidate()
        let locator = publication.normalizeLocator(locator)

        if options.animated,
           paginationView?.axis == .horizontalPaged,
           let direction = pageTurnDirection(from: options) {
            switch currentEffectivePageTurnStyle() {
            case .push:
                return await turnWithPageSurface(
                    to: direction,
                    style: .push,
                    target: locator
                )
            case .cover:
                return await turnWithPageSurface(
                    to: direction,
                    style: .cover,
                    target: locator
                )
            case .none, .simulation:
                break
            }
        }

        guard
            let paginationView = paginationView,
            let index = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(index),
            on(.jump(locator))
        else {
            return false
        }

        let success = await paginationView.goToIndex(spreadIndex, location: .locator(locator), options: options)
        on(.jumped)
        if success {
            delegate?.navigator(self, didJumpTo: locator)
        }
        return success
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        guard let locator = await publication.locate(link) else {
            return false
        }
        return await go(to: locator, options: options)
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
        guard let locator else {
            viewModel.editingActions.selection = nil
            return
        }
        viewModel.editingActions.selection = Selection(
            locator: locator,
            frame: view.convert(frame, from: spreadView)
        )
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
            cancelActivePageTurn()
        } else if currentSelection == nil {
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

    func spreadViewDidTerminate() {
        reloadSpreads()
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
        let velocity = panGestureRecognizer.velocity(in: view)
        let direction = if currentEffectivePageTurnStyle() == .none {
            EPUBPageTurnInteraction.direction(
                for: velocity,
                readingProgression: viewModel.readingProgression
            )
        } else {
            EPUBPageTurnInteraction.coverDirection(for: velocity)
        }
        return direction != nil && shouldBeginPageTurnPan()
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
