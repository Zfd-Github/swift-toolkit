# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose and toolchain

Readium Swift Toolkit is an iOS library suite for opening and rendering EPUB, PDF, audiobook, comic, and Readium Web Publication content, plus OPDS and Readium LCP support. The package targets iOS 15.0. CI uses Xcode 16.4/Swift 6 on macOS 15; `Package.swift` uses Swift tools 5.10.

The build and test commands assume XcodeGen and `xcbeautify` are installed. EPUB JavaScript work additionally requires Node 20, Corepack, and pnpm. Because the package imports UIKit, use an iOS Simulator destination rather than a plain host-platform `swift build`.

`TestApp/TestApp.xcodeproj` is generated, not source-controlled. Generate or refresh the local-development project after pulling project-definition changes:

```sh
(cd TestApp && make dev)
```

Do not edit generated Xcode projects directly; edit their XcodeGen YAML under `TestApp/Integrations/`, `Playground/project.yml`, or `Tests/NavigatorTests/UITests/project.yml`.

## Build and test commands

```sh
# Build all Swift package products for an iOS simulator.
xcodebuild build -scheme Readium-Package \
  -destination 'platform=iOS Simulator,name=iPad (A16)'

# Build the generated Test App using the local package checkout.
(cd TestApp && make dev)
xcodebuild build -project TestApp/TestApp.xcodeproj -scheme TestApp \
  -destination 'platform=iOS Simulator,name=iPad (A16)'

# Run the full unit-test plan. Tests are intentionally serialized.
scripts/test.sh

# Run one test target.
scripts/test.sh ReadiumSharedTests

# Run one suite or test. The argument is passed to xcodebuild -only-testing.
scripts/test.sh 'ReadiumNavigatorTests/EPUBPageTurnControllerTests'
scripts/test.sh 'ReadiumNavigatorTests/EPUBPageTurnControllerTests/activeDeadlineReleasesInteractivePageTurnWaiter()'

# Repeated Navigator test runs with a per-run watchdog and quiescence check.
scripts/test-navigator-stability.sh 10

# Generate and run the separately maintained Navigator UI-test project.
make navigator-ui-tests-project
xcodebuild test \
  -project Tests/NavigatorTests/UITests/NavigatorUITests.xcodeproj \
  -scheme NavigatorTestHost \
  -destination 'platform=iOS Simulator,name=iPad (A16)'
```

`ReadiumLCPTests` are not part of `Package.swift`; they require EDRLab's private `R2LCPClient.framework`. `Tests/NavigatorTests/UITests` is likewise excluded from the Swift package test target and must use its generated project.

## Formatting, linting, and generated files

```sh
# Check or apply SwiftFormat using BuildTools/Package.swift.
make lint-format
make format

# Check EPUB JavaScript without regenerating bundles.
pnpm --dir Sources/Navigator/EPUB/Scripts install --frozen-lockfile
pnpm --dir Sources/Navigator/EPUB/Scripts run lint
pnpm --dir Sources/Navigator/EPUB/Scripts run checkformat

# Format, lint, and bundle EPUB JavaScript into Navigator resources.
make scripts

# Regenerate other checked artifacts used by CI.
make podspecs
make playground
```

The JavaScript source of truth is `Sources/Navigator/EPUB/Scripts/src/`. SwiftPM excludes the `Scripts` workspace and ships the generated files in `Sources/Navigator/EPUB/Assets/Static/scripts/`; after changing JavaScript, run `make scripts` and commit both source and bundle changes. CI also verifies that `Support/CocoaPods/` and `Playground/.xcodegen` match their generators.

## Architecture

### Package boundaries

`Package.swift` defines independently consumable library products with `ReadiumShared` as the common foundation:

- **ReadiumInternal** (`Sources/Internal`) contains implementation utilities shared by toolkit modules but not exposed as a product.
- **ReadiumShared** (`Sources/Shared`) owns the cross-format domain and I/O abstractions: `Publication`, `Manifest`, `Link`, `Locator`, `Resource`, `Container`, HTTP access, format sniffing, assets, and publication services.
- **ReadiumStreamer** (`Sources/Streamer`) turns an `Asset` into a `Publication`. It parses packages/manifests but does not render them.
- **ReadiumNavigator** (`Sources/Navigator`) renders an already-opened `Publication` and exposes common navigation, selection, decoration, viewport, and preference APIs.
- **ReadiumOPDS** (`Sources/OPDS`) parses OPDS 1 XML and OPDS 2 JSON catalogs into models built on `ReadiumShared`; catalog acquisition is separate from publication opening.
- **ReadiumLCP** (`Sources/LCP`) implements LCP licensing and the shared `ContentProtection` extension point. Its private cryptographic client is supplied by the integrating app.
- **Adapters** (`Sources/Adapters`) connect shared interfaces to GCDWebServer and SQLite without forcing those dependencies into the core products.

