# Claude saved limit resets in Relay

## Verified source

Read-only live checks on 2026-10-05 compared production CodexBar 0.72.0, CodexBar Dev 0.72.1 (commit 6a26b2e), and the local CodexBar CloudKit cache. Both CLI versions emitted `usage.details` with a titleless section and one row containing `label: "Limit Reset Credits"`, `value: "1 available"`, and `secondaryValue: "Expires Oct 22 at 6:00 PM"`. The cache supplied the same count with `Expires Oct 22 at 18:00`. Neither serialized `claudeResetCredits`.

Current upstream's `ClaudeRateLimitResetCredits.swift` deliberately keeps the typed inventory live-only and emits this generic detail row. It exposes an aggregate count and presentation text for the next expiry, without grant/redemption handles, individual expirations, reset types, or scope. No reset was redeemed during validation.

## Display and freshness

Relay consumes the exact labelled detail row for Claude only. It shows the positive supplied count and unmodified optional secondary text in a muted row, with the upstream-defined `https://claude.ai/settings/usage` link. It does not show a fabricated zero/unavailable state, reset type, scope or “No expiry” label. Missing or ambiguous rows are omitted. Quota timers, subscription dates, cloud credits and saved resets remain separate.

A new snapshot with no row clears the display; no saved-reset inventory is carried forward from older snapshots or typed legacy fields. The underlying `usage.updatedAt` must be present, valid and not in the future. A newer sync/fetched wrapper cannot revive an older usage capture. After two minutes the existing 30-second UI timeline marks the count as “N last reported” without removing its row, including during failed polls or offline use. Provider rows use account-aware stable identities so capture updates do not recreate them.

The source gives localized expiry text, not an exact timestamp, year, timezone or a complete per-reset expiry schedule. Relay therefore cannot reliably compute a local expiry instant or decrement an aggregate count at expiry. It relies on upstream's live expiry/redemption filtering on the next refresh and identifies stale captures as last reported. Redemption cannot be detected before the producer refreshes. These are source limitations, not inferred dates or availability states.

## Compatibility and validation

The erroneous typed Relay field/mapping has been removed. Unknown legacy `claudeResetCredits` keys remain harmless during decoding, and the existing generic details/payload shape is unchanged for older iOS consumers. Updated iOS views use the same freshness rule; no graph history is synced.

`Tests/ClaudeSavedResetsChecks.swift` verifies actual CLI shapes, numeric cache timestamps, missing/redemption rows, stale and future captures, no timestamp, malformed/duplicate counts, missing expiry text, ignored typed legacy fields and payload round trips. Existing cloud-credit and Plan Usage/date-precision regressions pass. macOS Debug and iOS Simulator builds pass.

[Light](saved-reset-screenshots/claude-saved-resets-light.png) and [dark](saved-reset-screenshots/claude-saved-resets-dark.png) native-hosted renders use the inspected CLI response at its own capture time with personal identity hidden; they are isolated view renders, not screenshots of the installed application's live state.

The obsolete `CodexBar-claude-saved-resets` checkout is not modified or used to build this feature. The prior billing and Plan Usage changes are preserved. The personal Relay integration is separate from the upstream billing patch.

## Consistent Relay presentation

Claude and Codex share a muted `Reset credits` heading and a right-aligned `N available` count. Claude continues to match the upstream `Limit Reset Credits` source row and preserve its supplied expiry text and Usage link. Codex retains its individually supplied titles and expirations. No new reset types or dates are inferred. The native render proof uses recorded provider data frozen at each capture time; macOS and iOS builds pass.
