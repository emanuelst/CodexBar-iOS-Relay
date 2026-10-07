# macOS Plan Usage

Open the separate Plan Usage window from the chart button in Relay's existing status bar. Always on top shares the existing preference; no extra menu bar icon is created. Codex, Claude and Combined have separate Session/Weekly views, with Monthly or Sonnet offered only when the source history contains a supported lane. Combined defaults to overlaid on a shared actual-time graph actual timelines. Its optional normalized overlay compares elapsed window progress; it never adds or averages allowances.

## Data and ownership


CodexBar's in-process account resolver additionally has live credential/settings authority that is not exported in history JSON. Relay deliberately follows the persisted selection, rather than recreating that resolver from credentials. An account switch before CodexBar persists a new selection is not independently observable by Relay; the footer says “selected saved account.” This is a limitation of the current upstream history interface. No historical account migration is performed by Relay.

The model ports current upstream `QuotaBurndownModel` and `QuotaBurndownChartMenuView` preparation and styling, with the latest recorded capture as the model's reference time. It filters out other reset boundaries (120-second equivalence), restarts the line on a usage drop, canonicalizes session/weekly duration tolerance, and folds legacy Codex 43,200-minute primary/secondary histories into Monthly within the selected owner. Synthetic placeholders are excluded by CodexBar's recorder before persistence; this adapter never creates samples from missing snapshots. Expired windows disappear, unsupported/missing windows show unavailable, and stale records retain their capture timestamp. The line ends at the last recorded sample. Colour overrides use CodexBar's `accentColor` setting; file reads happen off the main thread.

## Subscription dates

Existing `subscriptionRenewsAt` / `subscriptionExpiresAt` flow through Relay. New optional `subscriptionRenewsAtIsDateOnly` / `subscriptionExpiresAtIsDateOnly` flags preserve calendar-only billing values without displaying an invented hour. Raw `yyyy-MM-dd` subscription values are also supported. Older iOS/iCloud payloads still decode; graph history is not added to the synced payload.

## Validation

`Tests/PlanUsageChecks.swift` covers recorded endpoints, missing/future/expired windows, changed reset boundaries, usage drops, duplicate captures, normalized progress, account selection changes, unknown history schemas and date precision. `Tests/PlanUsageRenderProof.swift` creates isolated native NSWindows with synthetic data in light/dark appearance, without a Relay controller, provider calls, LAN server or iCloud writes. It renders individual, overlaid on a shared actual-time graph, normalized and weekly graphs. The `--recorded` option instead reads existing saved history without provider calls; the included screenshots use that recorded data. These are native-hosted renders, not screenshots of the installed Relay application. Installed applications are not replaced or restarted.

Final macOS Debug and iOS Simulator builds pass. Graph/account/date-precision checks and the existing cloud-credit/reset decoder checks pass. Native recorded-history renders were inspected in light and dark appearance. Saved screenshots: [Codex](plan-usage-screenshots/codex-light.png), [Claude](plan-usage-screenshots/claude-light.png), [Combined](plan-usage-screenshots/combined-light.png), [Normalized](plan-usage-screenshots/normalized-light.png), [Weekly dark](plan-usage-screenshots/weekly-dark.png). The earlier typed Claude saved-reset work was subsequently consolidated into the upstream detail-row adapter; see [saved-reset notes](claude-saved-resets.md). Billing/date precision and graph checks continue to pass.

Combined uses one plot with separate Codex/Claude lines and a common 0–100 remaining-percentage scale. `Both` overlays session and weekly limits on one timeline. The hours around the active sessions take most of the width; earlier and later days are compressed. `//` marks each change of scale and no time is omitted. Lines have display-only interpolated vertices at those joins so recorded values and forecast timestamps remain correct. Hour ticks use the displayed timezone; compressed sections use calendar dates. Exact start, reset and forecast times stay in the rows below the chart; hover cards are not used. Normalized comparison continues to use elapsed progress without calendar ticks or scale changes.

Each quota has one forecast entry containing its line/endpoint key and complete projected exhaustion timestamp. It identifies continuation beyond reset as hypothetical. There is no repeated run-out-time row in the provider details. Forecast calculations still use the shared pace implementation; widening the hours changes their visual slope across scale joins, not their calculation. No allowances are summed or averaged.

### Claude dates from the local Dev build

Relay can read the selected verified Claude snapshot exported by CodexBar Dev. It prefers the complete fresh Dev Claude entry and labels it `codexbar-dev`; it never merges Dev dates onto a different signed-app account. An empty or unavailable Dev selection clears Dev metadata and falls back to the signed producer’s own complete snapshot. Stale or future captures are rejected. Existing iOS fields and payload decoding are unchanged. The DEBUG-only producer bridge is separate from the upstream billing changes.

