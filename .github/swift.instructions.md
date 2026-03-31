---
applyTo: "*.swift"
---

# Swift Language Instructions

**For Code Reviews:** Verify Swift-specific rules below. See `.github/instructions.md` for general repository guidelines.

---


## Language Version & Modern Features
- Must: Use Swift 6.0+ features and syntax
- Must: Use `async/await` for all asynchronous operations instead of completion handlers
- Must: Use structured concurrency (`Task`, `TaskGroup`, `AsyncSequence`, `AsyncStream`)
- Must: Properly annotate types with `Sendable` conformance where appropriate
- Must: Use `@MainActor` for all UI-related code and view models
- Must: Prefer value types (structs, enums) over reference types (classes) unless inheritance or DI registration is required
- Should: Use Swift 6's typed throws when defining error-throwing functions
- Should: Use `actor` types for thread-safe state management with mutable shared state
- Should: Use `nonisolated` keyword appropriately for actor methods that don't need isolation

## Code Style & Syntax
- Must: Follow Swift API Design Guidelines
- Must: Use meaningful, descriptive names that clearly communicate intent
- Must: Use `let` over `var` whenever possible (immutability first)
- Must: Use trailing closure syntax when the last parameter is a closure
- Must: Use implicit returns for single-expression closures and computed properties
- Must: Use type inference where it improves readability, explicit types where it improves clarity
- Must: Avoid force unwrapping (`!`) - use optional binding (`if let`, `guard let`), nil coalescing (`??`), or optional chaining
- Must: Use `guard` statements for early returns and preconditions
- Must: Use `switch` statements exhaustively - avoid default cases when all cases can be enumerated
- Should: Use Swift's result builders (e.g., `@resultBuilder`) when building DSLs
- Should: Prefer pattern matching over complex conditionals

## SwiftUI Best Practices
- Must: Follow the project's MVVM+SwiftUI architecture (see `Docs/MVVM+SwiftUI/MVVMSwiftUI.md`)
- Must: Use `@State` for view-local mutable state
- Must: Use `@Binding` for two-way data flow between parent and child views or closures for propagating actions to high level views.
- Must: Mark all view models and UI-related classes with `@MainActor`
- Must: Keep views small and focused - extract subviews when complexity grows (>50 lines)
- Must: Use view modifiers from the DesignSystem module to maintain consistency
- Should: Prefer composition over complex view hierarchies
- Should: Use `@Bindable` for creating bindings to observable properties
- Should: Use SwiftUI's native property wrappers over manual state management

## Concurrency & Threading

> **Deferred to Agent Skill:** For all concurrency guidance — async/await, actors, tasks, Sendable, `@MainActor`, threading, migration, and error triage — see `.github/skills/swift-concurrency/SKILL.md`.

### Available Skills

| Skill | Location | Use When |
|-------|----------|----------|
| **Swift Concurrency** | `.github/skills/swift-concurrency/SKILL.md` | Working with async/await, actors, tasks, Sendable, Swift 6 migration, concurrency linting warnings, or data race issues. |

## Dependency Management & Module Architecture
- Must: Follow the module structure defined in project guidelines
- Must: Use factory registration only in `Module.swift` files (no instance registration)
- Must: Depend only on `*API` modules from other features, never on implementation modules
- Must: Define protocols in API modules, implementations in feature modules
- Must: Conform to `ModuleDefinition` protocol from `JourneyModule` for feature modules
- Should: Prefer injecting dependencies through initializers (constructor injection)
- Should: Keep module dependencies minimal and acyclic
- Should: Use protocol-oriented design for testability and flexibility
- Should: Only use service locator pattern trhough DependencyRepository protocol
- Should: Prefer explicit dependency injection when possible

