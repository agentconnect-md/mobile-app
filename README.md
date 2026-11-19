# AgentConnect

A Flutter iOS app to follow your agents: answer approval requests, browse sessions, chat with an agent,
and see the daemons that run them. The UI follows the design "AgentConnect Mobile Lite" (claude.ai design
project "AgentConnect App Design"): gray/white surfaces, magenta brand, Geist / Geist Mono, light and plum dark.

## Screens (from the design)
- **Home**: org header (approvals badge, light/dark toggle, avatar → Settings), greeting, "Needs your approval"
  (first waiting request, "+N more waiting in Approvals"), "Ask <agent> anything…" box with agent picker
  (opens a new web chat with the message), Agents online / Running now / Daemons up, Recent sessions,
  offline daemons card.
- **Approvals** (shield in the header, "All" on Home): Pending · N / Decided. Cards show agent, age, a "Join"
  tag for join requests, the server's secret-masked request in a code box, the conversation link and the
  server's options as given (reject, always, once). "Always allow" asks for Face ID / passcode first.
- **Agents**: list (status dot, model · daemon, new-chat button) → detail (description, Chat with,
  Status / Model / Runtime / Daemon, Channels, Recent sessions). Configuration stays in the desktop console.
- **Sessions**: All / Running / Web chat, last reply preview, new chat.
- **Infra**: Cloud pool (members shown as one row) and self-hosted daemons with status, version,
  running sessions and CPU. Read-only. A daemon an owner hasn't approved shows Pending approval / Revoked instead
  of its health; tapping a self-hosted daemon shows its approval (source, when, by whom) and, for owners, an
  "Open in console" link (approving is interactive-only on the server, so the app never offers it).
- **Conversation**: header (agent · place · running/idle, link to the original platform, workspace button with
  the running-task count), transcript with "Ran N commands" groups, task cards under the message that started
  them ("N replies" opens the task's own thread, whose box replies to that task only), approvals waiting in it,
  and the message box with run chips (model · effort, permission). The live chat opens on the first send
  (continuing via the session's web chat token; 403/409 → read-only note).
- **Message text**: agent messages render Markdown like the console's transcript (`flutter_markdown_plus`, GitHub
  flavored: headings, lists, quotes, tables, code in `GeistMono` that scrolls sideways; a single newline breaks the
  line). Only http, https and mailto links open, in the external browser; any other link shows as its label. Over
  100,000 characters, or if the parser fails, the message shows as plain text. Your own messages show as typed.
- **Threads** (coordinator web chats on daemons with `webchat-threads-v1`): the timeline is read with `view=roots`, so
  thread replies stay off it; each root gets its thread's footer (holding task and state, repliers, reply count, last
  reply), a message handed to a task shows "Replied to a thread: …", and rows the agent wrote in a thread become one
  "In thread: …" line. A footer, or long press → Reply in thread, opens the thread full screen (older pages on demand,
  refreshed on live activity). A task-held thread writes through the task's continuation with `thread` (run settings
  and the task's approvals there too); an unowned thread writes to the coordinator on the conversation's chat. Older
  daemons (409 `DAEMON_FEATURE_MISSING`) keep the flat view and task cards.
- **Share links**: long press on a message → Copy text / Share link to message (`/<org>/sessions/<id>#msg=<seq>`,
  stored messages only); the conversation header's Share shows the session link, who can open it (`visibility`)
  and Copy link. Console session links opened on iOS (universal links on the console host, warm or cold start)
  open the session, page back until `#msg=<seq>` is loaded, scroll to it and highlight it; a link this sign-in
  can't read (or another org's) shows a not-found state.
- **Composer helpers**: the runtime's predicted next prompt (`prompt_suggestion`) shows as a chip above an empty box;
  tapping it fills an editable draft (never sent by itself), and sending or an empty prediction clears it. A leading
  `/` or `!` opens a list: console commands first (`stop` while a turn runs; `model`, `effort`, `permission`, `fast`
  when the run chips would allow them; aliases `cancel`, `models`, `permissions`/`perm`), then the agent's skills
  (`GET /agents/{id}/commands`, `/` only). Commands run as console actions; their text never reaches the agent.
