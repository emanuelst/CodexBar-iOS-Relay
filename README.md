# CodexBar iOS Relay

Shows your [CodexBar](https://github.com/steipete/CodexBar) AI-usage stats on your iPhone,
by running a tiny host app on your Mac that shares them over the **local network** (Bonjour)
or via an iCloud Drive snapshot file.

```
codexbar (CLI)  ->  CodexBar iOS Relay (Mac)  ->  Bonjour / iCloud Drive  ->  CodexBar iOS Relay (iPhone)
```

The Mac app shells out to `codexbar usage --format json` every 60s, wraps the
result with a `syncedAt` timestamp and your hostname, and serves it on an auto-chosen port
advertised as `_codexbarrelay._tcp`. The iPhone app browses Bonjour, fetches `/usage`, and
renders per-provider primary/secondary/tertiary usage bars plus reset details.

## Requirements
- `codexbar` on your PATH (the Mac app calls `/opt/homebrew/bin/codexbar` — edit
  `Mac/UsagePoller.swift` if yours lives elsewhere).
- Mac and iPhone on the **same Wi-Fi/LAN** for Bonjour mode.
- Xcode 26 (project generated with XcodeGen).

## Open & run
```sh
xcodegen generate          # regenerate CodexBarRelay.xcodeproj from project.yml
open CodexBarRelay.xcodeproj
```

In Xcode:
1. Pick your **personal team** for both targets in Signing & Capabilities.
2. Update the bundle IDs in `project.yml` from `com.changeme.*` to your own, then `xcodegen generate` again if needed.
3. **Mac:** select the *CodexBarSyncMac* scheme → run. A menu-bar gauge icon appears (and a small
   status window). It starts serving immediately, even with the window closed.
4. **iPhone:** select the *CodexBarSynciOS* scheme → your iPhone → run. Approve the local-network
   prompt. It finds the Mac within a second or two and shows the stats. Pull down to refresh.

## Files
- `project.yml` — XcodeGen project definition (two app targets, shared sources).
- `Shared/` — `Models.swift` (Codable for the codexbar JSON), `UsageListView.swift` (shared UI).
- `Mac/` — `CodexBarSyncMacApp.swift` (menu bar + window), `SyncController.swift` (owns poller +
  server, starts on init so it runs with no window), `UsagePoller.swift` (runs the CLI),
  `LanServer.swift` (NWListener HTTP server + Bonjour).
- `iOS/` — `CodexBarSynciOSApp.swift`, `ContentView.swift`, `Discovery.swift` (NWBrowser),
  `LanHttpClient.swift` (raw TCP GET over Network.framework).

## Notes / shortcuts
- `codexbar` exits non-zero when some providers fail but still emits valid JSON for the rest;
  the poller trusts stdout, not the exit code.
- `error.code` in the codexbar JSON is sometimes an int, sometimes a string — `FlexStr` handles both.
- Refresh interval is 60s on the Mac, 15s on the iPhone (read-only pulls). Edit in
  `UsagePoller.swift` / `Discovery.swift`.
- iCloud Drive sync works without a paid Apple Developer account because the user explicitly picks the file.
- Proper CloudKit sync is not implemented yet.

## Debug
```sh
# what the Mac is serving:
dns-sd -B _codexbarrelay._tcp .                         # find the instance
dns-sd -L "<HostName>" _codexbarrelay._tcp local.       # resolve host:port
curl http://<host>.local:<port>/usage | python3 -m json.tool
curl http://<host>.local:<port>/health
```
The Mac app logs poller status to stderr (`[codexbarsync] poll ok: N entries …`).
