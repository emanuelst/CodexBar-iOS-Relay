# macOS Plan Usage

Open the separate Plan Usage window from the chart button in Relay's existing status bar. Always on top shares the existing preference; no extra menu bar icon is created. Codex, Claude and Combined have separate Session/Weekly views, with Monthly or Sonnet offered only when the source history contains a supported lane. Combined defaults to overlaid on a shared actual-time graph actual timelines. Its optional normalized overlay compares elapsed window progress; it never adds or averages allowances.

## Data and ownership

This view reads CodexBar's existing version-1 JSON history under `~/Library/Application Support/com.steipete.codexbar/history/`. Each file contains `preferredAccountKey`, `accounts`, `unscoped` and series with `name`, `windowMinutes`, and `entries` (`capturedAt`, `usedPercent`, `resetsAt`). Dates are ISO-8601. The reader uses only the explicitly preferred **saved** account bucket and never merges owners, chooses another account by recency, adopts unscoped entries or reconstructs history from Relay's current snapshot. Missing or ambiguous stored ownership is unavailable. Changes to the preferred key replace the window's histories atomically on the next read; missing files/buckets clear them.

CodexBar's in-process account resolver additionally has live credential/settings authority that is not exported in history JSON. Relay deliberately follows the persisted selection, rather than recreating that resolver from credentials. An account switch before CodexBar persists a new selection is not independently observable by Relay; the footer says “selected saved account.” This is a limitation of the current upstream history interface. No historical account migration is performed by Relay.

The model ports current upstream `QuotaBurndownModel` and `QuotaBurndownChartMenuView` preparation and styling, with the latest recorded capture as the model's reference time. It filters out other reset boundaries (120-second equivalence), restarts the line on a usage drop, canonicalizes session/weekly duration tolerance, and folds legacy Codex 43,200-minute primary/secondary histories into Monthly within the selected owner. Synthetic placeholders are excluded by CodexBar's recorder before persistence; this adapter never creates samples from missing snapshots. Expired windows disappear, unsupported/missing windows show unavailable, and stale records retain their capture timestamp. The line ends at the last recorded sample. Colour overrides use CodexBar's `accentColor` setting; file reads happen off the main thread.

## Subscription dates

Existing `subscriptionRenewsAt` / `subscriptionExpiresAt` flow through Relay. New optional `subscriptionRenewsAtIsDateOnly` / `subscriptionExpiresAtIsDateOnly` flags preserve calendar-only billing values without displaying an invented hour. Raw `yyyy-MM-dd` subscription values are also supported. Older iOS/iCloud payloads still decode; graph history is not added to the synced payload.

## Validation

`Tests/PlanUsageChecks.swift` covers recorded endpoints, missing/future/expired windows, changed reset boundaries, usage drops, duplicate captures, normalized progress, account selection changes, unknown history schemas and date precision. `Tests/PlanUsageRenderProof.swift` creates isolated native NSWindows with synthetic data in light/dark appearance, without a Relay controller, provider calls, LAN server or iCloud writes. It renders individual, overlaid on a shared actual-time graph, normalized and weekly graphs. The `--recorded` option instead reads existing saved history without provider calls; the included screenshots use that recorded data. These are native-hosted renders, not screenshots of the installed Relay application. Installed applications are not replaced or restarted.

Final macOS Debug and iOS Simulator builds pass. Graph/account/date-precision checks and the existing cloud-credit/reset decoder checks pass. Native recorded-history renders were inspected in light and dark appearance. Saved screenshots: [Codex](plan-usage-screenshots/codex-light.png), [Claude](plan-usage-screenshots/claude-light.png), [Combined](plan-usage-screenshots/combined-light.png), [Normalized](plan-usage-screenshots/normalized-light.png), [Weekly dark](plan-usage-screenshots/weekly-dark.png). The earlier typed Claude saved-reset work was subsequently consolidated into the upstream detail-row adapter; see [saved-reset notes](claude-saved-resets.md). Billing/date precision and graph checks continue to pass.

Combined now uses one actual-time plot with separate Codex/Claude lines and dashed guides, a common 0–100 remaining-percentage scale, provider legend and each real reset time. Normalized comparison remains optional; no allowances are summed or averaged. Recorded native proofs were refreshed after this change.

### Claude dates from the local Dev build

Relay can read the selected verified Claude snapshot exported by CodexBar Dev. It prefers the complete fresh Dev Claude entry and labels it `codexbar-dev`; it never merges Dev dates onto a different signed-app account. An empty or unavailable Dev selection clears Dev metadata and falls back to the signed producer’s own complete snapshot. Stale or future captures are rejected. Existing iOS fields and payload decoding are unchanged. The DEBUG-only producer bridge is separate from the upstream billing changes.

Runtime handoff: the installed Relay/Dev bundles match the final build. Live Dev background cookie import currently requires a macOS Keychain approval; until a successful user-initiated Claude refresh, Relay falls back to signed CodexBar and does not show a renewal date. This is an authorization limitation, not a guessed date or a sync workaround.
