# MEMORY.md — DockClickMinimize

## 2026-10-13 — Snappier timings (user confirmed working)
- **Decided:** The gap between restoring the other windows and the last-active one went from 250ms to 100ms; it's the only wait the user can see. The final raise now runs only when user-minimized windows (stragglers) were restored after the active one, since those land on top. The 250ms wait before the straggler check stays because nothing visible happens during it. The minimize retry now polls every 100ms, up to 6 times, instead of every 250ms up to 3 times.
- **Kept (user's call):** A Dock click also restores windows the user minimized themselves (yellow button or Cmd+M).
- **Resources:** All of this runs only on Dock clicks. The always-on cost is the event tap, already minimized in July, so nothing further was changed there.
- **If 100ms is too short** for Word/Excel (the active window doesn't end up on top), raise that gap back toward 250ms.

## 2026-10-13 — Restore order: others first, active last (user confirmed working)
- **Decided (user preference):** In restore-all mode, the other windows restore first, then the previously active window restores LAST and stays on top (raised after a 250ms wait). Only windows recorded in the ledger at minimize time are restored in that first pass, matched by AXWindowNumber when the app exposes it, otherwise by title. Anything still minimized after that (windows the user minimized themselves) is restored afterwards, then the active window is raised.
- **Why:** Round 4 restored the active window first, so in Word/Excel/Brave the other window ended up on top, and Finder visibly jumped back to the active window.
- **Also decided:** Pointer-based fallback window IDs are never used for matching (AXWindowInfo.hasStableID). The Finder dump showed element pointers being reused for different windows between reads.
- **Supersedes:** the restore order in round 4 below. Background Finder tabs still never get un-minimize requests, because they aren't in the ledger.

## 2026-10-13 — Finder tab fix round 4 (tab bug confirmed fixed by user)
- **Observed (AX dump):** While open, a tabbed Finder window lists only the selected tab as an AX window. While minimized, every tab is listed as its own minimized window (subrole AXDialog), in this order: selected tab first, then the tabs after it. No AXWindowNumber, and element pointers change on every read, so the last-active window can only be matched by title. Restores flipped between the correct tab and the first tab.
- **Decided:** Restore now un-minimizes ONLY the last-active window first. In restore-all mode it then waits 250ms, re-reads the window list, un-minimizes whatever is still minimized (genuinely separate windows), and raises the last-active window after another 250ms. Sibling tabs never get un-minimize requests.
- **Rejected:** The round-3 approach of un-minimizing every tab with the last-active one last — it raced and was the cause of the intermittent wrong tab.

## 2026-10-13 — Excel/Word minimize-all fix (user confirmed working)
- **Decided:** After minimizing, WindowController re-reads each target's real AXMinimized state and retries the ones still open (up to 3 passes, 250ms apart). Excel and Word were minimizing only one window per Dock click while restore-all worked; the likely cause is that Office drops minimize requests that arrive while a minimize animation is running (unconfirmed).
- **Rejected:** Reversing the minimize order (front window last) — also a guess, and it doesn't verify that the windows actually minimized.
- **Note:** The `--dump-finder com.microsoft.Excel` diagnostic hung with no output, so Excel's AX tree has not been inspected.

## 2026-07-23 — Finder tab fix round 3 + performance overhaul (v1.4)
- **Decided (tabs):** Restore now un-minimizes the last-active window LAST (macOS selects the most recently un-minimized tab), then after a 250ms delay raises it and sets AXMain. Previous single immediate raise fired during the un-minimize animation and was ignored, causing the observed tab cycling.
- **Decided (perf):** buildWindowInfo now uses AXUIElementCopyMultipleAttributeValues — one AX IPC per window instead of ~10. Dropped per-window canSetMinimized/canRaise probes: minimize just attempts the set and records success; capability probes remain only on the rare modal-assessment path. Screen frames for the dock-edge pre-filter are cached and refreshed via didChangeScreenParametersNotification instead of queried per click.
- **Rejected:** Reading Dock orientation from com.apple.dock defaults to shrink the edge-filter region — brittle (no change notification when the user moves the Dock) for negligible gain over the three-edge check.
- **Known floor:** the CGEvent tap itself wakes the process once per left-click system-wide; that is inherent to being able to consume Dock clicks and cannot be optimized away.

## 2026-07-21 — Stable code signing (v1.3)
- **Decided:** make_app.sh now signs with the existing "Apple Development: anti135@gmail.com" certificate (found already in the keychain, originally set up via Xcode), falling back to ad-hoc with a warning if absent. Designated requirement is now bundle-id + certificate, so Accessibility/Input Monitoring grants survive rebuilds.
- **Why:** Ad-hoc signing changed the signature every build, invalidating TCC grants each release (the v1.2 permission problems).
- **Rejected:** Creating a new self-signed cert — unnecessary since a real Apple Development cert already existed.
- **Note:** Apple Development certs expire after ~1 year; if signing starts failing, renew via Xcode (sign in with Apple ID) and rebuild.

## 2026-07-21 — Permission detection fixes (v1.2)
- **Decided:** Input Monitoring status now uses CGPreflightListenEventAccess (with CGRequestListenEventAccess for the prompt) instead of probing by creating an event tap; Settings and Onboarding auto-refresh permission status every 2s while their window is open.
- **Why:** The tap-probe could misreport when only Accessibility was granted; status previously only updated on manual Refresh, so the app "didn't view permissions correctly".
- **Known limitation:** Ad-hoc signing means every rebuild changes the app's signature fingerprint, so macOS invalidates the Accessibility grant on each new version — the System Settings toggle can show ON while TCC actually denies. Users must remove the entry (minus button) and re-add/re-grant after each update. Durable fix would be signing with a stable self-signed code-signing certificate (requires user to create one in Keychain Access) — offered, not yet done.

## 2026-07-21 — Finder fix round 2 (v1.1)
- **Decided:** (1) When a clicked app's windows are ALL minimized, the coordinator now consumes the click and restores via our code even when the app isn't frontmost — previously it passed through and the native Dock "reopen" picked an arbitrary Finder window/tab, which is why the v1.0 fix appeared to do nothing. (2) Restore's raise step falls back to matching the last-active window by title when window IDs don't match (AXWindowNumber unsupported in many apps).
- **Why:** First-round fix only helped when our restore path actually ran; the second click was often reaching the native Dock instead.
- **Rejected:** Sharing the restore ledger with the coordinator across threads (needs locking or MainActor.assumeIsolated, which requires macOS 14; platform target is 13). The all-minimized AX check is cheap and only runs on real Dock clicks.

## 2026-07-21 — v1.1 packaging/UI
- Version now lives in Packaging/Info.plist (tracked in git); Settings shows an About section reading it from the bundle ("dev (running unbundled)" under swift run). Bump version there before each release; build with Packaging/make_app.sh.
- Custom AppIcon.icns generated (window + down arrow + dock bar on blue squircle); generator script kept only in session scratchpad — regenerate from a 1024px PNG via iconutil if a redesign is needed.
- Menu bar item is icon-only (SF symbol rectangle.stack.badge.minus), no text, per user preference.

## 2026-07-21 — Finder tab-switch bug fix
- **Decided:** On restore, raise the window recorded as last-active in the restore ledger (WindowController.restoreWindows), falling back to the first restored window only if the ledger has no match.
- **Why:** macOS exposes each Finder tab as a separate AX window. Raising an arbitrary window after restoring switched the visible Finder tab.
- **Rejected:** Not raising any window at all — restore would leave the app without a frontmost window in some cases.

## 2026-07-21 — Battery/CPU optimization of the event tap
- **Decided:** Pre-filter every left-click by screen position (within 160pt of bottom/left/right screen edge) before doing any AX hit-testing; cache the Dock's PID and only re-look it up if the cached process died.
- **Why:** The event tap sees every left-click system-wide; previously each click cost an app enumeration + AX IPC hit-test. The edge filter skips ~95%+ of clicks with pure arithmetic.
- **Rejected:** Reading the Dock's actual frame/orientation from AX or defaults — more accurate but more code and more failure modes; the generous 160pt margin covers max Dock size with magnification. Fails open if screen info is unavailable.

## 2026-07-21 — Code review fixes
- **Decided:** (1) Pass through Dock clicks when the frontmost app has no windows, so native reopen behavior works instead of a dead click; (2) name-based app matching now compares full normalized names, not just the first word; (3) restore ledger prunes entries for terminated apps; (4) removed redundant double dispatch in coordinator, simplified extractBundleIdentifier, aligned settings window height (680) with the view.
- **Why:** Consuming a click before knowing whether anything would happen made clicks vanish; first-word matching could resolve a Dock icon to the wrong running app.
- **Rejected:** Deferring the consume decision until after the full minimize attempt — the event tap must answer synchronously, so a single cheap AX window-count check is used instead.

## 2026-07-21 — App bundle packaging
- **Decided:** Ship as `dist/DockClickMinimize.app`, built by hand from the SwiftPM release binary + Info.plist (LSUIElement=true, bundle id com.anthonycbl.DockClickMinimize), ad-hoc codesigned. `dist/` is gitignored.
- **Why:** SwiftPM alone produces a bare binary; a bundle is needed for install, menu-bar-only behavior, and SMAppService launch-at-login.
- **Rejected:** Xcode project migration (no full Xcode installed) and Developer ID signing (no paid account assumed). Ad-hoc signing means macOS may ask to re-grant Accessibility/Input Monitoring after each rebuild.

## Environment notes
- `swift build` in the default `.build` dir hit a stale module-cache error ("could not build module 'CoreFoundation'"). Resolved 2026-07-21: `.build` deleted with user confirmation; builds work again.
- Machine has Command Line Tools only (no full Xcode): XCTest is unavailable, so the test suite compiles out via `#if canImport(XCTest)` and **zero tests actually execute** locally.
