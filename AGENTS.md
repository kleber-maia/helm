# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

Helm (pronounced "exit") is a native macOS Git client written in Swift. It provides a visual interface for viewing and managing Git repositories, with a focus on stability, scalability with large repositories, and a well-organized codebase.

The app is a hybrid **AppKit/SwiftUI** application that uses **libgit2** (via a C bridging header) for Git operations. It has no dedicated unit-test targets yet, though the architecture is designed for testability with extensive protocol-oriented fake implementations.

## Technology Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 5.0 |
| Platform | macOS 26.0+ |
| UI Frameworks | AppKit (primary), SwiftUI (dialogs/panels) |
| Git Operations | libgit2 (C library, static link) |
| Reactive State | Combine |
| Terminal | SwiftTerm (Swift Package) |
| Test Fakes | FakedMacro (Swift Package) |
| Web Assets | CodeMirror 6 bundled with esbuild |

## Project Structure

```
Helm/
├── Actions/                    # Custom user actions
├── Document/                   # NSDocument, window controllers, title bar
│   ├── RepoDocument.swift
│   ├── HelmWindowController.swift
│   ├── RepositoryUIAccessor.swift
│   └── ...
├── FileView/                   # File list and preview components
│   ├── File List/              # Staging/workspace/commit file list controllers
│   └── Previews/               # Diff, blame, text, QuickLook viewers
├── HistoryView/                # Commit history table and graph
├── Operations/                 # Multi-step operation controllers (stash, reset, etc.)
├── Preferences/                # Settings panels (Accounts, General, Previews)
├── Repository/                 # Core Git repository abstraction
│   ├── HelmRepository.swift    # Main libgit2 wrapper
│   ├── RepositoryProtocols.swift # All capability protocols
│   ├── RepositoryController.swift # Business logic, caching, watchers
│   ├── RepositorySelection.swift # Selection abstraction
│   ├── Fakes.swift             # Fake implementations for testing
│   ├── FakeRepo.swift          # Pre-built fake repository
│   └── Git*.swift              # libgit2 primitive wrappers
├── Services/                   # Auth services, pull request cache
├── Sidebar/                    # Branch/remote/tag/stash/submodule sidebar
├── Terminal/                   # Embedded terminal (SwiftTerm)
├── Utils/                      # Extensions and helpers
│   ├── Extensions/             # Swift/Foundation/AppKit extensions
│   └── SwiftUI/                # Reusable SwiftUI components
├── Helm.icon/                  # App icon assets
├── html/                       # Bundled HTML/CSS/JS for diff/blame/text views
├── html-build/                 # Node.js/esbuild setup for CodeMirror bundle
├── images/                     # Image resources
├── Helm-Bridging-Header.h      # Objective-C / libgit2 imports for Swift
├── Helm-Info.plist             # App bundle configuration
├── Helm.entitlements           # Sandbox entitlements (currently empty)
├── Defaults.plist              # Default user preferences
└── MainMenu.xib                # Application menu

libgit2/                        # Git submodule: libgit2 source
libgit2-mac.a                   # Prebuilt static library
build_libgit2.sh               # Build script for libgit2

Xcode-config/
├── Shared.xcconfig             # Common build settings
└── DEVELOPMENT_TEAM.xcconfig   # Developer-specific code-signing (gitignored)
```

## Build System & Configuration

The project is an **Xcode project** (`Helm.xcodeproj`). It uses Xcode's modern `fileSystemSynchronizedGroups` feature (Xcode 16+) to automatically sync directory contents into the build.

### Targets

| Target | Type | Purpose |
|--------|------|---------|
| Helm | Application | Main app target |
| Periphery | Aggregate | Dead code detection (runs Periphery tool) |
| libgit2 | Aggregate | Builds `libgit2-mac.a` from the `libgit2/` submodule |

### Build Commands

```bash
# Initialize the libgit2 submodule
git submodule update --init --recursive

# Build libgit2 from source (if needed)
./build_libgit2.sh

# Build the app
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug build

# Run tests (no test targets currently exist, so this will build only)
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug test

# Lint (runs automatically during Xcode build if SwiftLint is installed)
swiftlint lint Helm/
```