- **Fill card** (live chat and task threads): an agent with computer use asks the person to fill a website form.
  Shows the computer, the website origin and title (and a frame's origin), the agent's reason as plain text, and
  one control per field; every secret is masked (with a show toggle). Fill sends `fill_submit` with only what was
  entered and clears it at once; Cancel declines; `fill_resolved` settles the card; an expired or settled card is
  read-only. Values live only in the card's widget state: never logged, saved as a draft or kept in a transcript.
- **Attachments** (the box's + button; new chat, session and task thread): photo library, camera or files. Where
  the deployment has file transfer and the agent's daemon fetches uploads (`file-transfer-v2`,
  `webchat-upload-previews-v1`), up to 10 images and files per message, each uploaded first (one presigned PUT;
  images get a 16 KiB preview) with progress, retry and remove; Send waits for them. Otherwise one image, shrunk
  to 160 KiB and sent inline. A continued session follows `continuationAttachments` (images only for a mirrored
  Slack thread, none when null). Messages draw images and files as same-size cards; images open full screen. Files
  can't be downloaded back (no endpoint), as in the console.
- **Run settings** (the chips): model, effort and permission preset for the session's next turn, from the
  session's own status snapshot (models fall back to the daemon's runtime catalog). Sent over the live chat.
- **Workspace** (header button): Tasks (threaded tasks with state, age and summary), Files (workspace folder,
  branch and change count; rows with a kind icon, size · age and the git M / A tag; folders open with a breadcrumb
  back), Git (branch, base, changes with +/−, tap to view, commit message → stage + commit; needs edit access).
  The design's Computer tab is not built yet.