Tests mirror these boundaries under `Tests/*Tests`; `Tests/Publications` is a resource target shared by several test targets. `TestApp` is the full integration example, while `Playground/Sources/Recipes` contains smaller API-focused examples.

### Publication opening flow

The central data flow is:

1. `AssetRetriever` (`ReadiumShared`) retrieves a local or remote URL, sniffs its format, and returns a resource or container `Asset`.
2. `PublicationOpener` (`ReadiumStreamer`) passes the asset through configured `ContentProtection` implementations, then into a `PublicationParser`.
3. `DefaultPublicationParser` tries EPUB, PDF, Readium Web Publication, image, and audio parsers through `CompositePublicationParser`.
4. A parser produces `Publication.Builder`; opener-level and protection-level transforms can alter its manifest, container, and service factories before `build()` creates the `Publication`.
5. The resulting `Publication` combines a `Manifest`, a resource `Container`, and `PublicationService` instances. Services provide or override resources and capabilities such as positions, content extraction, search, cover, locators, and content-protection state.

`TestApp/Sources/App/Readium.swift` is the canonical composition root: it creates the HTTP client, `AssetRetriever`, `DefaultPublicationParser`, `PublicationOpener`, and optional LCP content protection. Keep these dependency boundaries intact—Navigator consumes `Publication` and should not become responsible for retrieval or parsing.

### Navigator model

`Navigator` is the format-neutral location and movement API based on `Locator`; `VisualNavigator` adds UIKit presentation and direction-aware movement. Capabilities are split into protocols such as `SelectableNavigator`, `DecorableNavigator`, `Configurable`, `ViewportObservingNavigator`, and `InputObservable` so format implementations expose only what they support.

Format-specific implementations live under `Sources/Navigator/EPUB`, `PDF`, `Audiobook`, and `CBZ`. EPUB and PDF are UIKit view controllers; audiobook navigation coordinates playback rather than a document view. Preferences are modeled separately under `Sources/Navigator/Preferences` and applied through `Configurable` implementations.

The EPUB navigator spans native Swift and bundled JavaScript:

- `EPUBNavigatorViewController` owns navigation state, current `Locator`, preference/decorations integration, and the pagination/page-turn lifecycle.
- `PaginationView` manages loaded reading-order spreads; `EPUBReflowableSpreadView` and `EPUBFixedSpreadView` specialize `EPUBSpreadView` and host web content.
- Scripts under `Sources/Navigator/EPUB/Scripts/src` run in the web view and communicate with the Swift spread/navigator layer. A change to bridge contracts normally requires coordinated Swift, JavaScript, generated bundle, and Navigator test updates.
- Page-turn behavior is split under `Sources/Navigator/EPUB/PageTurn`; lifecycle, snapshot, and transaction tests are concentrated in `Tests/NavigatorTests/EPUB` and stress/UI coverage in `Tests/NavigatorTests/UITests`.

## Code navigation

This repository has a CodeGraph index and an always-applied rule in `.cursor/rules/codegraph.mdc`:

- Use CodeGraph first for structural questions: symbol definitions, callers/callees, call paths, impact, and directory structure.
- Start broad architecture or feature questions with `codegraph_context`, then use one focused `codegraph_explore`; use `codegraph_trace` first for a specific flow from one symbol to another.
- Use native text search only for literal strings/comments or after locating a specific file. Do not re-verify CodeGraph results with grep.
- The index watcher lags writes by roughly one second. If `.codegraph/` is not initialized, ask before running `codegraph init -i`.

## Fork branch maintenance

- 所有 Hometail fork 修改必须进入唯一长期维护分支 `hometail/readium-3.11`；`hometail/readium-3.10` 仅保留为升级前基线，不再接收修改。
- 不创建、使用或推送 `codex/*` 分支；推送时只推送 `hometail/readium-3.11`。