Runtime handoff: the installed Relay/Dev bundles match the final build. Live Dev background cookie import currently requires a macOS Keychain approval; until a successful user-initiated Claude refresh, Relay falls back to signed CodexBar and does not show a renewal date. This is an authorization limitation, not a guessed date or a sync workaround.

### In-chart labels

Event labels no longer sit at fake data values. Actual-time charts reserve point-sized annotation lanes via `chartYScale(range: .plotDimension(...))`: lanes above 100% hold `Now` and reset labels (session resets include the countdown, weekly resets keep the weekday), lanes below 0% hold run-out labels. `PlanUsageAnnotationLayout` (in `PlanUsageHistory.swift`) places them deterministically in priority order (`Now`, resets, run-outs, provider tags; session before weekly; Codex before Claude). It stacks labels into free lanes before shortening them, keeps each label touching its rule, clamps labels inside the plot, and drops the lowest-priority label only when nothing fits. Every value stays in the detail rows below. Provider tags float beside their latest capture, avoiding markers and the lanes. Compressed `Both` axis labels are thinned to a minimum spacing. Hover tooltips stay disabled; the overlay does not hit-test.

`Tests/PlanUsageAnnotationLayoutChecks.swift` covers stacking, shortening, determinism, weekday retention, edge clamping, priority drops, floating-tag avoidance and axis thinning. The render proof adds `collision-*` fixtures reproducing the crowded live case (Now, a reset 2 minutes away, run-outs 1 minute apart) at 680 and 580 pt.

```
swiftc -parse-as-library -o /tmp/layout-checks Tests/PlanUsageAnnotationLayoutChecks.swift Mac/PlanUsageHistory.swift && /tmp/layout-checks
```

### Session context after a reset

While a session window is in its first half, Session views (single-provider and Combined, actual time) also draw the previous finished window as a faint line labelled "previous window". It is rebuilt read-only from the same recorded history via `PlanUsageGraph.previous(series:before:)`, which uses the same reset-boundary and usage-drop rules. Forecasts never use it. Time after Now is shaded as forecast. Now is a solid neutral rule. Window starts are square markers only, with no vertical rule. A window with no usage yet shows "no usage yet" instead of a flat projection on the 100% gridline; otherwise a window with a single capture is tagged "new window". Forecast rows say "Lasts to reset" when the projected run-out falls after the reset.

### Below the chart

One key line explains the marks: start, reset, Now, shaded forecast, and the faint previous window when shown. Each quota window then has one summary in provider order. The first line gives the provider and window, % left, and the outlook: "Out … at this pace", "Lasts to reset · would run out … at this pace", "Lasts through reset", "No usage yet" or "Waiting for enough usage to estimate". The second line gives the exact reset time and countdown. The third gives the exact window start and the last capture, flagged when stale. This replaces the separate legend, forecast grid and per-provider start/reset/remaining/capture rows.

### Combined chart labels

Combined Session and Weekly stay one overlaid chart. A colour key in the chart header (● Codex ● Claude) names the lines. Each latest point is labelled with its value in the provider colour ("65%", or "100% · no usage yet") instead of a floating provider-name pill. Reset and run-out labels sit away from the lines, so they keep the provider name.

### Early resets and the axis end

A window's chart ends at its reset. A projected run-out after the reset never happens, so it no longer stretches the axis. Before this, a fresh week with 1% used pushed the Weekly axis about a month out. Instead, a hollow marker at the reset shows the projected remaining % ("lasts to reset"), and the hypothetical date stays in the label and the summary.

The previous window (Session and Weekly, while the current window is in its first half) is now the window captured immediately before the current one. That includes a window the provider reset early, whose scheduled reset lies after the new start. For example, Codex replaced a 70%-used week at 05:37 on Oct 7, 2.5 days before it was due. In that case, a faint dashed rule marks where it was cut off. Idle windows (0% throughout) are skipped. Codex reports a rolling reset time for them, so they are not real windows.

Event labels share one pattern: "<Provider> resets <when>" in the top lanes, and "<Provider> runs out <when>" or "<Provider> lasts to reset" in the bottom lanes. Both adds "5h"/"wk". The hypothetical after-reset date appears only in the summary row.

Every window starts at 100% left, but CodexBar captures roughly hourly, so the first recorded point can come up to an hour after the start marker. A faint dotted segment joins the start marker to the first capture (actual-time views only). This shows the known starting value without implying a recorded path in between.
