# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Helm

Helm is a native macOS Git client written in Swift (AppKit/SwiftUI hybrid), using **libgit2** for Git operations via a C bridging header.

## Setup

```bash
git submodule update --init --recursive
brew install libgit2          # installs to /usr/local, required for build
```

**Code signing:** Either delete the "Code Signing Identity" build setting in the Application target, or create `Xcode-config/DEVELOPMENT_TEAM.xcconfig` with:
```
DEVELOPMENT_TEAM = <Your TeamID>
```

On Apple Silicon, set the build destination to "My Mac" (not Rosetta).

If libgit2 needs rebuilding from source: `./build_libgit2.sh`

## Build & Test

```bash
# Build
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug build

# Run all tests
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug test

# Run a single test class
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug test -only-testing:HelmTests/SidebarDataModelTest

# Lint (runs automatically on build if SwiftLint is installed)
swiftlint lint Helm/
```

## Architecture

Three-layer architecture with strict separation:

```
UI Layer (AppKit/SwiftUI)
  RepoDocument, HelmWindowController, view controllers, SwiftUI dialogs
        ↓
Controller Layer
  GitRepositoryController — task queue, caching, file watchers, Combine publishers
  RepositoryUIController  — UI coordination protocol (selection, window state)
        ↓
Repository Layer  (Helm/Repository/)
  HelmRepository — wraps libgit2's git_repository pointer
  Protocol hierarchy — capabilities split into focused protocols
```

### Protocol-Oriented Repository

Repository capabilities are split into composable protocols, all combined into `FullRepository`:

```swift
typealias FullRepository =
    BasicRepository & Branching & CommitStorage & CommitReferencing &
    FileDiffing & FileContents & FileStaging & FileStatusDetection &
    Merging & RemoteManagement & RepoConfiguring & Stashing &
    SubmoduleManagement & Tagging & WritingManagement & Workspace
```

All protocols are defined in `Helm/Repository/RepositoryProtocols.swift`. The `@Faked` macro auto-generates test doubles for each protocol. "Empty" default implementations (`EmptyFileDiffing`, etc.) provide no-op conformances.

### State Management

- `GitRepositoryController` holds a serial `TaskQueue` for repo writes and an LRU `RepositoryCache` for file changes.
- Repository state changes are broadcast via Combine `AnyPublisher<Void, Never>` publishers (`headPublisher`, `indexPublisher`, etc.).
- File system watchers (`RepositoryWatcher`, `WorkspaceWatcher`, `ConfigWatcher`) detect changes and trigger cache invalidation + publisher emissions.

### Thread Safety

- UI code runs on the main thread (`@MainActor` on UI protocols).
- Repository writes use `performWriting()` + `isWriting` flag + `NSRecursiveLock`.
- The `@MutexProtected` property wrapper guards shared cache state.

### Selection Abstraction

`RepositorySelection` (in `Helm/Repository/RepositorySelection.swift`) represents what is currently selected — a commit, staging area, stash, etc. — and provides a unified file-list interface. All file view controllers work against this protocol rather than concrete types.

### Operations (Multi-step Workflows)

`Helm/Operations/` contains `OperationController` subclasses that encapsulate complex user workflows (stash, reset, merge, etc.): dialog → model validation → execution.

## Key Files

| File | Purpose |
|------|---------|
| `Helm/Repository/RepositoryProtocols.swift` | All repository capability protocols |
| `Helm/Repository/HelmRepository.swift` + extensions | libgit2 wrapper implementation |
| `Helm/Repository/RepositoryController.swift` | Business logic, watchers, task queue |
| `Helm/Document/HelmWindowController.swift` | Main window coordinator |
| `Helm/Repository/RepositorySelection.swift` | Selection abstraction |

## Coding Style

- Braces at end of line for control flow; on their own line for functions/classes/etc.
- `else` always starts a new line (for both `if` and `guard`).
- Blank lines separate groups of `let`/`var` declarations, `guard` statements, and other statements.
- SwiftLint enforces line length (~83 chars), function length (~60 lines), and cyclomatic complexity.

## Extending the Codebase

**New repository capability:** Add protocol to `RepositoryProtocols.swift` → implement in an `HelmRepository` extension → add to `FullRepository` typealias → annotate with `@Faked`.

**New operation/dialog:** Subclass `OperationController`, create a SwiftUI panel conforming to `SheetDialog`, bridge to AppKit with `NSHostingController`.

**Tests:** Add to `HelmTests/` target using XCTest. Inject fake repositories (see `Helm/Repository/Fakes.swift`, `FakeRepo.swift`) instead of real `HelmRepository`. Include a happy-path and at least one edge-case test.

## Further Reading

- `ARCHITECTURE.md` — detailed architecture guide
- `CONTRIBUTING.md` — build walkthrough and code style details