- **File view** (read-only, in memory only), like the console's viewer: code with line numbers and highlight.js
  colors (`re_highlight`, the console's token palette; wrap toggle, copy), Markdown rendered with a Preview / Code
  switch (relative links and images open from the workspace), images (zoomable, size shown) and PDFs (`pdfrx`) from
  the raw download route (≤ 8 MiB), "Load more" for text over the 64 KiB slice, binary files named with their size.
- **Settings** (avatar): organizations (switch, Add organization, Sign out), approval alerts, about.

Design decisions that replace the original task document: tabs are Home / Agents / Sessions / Infra (no Inbox
or Settings tab; approvals live on Home and their own screen); Infra and the word "daemon" are shown as in the
design; the "Only mine" filter is gone (All / Running / Web chat).

## Platform look
One codebase, two looks. iOS follows Apple's Human Interface Guidelines where they differ from Material; Android
keeps the Material look. Every iOS branch is behind `isIOS` (`lib/ui/platform.dart`):
- `lib/ui/icons.dart` (`AppIcons`): each icon is its Material glyph on Android and the matching SF-style glyph
  (`CupertinoIcons`) on iOS. Use `AppIcons.x`, not `Icons.x`, in app code.
- `lib/ui/tab_bar.dart`: system-style tab bar on iOS (49 pt, filled selected glyph), `NavigationBar` on Android.
- `lib/ui/adaptive.dart`: `confirmDialog` (system alert / Material dialog), `showActionMenu` (action sheet / bottom
  sheet), `Spinner` (activity indicator / Material ring).
- `lib/ui/theme.dart`: on iOS no ink ripple, a 44 pt navigation bar with a centered 17 pt title (`rootTitle` gives
  the tab screens a large left title), floating notices. Pull-to-refresh and the alerts switch use `.adaptive`.
- The workspace sheet switches Tasks / Files / Git with a segmented control on iOS (underlined tabs on Android).
- `Haptics` (iOS only): tab and segment changes, send, long-press menu, approval decisions.
- Brand colors and the Geist typeface are the same on both. `test/platform_ui_test.dart` checks the split.

## Build
Builds run on a remote macOS builder with `runbuild <project-id>` using `.airbuild/airbuild.yaml`:
`flutter pub get`, `flutter gen-l10n`, `flutter build ios --config-only`, then `airbuild-xcode archive`
(Runner.xcarchive; the app inside is ad-hoc signed by Xcode, which the iOS Keychain needs on the simulator).
Tests: `runtest <project-id> --script unit` (`flutter analyze` + `flutter test`).
Locally with Flutter: `flutter pub get && flutter gen-l10n && flutter run` (iOS simulator 17.4+).
Android is not a target: the sign-in bridge is iOS-only.

## CI and releases (GitHub Actions)
- `.github/workflows/ci.yml` (push to `main`, pull requests, manual): `flutter analyze` + `flutter test`, then an
  Android debug APK (kept 7 days as a workflow artifact) and an iOS simulator build without signing (macOS runner).
- `.github/workflows/release.yml`: **publishing a GitHub release tagged `vX.Y.Z`** builds the Android release with
  version name `X.Y.Z` (build number = run number) and attaches `agentconnect-X.Y.Z.apk`, `.aab` and `SHA256SUMS`
  to the release. "Run workflow" (manual) builds the same files as an artifact only.
- Release signing uses repository secrets `ANDROID_KEYSTORE_BASE64` (base64 of the `.jks`), `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (read by `android/app/build.gradle.kts` as `AC_ANDROID_*`). Without them
  the files are signed with a debug key and named `…-debugsigned` (installable for testing, not for Play).
  The repository variable `ANDROID_SIGNING_LABEL` marks a non-production key in the file names (`test` →
  `agentconnect-X.Y.Z-test.apk`); remove it when the secrets hold the production upload key.
- The secrets currently hold a **test-environment key** (alias `test`, SHA-256 `45:71:60:A8:…:25:98`), so test
  builds update each other in place. Keep the `.jks` and its password outside the repository.
- Flutter is pinned to 3.47.9 in both workflows.

## Environment and sign-in setup
The server is built in: there is no address field in the app. Addresses live only in
`ios/Flutter/Environment.xcconfig` (and, through its variables, in `ios/Runner/Runner.entitlements`). This package
is the Test environment; the README shows example values:

```
AC_API_HOST = api.example.test              // API base = https://$(AC_API_HOST)$(AC_API_PATH), path /v1
AC_CALLBACK_HOST = console.example.test      // web console: /mobile/oauth/callback and the AASA file
```

A production package gets its own xcconfig with the production hosts and `AC_URL_SCHEME = agentconnect`.
`Environment.local.xcconfig` (git-ignored, optional) can override the values for a local build.

- Associated Domains: `applinks:$(AC_CALLBACK_HOST)`, `webcredentials:$(AC_CALLBACK_HOST)`. The server's
  `apple-app-site-association` must list `<TEAMID>.com.yulong.agentconnect`; until it does, iOS won't hand the
  https callback to the app and the callback page's "Return to AgentConnect" button is used instead.
- `AC_HTTPS_CALLBACK = NO` until the AASA file is live (iOS closes an `.https` sheet at once without it); the sheet
  then completes on the fallback scheme below. Set `YES` afterwards.
- Fallback URL scheme: `agentconnect-test` (Test package; a production package would use `agentconnect`).
  `agentconnect-test://oauth/callback?code=&state=` is handed to the waiting sign-in, with the same `state` check.
- Deployment target iOS 17.4 (`ASWebAuthenticationSession` https callbacks).

## Sign-in (OAuth 2.1 + PKCE, public client)
1. Sign in always uses the server built into the package (no address to type; self-hosted servers need their own build).
2. Discovery: `{api origin}/.well-known/oauth-protected-resource` → `authorization_servers[0]` →
   `/.well-known/oauth-authorization-server` (may be another host). The test API host has no metadata, so the app
   also follows the `WWW-Authenticate: resource_metadata` challenge of `POST {api}/v1/mcp`.
3. Dynamic registration (`AgentConnect for iOS`, https redirect only), `client_id` cached per server in the Keychain,
   renewed before its 90 days run out and re-registered silently on `invalid_client`.
4. `ASWebAuthenticationSession` (not ephemeral, so the Safari console sign-in is reused) → consent page (choose
   org, Authorize) → code + `state` check → token exchange (`code_verifier`, `resource`).
5. Access token ~1 h, refreshed 60 s before expiry or after a 401, one refresh at a time; rotated refresh tokens are
   saved before use. A rejected refresh (revoked in the console Profile page, 30 days unused) shows
   "You were signed out" with "Sign in again".
6. One sign-in = one organization. Settings → Add organization runs it again; accounts are keyed by server + org.
7. Sign out deletes the local tokens (the server has no revocation endpoint yet; see API_NOTES).

Tokens and `client_id` are in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); PKCE verifier and
`state` only in memory. Code: `lib/core/auth/` (`oauth.dart` protocol, `sign_in_flow.dart`, `oauth_session.dart`
token provider, `native.dart` + `ios/Runner/AppDelegate.swift` sheet/callback bridge). Everything else gets tokens
only through `TokenProvider`. Personal API key sign-in was removed (out of scope).

