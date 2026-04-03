# UI Test Authoring Patterns

## 6.1 Test class setup

Always set `continueAfterFailure = false` in `setUpWithError`. Without it, a test
continues executing after `XCTAssert` failures, causing misleading secondary errors:
```swift
@MainActor
override func setUpWithError() throws {
    continueAfterFailure = false
    app = LaunchHelper.launchApp(with: [])
    helper = UITestHelper(application: app)
}
```
`@MainActor` is required on `setUpWithError` and on every `@Test` / `func test_…`
method in modern Swift. Omitting it triggers Main Actor isolation warnings.

---

## 6.2 Login state detection

**DO NOT** use `.exists` or `.isHittable` on a button that is always present in the
view hierarchy (e.g., a header button that exists in both logged-in and logged-out
states) to infer auth state. **Both `.exists` AND `.isHittable` return `true`
regardless of auth state** — this was verified empirically at t=22s in a logged-out
session where both properties returned `true`.

**Correct approach — tap-and-observe:**
```swift
// Tap the button that triggers different flows depending on auth state
let headerButton = app.buttons["<auth-entry-button-id>"].firstMatch
_ = headerButton.waitForExistence(timeout: 5)
headerButton.tap()

// Observe what appeared — the login form field is the discriminator
let emailField = app.textFields["<login-email-field-id>"].firstMatch
if emailField.waitForExistence(timeout: 5) {
    // Logged OUT — login screen appeared
    // ... fill form and submit
} else {
    // Logged IN — a different screen appeared (e.g., deposit/balance sheet)
    // ... dismiss it
}
```

Note the asymmetry: a session-dependent element (e.g., user icon that only appears
after authentication) IS reliable as a **post-login confirmation**. It's only
unreliable as a **pre-login discriminator** if it also exists in a hidden/dormant
state before login. Always verify which case you're in by checking the hierarchy
with `XcodeGrep` before choosing your discriminator element.

**Post-login state confirmation:**
```swift
// Wait for a session-ONLY element — one added to the hierarchy only after auth
let sessionElement = app.buttons["<session-only-element-id>"].firstMatch
XCTAssert(
    sessionElement.waitForExistence(timeout: 30),
    "Session element should appear within 30s of login (accounts for network latency)"
)
```

---

## 6.3 Polling for a deferred element

When an element may take a variable amount of time to appear (e.g., a popup
triggered by a background timer), use a deadline loop rather than a single
`waitForExistence(timeout:)`:

**Deadline formula:** `deadline = expected_trigger_time + retrigger_interval + jitter_buffer`  
For a feature with `investigationInterval=10s` and `retriggerInterval=30s`, a 70s
deadline covers first trigger (≥10s) + one full retrigger (30s) + jitter buffer.

```swift
let popup = app.otherElements["<feature-popup-id>"].firstMatch
// ↑ Use app.otherElements for custom view controllers / container views.
//   Custom VCs do not map to a specific XCUIElementType and appear under otherElements.

var found = false
let deadline = Date().addingTimeInterval(70)  // adjust per timing formula above

while !found && Date() < deadline {
    if popup.exists { found = true; break }
    // Also accept alternative presentation forms (e.g., UIAlertController)
    if app.alerts.firstMatch.exists { found = true; break }
    // Dismiss any blocking modals that are NOT the element under test
    let blocker = app.buttons["<dismiss-button-id>"].firstMatch
    if blocker.exists { blocker.tap() }
    // waitForExistence here doubles as a sleep between poll cycles
    _ = popup.waitForExistence(timeout: 2)
}
XCTAssert(found, "Popup should appear within the deadline")
```

Always use `.firstMatch` rather than subscript `[0]`. Subscript throws if the
collection is empty; `.firstMatch` returns a non-existent-element proxy safely.

---

## 6.4 Multiple presentation forms of the same feature

When a feature can be presented differently depending on context (e.g., a custom
view in one case, a native `UIAlertController` in another), accept both in the
same test rather than assuming one form:
```swift
// Custom view with accessibilityIdentifier
if app.otherElements["<feature-popup-id>"].exists { found = true }
// Native UIAlertController
if app.alerts.firstMatch.exists { found = true }
```

**Never dismiss an alert without first checking if it IS the element under test.**  
Dismissing the very UI you are asserting causes a false failure with no obvious
root cause.

---

## 6.5 Startup dialog handling

Apps with permission prompts, privacy notices, and tutorials must dismiss them
before any test logic runs. Use `UITestHelper.waitForHomeScreenToAppear(handleStartupDialogs:)`.

---

## 6.6 Post-action modals and conditional wait times

After key actions (e.g., login), the app may present a modal (welcome screen,
onboarding, terms update, etc.). Dismiss it before asserting any downstream
feature appears, otherwise the polling loop will time out.

Adjust the wait timeout based on what action was taken in the current test run:
```swift
// If we just logged in, the modal needs up to 10s to appear.
// If we were already logged in when the test started, the modal won't appear
// so 2s is sufficient to confirm it's absent.
let modal = app.buttons["<modal-dismiss-button-id>"].firstMatch
if modal.waitForExistence(timeout: alreadyLoggedIn ? 2 : 10) {
    modal.tap()
}
```
This pattern avoids adding fixed 10s delays to every test run.

---

## 6.7 Dismissing screens without a close button

When a screen is presented as a bottom-sheet or push navigation and has no
close button, use `swipeDown()` as a fallback:
```swift
let closeButton = app.buttons["<close-button-id>"].firstMatch
if closeButton.waitForExistence(timeout: 2) {
    closeButton.tap()
} else {
    app.swipeDown()   // fallback: bottom-sheet swipe-to-dismiss
}
```

---

## 6.8 Interacting with fields that have no accessibility ID

Password fields commonly lack accessibility IDs because they use the system
`UITextField` with `isSecureTextEntry = true` and no label. Access them by type:
```swift
let passwordField = app.secureTextFields.firstMatch
XCTAssert(passwordField.waitForExistence(timeout: 5), "Password field should appear")
passwordField.tap()
passwordField.typeText(password)
```
For email/username fields, prefer `app.textFields["<id>"]` when an ID exists,
but fall back to `app.textFields.firstMatch` when it doesn't.

---

## 6.9 Accessibility identifiers — naming contract
- Add `container.accessibilityIdentifier = "snake_case_component_name"` to custom
  view controllers/views that UI tests need to target.
- Use a consistent prefix convention per component layer, e.g.:
  - `<feature>_popup` for feature-level popups
  - `header_<action>_button` for header CTA buttons
  - `general_button_<action>` for shared generic buttons
  - `<screen>_button_<action>` for screen-specific CTAs
- Adding an ID is a one-line change in `setConstraints()` or `viewDidLoad()` — do
  it in the same PR that introduces the UI test.

---

## 9. Hardcoded Test Intervals — ⚠️ TEMP Pattern

When short intervals are needed for a UI test:
```swift
// <ControllerFile>.swift — TEMP for UI test
retriggerInterval = 30   // normally: configuration.retriggerInterval

// <FactoryFile>.swift — TEMP
investigationInterval: 10.0   // normally driven by configuration
```

**These must be removed after the UI test phase.** Mark with `// ⚠️ TEMP` and
create a follow-up task. Never merge hardcoded test intervals to a release branch.
