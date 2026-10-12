# Phase Analytics SDK for Swift

Privacy-first mobile analytics for iOS and macOS applications.

[![Swift](https://img.shields.io/badge/Swift-6.0+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015.0+%20|%20macOS%2012.0+-lightgrey)](https://github.com/Phase-Analytics/Phase)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%203.0-blue.svg)](./LICENSE)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager)

## Features

- **Privacy by Default** - No PII collected without explicit consent
- **Offline Support** - Events queued locally and synced when online
- **SwiftUI Native** - Built for modern Swift with async/await
- **Type Safe** - Full Swift 6 concurrency support
- **Lightweight** - Minimal impact on app size
- **Self-Hostable** - Run on your own infrastructure

## Requirements

- iOS 15.0+ or macOS 12.0+
- Swift 6.0+
- Xcode 16.0+ (the package uses `swift-tools-version: 6.0`)

## Installation

### Swift Package Manager

Add Phase Analytics to your project using Swift Package Manager:

#### In Xcode:

1. Go to **File → Add Package Dependencies**
2. Enter the repository URL: `https://github.com/Phase-Analytics/Phase-Swift`
3. Select the latest version
4. Add to your target

#### In Package.swift:

```swift
dependencies: [
    .package(url: "https://github.com/Phase-Analytics/Phase-Swift", from: "0.2.0")
]
```

Then add it to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "PhaseAnalytics", package: "Phase-Swift")
    ]
)
```

## Quick Start

### SwiftUI

Wrap your app with the `Phase` view to initialize the SDK:

```swift
import SwiftUI
import PhaseAnalytics

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            Phase(apiKey: "phase_xxx") {
                ContentView()
            }
        }
    }
}
```

Then identify the user and track events:

```swift
import SwiftUI
import PhaseAnalytics

struct ContentView: View {
    var body: some View {
        Text("Hello, World!")
            .onAppear {
                Task {
                    // Initialize analytics - no PII collected by default
                    await PhaseSDK.shared.identify()

                    // Track custom events
                    track("app_opened")
                }
            }
    }
}
```

### UIKit

Initialize the SDK in your AppDelegate:

```swift
import UIKit
import PhaseAnalytics

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Task {
            try await PhaseSDK.shared.initialize(apiKey: "phase_xxx")
            await PhaseSDK.shared.identify()
        }
        return true
    }
}
```

## Configuration

The `Phase` view and `initialize()` method accept the following parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `apiKey` | `String` | **Required** | Your Phase API key (starts with `phase_`) |
| `baseURL` | `String` | `"https://api.phase.sh"` | Custom API endpoint for self-hosted deployments |
| `logLevel` | `LogLevel` | `.none` | Console logging level (`.info`, `.warn`, `.error`, `.none`) |
| `debugData` | `Bool` | `false` | Mark identify/events as debug data |
| `deviceInfo` | `Bool` | `true` | Collect device metadata (model, OS version, platform, app version as `app_version`) |
| `userLocale` | `Bool` | `true` | Collect the user locale (as a BCP 47 tag such as `en-US`) and resolve country from IP |

### Example with Configuration

```swift
Phase(
    apiKey: "phase_xxx",
    logLevel: .info,
    debugData: false,
    deviceInfo: true,
    userLocale: true
) {
    ContentView()
}
```

## API Reference

### `identify(_:)`

Register the device and start a session. Events tracked earlier (even before `initialize()`) are kept, up to 200 events for up to an hour, with their original timestamps, and sent once `identify()` runs. Calling `identify()` before `initialize()` finishes is fine too: it runs right after initialization.

Custom properties must be flat (`String`, `Int`, `Double`, `Bool`, `nil`), keys up to 128 characters. Invalid properties are logged and left out; the device is still identified.

```swift
// Basic usage - no PII collected
await PhaseSDK.shared.identify()

// With custom properties
await PhaseSDK.shared.identify([
    "user_id": "123",
    "plan": "premium",
    "beta_tester": true
])
```

### `track(_:params:)`

Track custom events with optional parameters.

```swift
// Global function - event without parameters
track("app_opened")