### Setup Requirements

1. **libgit2**: Install via Homebrew (`brew install libgit2`) or build from source with `./build_libgit2.sh`.
2. **Code signing**: Either delete the "Code Signing Identity" build setting in the Application target, or create `Xcode-config/DEVELOPMENT_TEAM.xcconfig` containing `DEVELOPMENT_TEAM = <Your TeamID>`.
3. **Apple Silicon**: Set the build destination to "My Mac" (not Rosetta).
4. **Node.js**: Required only if modifying `Helm/html-build/` web assets.

### Web Asset Build

The diff/blame/text preview pane uses a CodeMirror 6 editor bundled into a single file:

```bash
cd Helm/html-build
npm install
npm run build   # Outputs ../html/codemirror-bundle.js
```

## Dependencies

Dependencies are managed via **Xcode's Swift Package Manager integration** (no `Package.swift` in the repo root):

| Package | Source | Purpose |
|---------|--------|---------|
| FakedMacro | `https://github.com/Uncommon/FakedMacro` (main branch) | Macro to generate fake test doubles |
| SwiftTerm | `https://github.com/migueldeicaza/SwiftTerm.git` (1.5.0+) | Embedded terminal emulator |

Native dependencies:

| Library | Source | Purpose |
|---------|--------|---------|
| libgit2 | Git submodule + prebuilt `libgit2-mac.a` | Git operations |
| OpenSSL | Homebrew (`openssl@3` or `openssl`) | SSH support in libgit2 |
| libssh2 | Homebrew | SSH support in libgit2 |

## Code Style & Conventions

### Swift

- **Braces**: End of line for control flow (`if`, `while`, etc.); on their own line for functions, classes, structs, etc.
- **Else**: Always starts a new line (both `if` and `guard`).
- **Blank lines**: Separate groups of `let`/`var` declarations, `guard` statements, and other statements.
- **Line length**: ~83 characters (enforced by SwiftLint).
- **Function length**: ~60 lines (enforced by SwiftLint).
- **Cyclomatic complexity**: Monitored by SwiftLint.

### SwiftLint Configuration

Rules are defined in `.swiftlint.yml`. Notable disabled rules include `opening_brace`, `force_cast`, `trailing_comma`, and `identifier_name`. Enabled opt-in rules include `yoda_condition`, `empty_count`, `let_var_whitespace`, and `implicit_return` (closures/getters only).

### C/Objective-C

Formatted with `.clang-format` (Google style, Stroustrup braces). Only the bridging header (`Helm-Bridging-Header.h`) and a small C utility file (`Helm/Utils/HelmQueueUtils.c`) are maintained in the project.

## Architecture Overview

The codebase follows a strict three-layer architecture:

```
UI Layer (AppKit/SwiftUI)
  RepoDocument, HelmWindowController, view controllers, SwiftUI dialogs
  RepositoryUIController  — UI coordination protocol (selection, window state)
        ↓
Controller Layer
  GitRepositoryController — task queue, caching, file watchers, Combine publishers
        ↓
Repository Layer (Helm/Repository/)
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

All protocols are defined in `Helm/Repository/RepositoryProtocols.swift`.

The `@Faked` macro (from the `FakedMacro` package) auto-generates test doubles and "Empty" default implementations (`EmptyFileDiffing`, `EmptyFileStaging`, etc.) for annotated protocols. These provide no-op conformances so fakes only need to implement the capabilities under test.

### State Management

- `GitRepositoryController` holds a serial `TaskQueue` for repository writes and an LRU `RepositoryCache` for file changes.
- Repository state changes are broadcast via Combine `AnyPublisher<Void, Never>` publishers (`headPublisher`, `indexPublisher`, `refsPublisher`, `stashPublisher`, `workspacePublisher`, etc.).
- File system watchers (`RepositoryWatcher`, `WorkspaceWatcher`, `ConfigWatcher`) detect changes and trigger cache invalidation + publisher emissions.

### Thread Safety

- UI code runs on the main thread (`@MainActor` on UI protocols and controllers).
- `HelmRepository` writes use `performWriting()` + `isWriting` flag + `NSRecursiveLock`.
- `GitRepositoryController` uses a serial `TaskQueue` for repository writes and an `NSRecursiveLock` for cache access.
- The `@MutexProtected` property wrapper guards shared cache state.

### Selection Abstraction

`RepositorySelection` (in `Helm/Repository/RepositorySelection.swift`) represents what is currently selected — a commit, staging area, stash, etc. — and provides a unified file-list interface. All file view controllers work against this protocol rather than concrete types.

### Operations (Multi-step Workflows)

`Helm/Operations/` contains `OperationController` subclasses that encapsulate complex user workflows (stash, reset, merge, clean, clone, fetch, pull, push, etc.). The typical pattern is: dialog → model validation → `OperationController` execution.

## Testing Strategy

**Current state:** The project has no dedicated test targets or XCTest files. However, the architecture is designed for testability:

- The `@Faked` macro generates fake implementations for most repository protocols.
- `Helm/Repository/Fakes.swift` and `FakeRepo.swift` provide manually maintained fake classes (`FakeRepo`, `FakeCommit`, `FakeLocalBranch`, `FakeRemoteBranch`, `FakeRemote`, etc.).
- "Empty" protocols (`EmptyCommitReferencing`, `EmptyFileStaging`, etc.) allow composing minimal fakes.

If adding tests, create a new **XCTest target** in the Xcode project and inject fake repositories instead of real `HelmRepository` instances. Include a happy-path test and at least one edge-case test where practical.

## Security Considerations

- **Entitlements**: `Helm/Helm.entitlements` is currently empty (no sandbox restrictions or capabilities declared).
- **Password storage**: `Helm/Utils/PasswordStorage.swift` and `MemoryPasswordStorage.swift` handle credentials in memory. There is also a `NoOpKeychain` fallback.
- **Basic auth**: `Helm/Services/BasicAuthService.swift` handles HTTP basic authentication for remotes.
- **libgit2 callbacks**: SSH and HTTPS remote operations use libgit2 credential callbacks.
- Do not commit secrets, API keys, or provisioning profiles.
- Do not modify code signing or team settings in the Xcode project without explicit instruction.

## Key Files

| File | Purpose |
|------|---------|
| `Helm/Repository/RepositoryProtocols.swift` | All repository capability protocols |
| `Helm/Repository/HelmRepository.swift` + extensions | libgit2 wrapper implementation |
| `Helm/Repository/RepositoryController.swift` | Business logic, watchers, task queue |
| `Helm/Document/HelmWindowController.swift` | Main window coordinator |
| `Helm/Document/RepositoryUIAccessor.swift` | Convenience accessors for `RepositoryUIController` |
| `Helm/Repository/RepositorySelection.swift` | Selection abstraction |
| `Helm/Document/RepoDocument.swift` | NSDocument subclass that opens Git repos |
| `Helm/AppDelegate.swift` | App entry point (`@NSApplicationMain`) |
| `Helm/Operations/OperationController.swift` | Base class for multi-step operations |
| `Helm/Helm-Bridging-Header.h` | Objective-C/Swift bridging for libgit2 |

## Extending the Codebase

**New repository capability:**
1. Add the protocol to `RepositoryProtocols.swift` and annotate with `@Faked`.
2. Implement it in an `HelmRepository` extension.
3. Add it to the `FullRepository` typealias.
4. Create an `Empty<Capability>` protocol with no-op defaults if needed for fakes.

**New operation/dialog:**
1. Subclass `OperationController`.
2. Create a SwiftUI panel conforming to `SheetDialog` (or `DataModelView`).
3. Bridge to AppKit with `NSHostingController`.

**New UI panel/dialog:**
1. Create a SwiftUI view conforming to `DataModelView`.
2. Define a model conforming to `Validating`.
3. Use `SheetDialog` for modal presentation.

**New web preview feature:**
1. Modify sources in `Helm/html-build/`.
2. Run `npm run build` in `Helm/html-build/` to regenerate `codemirror-bundle.js`.

## Further Reading

- `README.md` — Project introduction and feature overview
- `ARCHITECTURE.md` — Detailed architecture guide
- `CONTRIBUTING.md` — Build walkthrough and code style details
- `Usage Notes.md` — Notes on in-progress features