## Architecture
- `lib/core/api`: thin hand-written REST client (`dart:io`; not generated from OpenAPI), models, approvals. Never logs URLs, headers or bodies.
- `lib/core/auth`: OAuth sign-in and token refresh, accounts (server + org), app state, Face ID/passcode (before "always allow" only).
- `lib/core/streaming`: hand-written SSE parser and org event stream (reconnect with backoff and every 5 min, stopped when the app is paused, full refresh on every connect).
- `lib/core/webchat`: live chat frames, ordering by index, WebSocket controller. Transcripts are in memory only.
- `lib/core/org_data.dart` (agents, daemons, recent sessions; refreshed on live events), `lib/core/approvals_controller.dart`.
- `lib/features/{home,approvals,agents,sessions,infra,chat,settings,signin}`, `lib/ui` (design tokens in `theme.dart`, shared widgets), `lib/l10n/app_en.arb` (all UI strings).
- Debug builds only, for screenshots: `xcrun simctl launch <device> com.yulong.agentconnect -acDebugTab 2` starts on a
  tab, `-acDebugOpen 1` opens the first recent conversation (Android: `adb shell am start -e acDebugTab 2 ...`).
- Android: the same sign-in bridge in `MainActivity.kt` (Custom Tabs + `agentconnect-test://oauth/callback`); hosts are
  read from the same `ios/Flutter/Environment.xcconfig` by `android/app/build.gradle.kts`.
- `test/`: JSON decoding with anonymized fixtures, SSE parser, chat frames, approval dedupe, OAuth (discovery, registration, PKCE, state, invalid_client retry, refresh single-flight, revoked grant, sign-out).

## Dependencies
Geist and Geist Mono fonts (`assets/fonts`, SIL Open Font License, `OFL-Geist.txt`): the design's typefaces.
flutter_secure_storage (Keychain), local_auth (Face ID), shared_preferences (non-secret prefs: current account, alert toggle),
crypto (SHA-256 for PKCE). The sign-in sheet is a small native bridge in AppDelegate.swift (no plugin: it must also
finish the waiting sheet when the fallback scheme arrives), url_launcher (open a conversation in Slack/GitHub), flutter_localizations + intl (ARB strings).
No analytics or crash SDKs.

## Privacy
Message content and tool arguments are never logged, written to disk or put in notifications.

## Known limitations
- Approval alerts (local notification and background refresh) are not implemented; the toggle only stores the preference.
- Sign-in has not yet been run against the test environment (hosts and Team ID pending); see API_NOTES "Still to verify live".
- The in-chat approval reply (`permission_choice`) is derived from the protocol sources and was not exercised live.
- Approval decisions and the 409/503 paths were not exercised against live data (no pending request existed).
- Chat shows streamed replies below the transcript; a finished turn is reloaded when the conversation is reopened.
- Only English strings. Settings → Privacy opens agentconnect.md/privacy, Support opens the docs (no support page yet).
- Only the first page of older messages loads on demand; tool bodies use the tool-body endpoint.
