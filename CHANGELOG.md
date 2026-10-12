# Changelog

## Unreleased

### Added

- `PhaseSDK.shared.flush()` sends queued data immediately.
- `PhaseSDK.shared.reset()` forgets the current device (e.g. on logout) and generates a new device ID.
- Every event carries a client-generated `eventId` (ULID), created at `track()` time and kept across retries, so retried events are not duplicated.

### Changed

- All data is now delivered in batches through the persistent queue (at 20 items, every 10 seconds while items are waiting, on backgrounding inside a background task, and when connectivity returns) instead of one request per event.
- Items are removed from the queue only after the server answers; per-item results of `207` responses are applied (permanent failures dropped, transient failures retried up to 5 times).
- Backoff is exponential with jitter, honors `Retry-After`, and non-retryable `4xx` responses are no longer retried. Requests time out after 15 seconds.
- Events tracked before `initialize()`/`identify()` are buffered (up to 200, for up to an hour) with their original timestamps and IDs instead of being replayed later with new timestamps. `identify()` called before initialization finishes runs afterwards instead of waiting indefinitely.
- `.phaseScreen()` tracks every appearance of a view, including navigating back to it.
- Locale is sent as a BCP 47 tag (`en-US`) that fits the server limit.
- Session inactivity and maximum age use a monotonic clock, so changing the device time no longer splits or extends sessions.
- The queue is written to storage at most once per second (and immediately on backgrounding) instead of on every event; only one pending heartbeat is kept per session.

### Fixed

- Screen names with numeric segments (`/users/123`) were rewritten to `/users/:id`, which the server rejects; they are now sent as-is and normalized by the server.
- Event names and IDs containing non-ASCII letters passed client validation but were rejected by the server; validation now matches the server.
- A single invalid item (an over-long locale, nested or non-finite device properties) caused the whole batch, and every other item in it, to be rejected and dropped.
- Batches could mix data from two devices after an API key change or reset, which the server rejects as a whole.
- Connectivity reported before the SDK subscribed was lost, which could leave the SDK offline until the network changed.
- Pause/resume handlers running out of order could leave the session in the wrong state.
- `NaN` or infinite event params could crash the app while validating.