// Global function - event with parameters
track("purchase_completed", [
    "amount": 99.99,
    "currency": "USD",
    "product_id": "premium_plan"
])

// Instance method
PhaseSDK.shared.track("button_clicked", params: ["button_id": "submit"])
```

Params allow up to 32 keys (keys up to 32 characters), string values up to 256 characters and 8 KB in total. `NaN` and infinite numbers are rejected. Each event gets a unique ID when it is tracked, so retries never create duplicates.

### `trackScreen(_:params:)`

Manually track screen views.

```swift
// Global function
trackScreen("/profile", ["user_id": "123"])

// Instance method
PhaseSDK.shared.trackScreen("/settings", params: nil)
```

Screen names follow the event naming rules below. Send IDs as they are (`/users/42`); the server groups numeric segments into `/users/:id`.

### `flush()`

Send queued data now, e.g. before a test assertion or a known shutdown. Returns when the attempt finishes. While offline or while the server asks the SDK to back off, data stays queued and is retried automatically.

```swift
await PhaseSDK.shared.flush()
```

### `reset()`

Forget the current device, e.g. on logout. Ends the session, tries to deliver queued data, discards what could not be sent and generates a new device ID. Call `identify()` again to start tracking the new device.

```swift
await PhaseSDK.shared.reset()
await PhaseSDK.shared.identify()
```

### `.phaseScreen(_:params:)` Modifier

Automatically track screen views in SwiftUI:

```swift
struct ProfileView: View {
    let userID: String

    var body: some View {
        VStack {
            Text("Profile")
        }
        .phaseScreen("ProfileView", params: ["user_id": userID])
    }
}
```

Screen names are normalized automatically (e.g., `"ProfileView"` → `"/profile-view"`; query strings are removed and unsupported characters become `-`). A screen view is tracked each time the view appears, including when navigating back to it.

## Documentation

For complete documentation, including:
- Advanced configuration
- Event tracking best practices
- Screen tracking strategies
- Type references
- Privacy guidelines

Visit our documentation:

**[Swift Guide](https://phase.sh/docs/get-started/swift)** - Complete setup guide for iOS and macOS

## Privacy

Phase Analytics is designed with privacy as a core principle:

- No personal data is collected by default
- Device IDs are generated locally and stored persistently using `UserDefaults`
- Only technical metadata is collected (OS version, platform, locale, app version)
- Geolocation is resolved server-side from IP address
- All data collection is optional via configuration

**Important:** If you collect PII (personally identifiable information), ensure you have proper user consent.

## How It Works

### Delivery

- Everything goes through a persistent queue (stored in `UserDefaults`, up to 1000 items) and is sent in batches of up to 50 items: when 20 items are waiting, every 10 seconds while the queue is not empty, when the app moves to the background (inside a background task) and when connectivity returns.
- Items leave the queue only after the server answers. Items the server rejects permanently are dropped; items that failed for a transient reason are retried up to 5 times.
- Failed requests back off exponentially with jitter (up to 5 minutes) and honor `Retry-After` on `429`/`503`. Requests time out after 15 seconds.
- Session heartbeats are coalesced to one pending heartbeat per session.
- Thread-safe with Swift 6 concurrency.

### Type Safety

All parameters must be primitives: `String`, `Int`, `Double`, `Bool`, or `nil`. Invalid events are logged and dropped at the call site.

## Event Naming Rules

- ASCII letters and digits, underscores (`_`), hyphens (`-`), periods (`.`), forward slashes (`/`), and spaces
- 1-256 characters
- Examples: `purchase`, `user.signup`, `payment/success`, `Button Clicked`

## Dependencies

Phase Analytics uses the following dependencies:

- [ULID.swift](https://github.com/yaslab/ULID.swift) - Universally Unique Lexicographically Sortable Identifiers
- [GzipSwift](https://github.com/1024jp/GzipSwift) - Data compression

## License

This project is licensed under the AGPL-3.0 License - see the LICENSE file for details.

## Repository

- **Homepage**: [phase.sh](https://phase.sh)
- **GitHub**: [Phase-Analytics/Phase](https://github.com/Phase-Analytics/Phase)
- **Issues**: [Report a bug](https://github.com/Phase-Analytics/Phase/issues)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