## Error Handling
- Must: Use Swift's native error handling (`throws`, `try`, `catch`, `do`)
- Must: Define custom error types conforming to `Error` protocol
- Must: Use typed throws (Swift 6+) to specify exact error types: `func fetch() throws(NetworkError)`
- Must: Provide descriptive error messages with sufficient context
- Should: Use `Result<Success, Failure>` for APIs that return success or failure without throwing
- Should: Group related errors into enum cases with associated values
- Should: Handle errors at appropriate architectural boundaries
- Should: Use `rethrows` for functions that only throw if their closure parameter throws
- Should: Log errors appropriately but don't swallow them silently
- Should: Never use `fatalError` in production code - handle errors gracefully
- Should: Never use print statements for error logging - use a proper logging framework (OSLog, TracingService)

## Memory Management
- Must: Avoid retain cycles - use `[weak self]` or `[unowned self]` in closures appropriately
- Must: Use `weak` for delegate patterns
- Must: Profile memory usage for collections with large datasets
- Should: Use lazy initialization (`lazy var`) for expensive computed properties
- Should: Prefer structs over classes for better performance and value semantics
- Should: Be mindful of capture lists in async contexts

## Testing
- Must: Follow the Testing Strategy (see `Docs/TestingStrategy/TestingStrategy.md`)
- Must: Write unit tests for all business logic and view models
- Must: Use descriptive test names:
  - XCTest: `test_givenCondition_whenAction_thenExpectedResult()`
  - Swift Testing: `givenCondition_whenAction_thenExpectedResult()`, with using `@Test` annotation
- Must: Test both success and failure paths
- Must: Use Swift Testing framework over XCTest when possible
- Must: Test async code using `await` in test methods
- Must: Use test doubles (mocks, stubs, fakes) for external dependencies. When a double used in multiple test modules, prefer creating it in shared test utilities module
- Must: Create test utilities module under `Modules/<Team>/<Feature>/Tests` for shared test helpers with `<Feature>APITestUtilities` name
- Must: Keep tests time-independent — do not use `Task.sleep`, `ContinuousClock`, `Duration.seconds`, or polling loops to wait for conditions. Use `withCheckedContinuation`/`withCheckedThrowingContinuation` or structured concurrency primitives to suspend until the expected event occurs
- Should: Aim for high test coverage (>80%) on critical business logic
- Should: Keep tests fast, isolated, and deterministic

## Documentation
- Must: Add documentation comments (`///`) for all public APIs
- Must: Use DocC-style documentation with proper markup
- Must: Document parameters using `- Parameter name: description`
- Must: Document return values using `- Returns: description`
- Must: Document thrown errors using `- Throws: description`
- Should: Include usage examples in documentation for complex APIs
- Should: Document non-obvious implementation details with inline comments (`//`)
- Should: Keep documentation up-to-date with code changes

## Networking
- Must: Use the `Networking` module from Common package for all network calls
- Must: Handle network errors gracefully
- Must: Use `async/await` with URLSession's modern APIs
- Must: Create separate models for API requests and domain models
- Should: Use `Codable` for JSON serialization/deserialization
- Should: Use `URLSession` with custom configurations for different needs

## Design System Integration (applicable NativeSportsBook only)
- Must: Use tokens and components from the `DesignSystem` module
- Must: Apply design tokens through provided SwiftUI modifiers
- Must: Use views from `DesignSystemViews` module for common UI patterns
- Should: Contribute reusable components back to the design system
- Should: Follow the design system's spacing, color, and typography guidelines

## Security & Privacy
- Must: Never commit sensitive data (API keys, secrets, credentials)
- Must: Use Keychain for storing sensitive information
- Must: Validate and sanitize user input

## Code Quality
- Must: Fix all compiler warnings - treat warnings as errors
- Must: Run SwiftLint and fix all violations
- Should: Perform code reviews before merging
- Should: Refactor complex code to improve readability

## Deprecated Patterns to Avoid
- Must not: Use completion handlers (use `async/await` instead)
- Must not: Use `DispatchQueue` for new async code (use structured concurrency)
- Must not: Use `ObservableObject` + `@Published` (use `@Observable` macro). Applicable only for NativeSportsBook.
- Must not: Use force unwrapping unless in test code or after explicit precondition checks
- Must not: Use stringly-typed APIs (use type-safe alternatives)
- Must not: Use `AnyObject` or `Any` unless absolutely necessary (prefer specific types)
