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
  **Waiting for you** (Pending tab, while the screen is open): what the org's assistant-mode agents wait on a
  person for, read per agent (`GET /agents/{id}/assistant/drafts`, agents this account may edit; refreshed every
  45 s and on pull). A message draft shows where it would post, the exact text, who approves and when it lapses,
  with **Approve** / **Discard**; a suggested task or follow-up shows its sentence, why, the task or the follow-up
  it would take, with **Approve** / **Deny**. Each asks for confirmation, then posts
  `…/drafts/{draftId}/decision`; the card then says what the decision did (posted, runs as a task, taken, denied,
  failed with its reason, expired, already decided, not confirmed) until **Dismiss**.
- **Agents**: list (status dot, model · daemon, new-chat button) → detail (description, Chat with,
  Status / Model / Runtime / Daemon, Channels, Recent sessions). Configuration stays in the desktop console.
- **Sessions**: All / Running / Web chat, last reply preview, new chat.
- **Infra**: Cloud pool (members shown as one row) and self-hosted daemons with status, version,
  running sessions and CPU. Read-only. A daemon an owner hasn't approved shows Pending approval / Revoked instead
  of its health; tapping a self-hosted daemon shows its approval (source, when, by whom) and, for owners, an
  "Open in console" link (approving is interactive-only on the server, so the app never offers it).
- **Schedules** ("All" in Home's Schedules section, which lists the next three runs): the org's scheduled runs
  (the console's crons) with name, agent, when they run ("Weekdays at 09:00" for the hourly / daily / weekdays /
  weekly shapes, otherwise the cron expression; the zone is named when it isn't the phone's), next run, and
  enabled / paused / invalid. A schedule's page shows its prompt, cron, time zone, next and last run, where it
  posts, who can see it, who made and changed it, and recent runs (Running / Success / Failed, start, duration,
  reason; a run with a session opens it). With write access and edit rights on the schedule: a switch to turn it
  on or off and **Run now** (asks first; the server's reason is shown when it refuses). Adding, editing and
  deleting stay in the desktop console. The next run is worked out on the phone (`lib/core/cron.dart`, same rules
  as the daemon's cron library, zones from the `timezone` package); the daemon decides when it really fires.
- **Conversation**: header (agent · place · running/idle, link to the original platform, workspace button with
  the running-task count), transcript with "Ran N commands" groups, task cards under the message that started
  them ("N replies" opens the task's own thread, whose box replies to that task only), approvals waiting in it,
  and the message box with run chips (model · effort, permission). The live chat opens on the first send
  (continuing via the session's web chat token; 403/409 → read-only note).
- **Message text**: agent messages render Markdown like the console's transcript (`flutter_markdown_plus`, GitHub
  flavored: headings, lists, quotes, tables, code in `GeistMono` that scrolls sideways; a single newline breaks the
  line). Only http, https and mailto links open, in the external browser; any other link shows as its label. Over
  100,000 characters, or if the parser fails, the message shows as plain text. Your own messages show as typed.
- **Transcript navigation**: a conversation opens on its latest message. "Load earlier messages" pages back with the
  messages cursor until the start; older pages sit above a fixed anchor (`lib/features/chat/transcript_scroll.dart`),
  so adding one leaves the rows on screen where they are, and a refresh keeps the pages already loaded
  (`lib/features/sessions/transcript_pager.dart`). A finished turn joins the stored transcript without reopening:
  the transcript is read forward from the last page's `liveCursor` (`after=`; the newest page again on daemons
  without one) and merged by seq, and the stored rows take the live copy's place (`lib/features/chat/live_turn.dart`).
  The list follows new rows only while the person is at the latest one; scrolled up, a round "Jump to latest" button
  floats over the list's bottom right corner with a count of the messages that arrived meanwhile. Sending goes to
  the latest row. A "New" divider marks the first row that arrived since the conversation was last read on this
  device (taken when it opens and when the app comes back to the front); when it is above the screen the
  conversation opens on it instead of the latest row. The conversation counts as read while its latest row is on
  screen with the app in front. `lib/core/last_read_store.dart` keeps only session id and seq (`shared_preferences`,
  the 300 most recently read sessions, cleared when the last account signs out); never message content.
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
- **Sending while the agent runs**: a message sent mid-turn is queued and goes out when the turn ends, one per
  turn, in order. Queued messages show above the box (attachments wait with them), each with "Cancel queued
  message"; they live in memory only and are dropped, with a note above the box, if the connection is lost or the
  conversation turns read-only. When the turn's status says `steerable`, a text-only message goes into the running
  turn instead (`steer: true`; one agent, root conversation, nothing already queued) and is tagged "Steering…",
  then "Steered" once the daemon confirms; a `busy` refusal puts it back in the queue where it was sent. With an
  empty box the send button is Stop while a turn runs. Console commands are never queued.
- **Reconnecting mid-turn**: when the chat's connection drops while a turn runs, the new connection picks the turn
  up again with the console's `resume` op (turn id, a `generation` that rises with each resume, and `afterIndex`,
  the last output applied): the daemon replays what was missed and the turn ends on its `done`. A turn nobody had
  answered yet is sent again under the same turn id instead (within four minutes of the first send, while the
  daemon still answers a second copy `busy` rather than running it). The relay's `resync` (the agent's machine
  relinked) asks for the same replay. If the turn can't be picked up it ends and the transcript reloads: without
  a word when the daemon no longer holds the turn (it is over), with a note above the box when the agent may
  still be working (too much was missed, the agent's machine is offline, or the conversation has several agents)
  or when an unanswered message may never have arrived.
- **Fill card** (live chat and task threads): an agent with computer use asks the person to fill a website form.
  Shows the computer, the website origin and title (and a frame's origin), the agent's reason as plain text, and
  one control per field; every secret is masked (with a show toggle). Fill sends `fill_submit` with only what was
  entered and clears it at once; Cancel declines; `fill_resolved` settles the card; an expired or settled card is
  read-only. Values live only in the card's widget state: never logged, saved as a draft or kept in a transcript.
- **Question card** (live chat and task threads): the agent asks in the conversation (`elicitation`). One choice
  answers on the tap; a multi-select holds its picks until Confirm; a typed answer (text or number) and a form of
  up to ten questions are checked against the card's own constraints before Submit; a question's "Other…" box is
  part of that question. A link card shows the URL as written with the host emphasized, warns about `http`, text
  before an `@` and non-ASCII hosts, and opens the browser only on **Open link**. Every answer is one
  `elicitation_choice` (`null` dismisses or declines); the daemon settles the card with `elicitation_resolved`
  (answered with the chosen label, dismissed, cancelled, completed), so a refused answer leaves it open, and a card
  still open when its turn ends reads Cancelled. What is picked and typed lives only in the card's widget state.
  A saved `elicit` row is the same card, read-only, with how it ended.
- **MCP write approval** (web chats the person owns): a change an agent asks AgentConnect's own MCP tools to make
  waits for the conversation's owner. The chat lists what is pending
  (`GET /agents/{id}/webchat/{conversationId}/mcp-operations`, asked again every 3 s and when a turn ends) with
  the tool and its arguments; **Approve and run** / **Deny** post `…/{operationId}/decision`. The settled card
  reads Completed (with the result), Failed, Denied, Expired, Outcome uncertain, or Executing… / Outcome unknown
  with **Check status**; a known outcome is told to the agent as an `[approval] …` turn (after the running turn,
  if one is). Where tasks write under the conversation's grant, each chat shows only the operations its own rows
  name. A task-held thread doesn't show them yet.
- **Capability request card** (live `capability_request` events and saved `capability` rows): the agent asks for
  something it lacks (a setting, an MCP server, a repository, a secret, a scheduled task). Shows the summary and
  the agent's reason as plain text, then reads the request (`GET /capability-requests/{id}`; again when the app
  comes back to the front) for where it stands: waiting with its expiry, who can act (you, or the people the
  server names and why you can't), or how it ended (completed / declined by whom, with the note or what changed;
  expired; withdrawn). **Open in console** goes to the request's page. Making the change and declining are not
  offered here: the server takes both only from an interactive console sign-in and answers this app's OAuth token
  403.
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

## TestFlight (from a Mac)
`scripts/testflight.sh` builds, signs and checks an App Store IPA (`build/ios/ipa/`); `scripts/testflight.sh --upload`
also sends it to App Store Connect. `--build-name` defaults to the version in `pubspec.yaml`, `--build-number` to the
hour as `yyMMddHH` (it must be higher than the last upload of that version).
- Needs: Xcode, Flutter on PATH, the team's "Apple Distribution" certificate in the keychain, and that team's Apple
  account signed in to Xcode (Settings > Accounts). The script reads no password or API key.
- The team is `AC_IOS_TEAM_ID`, or `DEVELOPMENT_TEAM` in the git-ignored `ios/Flutter/Environment.local.xcconfig`.
- It builds whatever is checked out, for the environment in `ios/Flutter/Environment.xcconfig` (Test), and prints the
  commit, version, team and environment before it starts.
- Before uploading it checks the IPA (bundle id, version, distribution signature, every entitlement of
  `Runner.entitlements` present) and stops if anything is off. Without `--upload` nothing leaves the Mac.
- The archive is built unsigned and given the app's entitlements with an ad-hoc signature before Xcode's export signs
  it: automatic signing cannot archive for a team with no registered devices, and an unsigned archive would lose
  Associated Domains. The script's header has the details.
- After an upload: Apple processes the build; then add testers in App Store Connect > TestFlight.
- Export compliance: `Info.plist` sets `ITSAppUsesNonExemptEncryption` to false, so App Store Connect does not ask
  the encryption question for each build. The app has no encryption of its own design; it uses standard algorithms
  only (TLS from the Flutter engine for HTTPS and WebSocket, PDFium for protected PDFs, the iOS Keychain for
  tokens), which need no documents in App Store Connect unless the app is on the App Store in France. Before
  distributing there, or adding other encryption, file the French encryption declaration in App Store Connect and
  set the key to true with the `ITSEncryptionExportComplianceCode` Apple then gives.

## CI and releases (GitHub Actions)
- Jobs run on **self-hosted runners**, not GitHub-hosted ones: analysis, tests, the Android builds and the Android
  release on the organization's Linux runners (labels `self-hosted, Linux, X64`); the iOS simulator build on the
  team's Mac (`self-hosted, macOS, ARM64`), the only job that needs Xcode. The workflows install Flutter (pinned),
  JDK 17 and the Android SDK tools themselves; Xcode and CocoaPods come from the Mac. While the Mac is offline only
  the iOS job waits.
- `.github/workflows/ci.yml` (push to `main`, pull requests, manual): `flutter analyze` + `flutter test`, then an
  Android debug APK (kept 1 day as a workflow artifact) and an iOS simulator build without signing.
- `.github/workflows/release.yml`: **publishing a GitHub release tagged `vX.Y.Z`** builds the Android release with
  version name `X.Y.Z` (build number = run number) and attaches `agentconnect-X.Y.Z.apk`, `.aab` and `SHA256SUMS`
  to the release. "Run workflow" (manual) builds the same files as an artifact only (kept 3 days).
- Release signing uses repository secrets `ANDROID_KEYSTORE_BASE64` (base64 of the `.jks`), `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (read by `android/app/build.gradle.kts` as `AC_ANDROID_*`). Without them
  the files are signed with a debug key and named `…-debugsigned` (installable for testing, not for Play).
  The decoded keystore is deleted at the end of every release job, since the runner outlives it.
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

### Developer menu (packages for testers)
With `AC_DEBUG_MENU = YES` in the xcconfig (as in this Test package), shaking the phone opens a "Developer" sheet;
Settings > Developer > Server and the "Server: …" line under the Sign in button open the same sheet. A package
for the App Store sets `AC_DEBUG_MENU = NO`: the app then has none of it and ignores a choice stored earlier.
- It chooses the server the **next sign-in** uses: the package's own, the second server the xcconfig names
  (`AC_ALT_ENV_NAME`, `AC_ALT_API_HOST`, `AC_ALT_API_PATH`, `AC_ALT_CALLBACK_HOST`, `AC_ALT_URL_SCHEME`; Production
  here), or a custom one (API address, console host, URL scheme). The choice is kept across launches
  (`shared_preferences`: addresses only).
- Organizations already signed in stay on the server they were signed in to; each account records its API base, and
  console links are built from that server's console host. Signing in on another server adds an organization beside
  them.
- A server other than the package's own always completes sign-in on its URL scheme: Associated Domains cover only
  `AC_CALLBACK_HOST`, so the https callback and universal links work for the package's own console only. The scheme
  is handed to `ASWebAuthenticationSession` and need not be registered in `Info.plist`. The server's console has to
  serve `/mobile/oauth/callback`, and that page's button has to open the scheme.
- Measured 2026-11-20: `api.agentconnect.md` answers the API, but `app.agentconnect.md/mobile/oauth/callback` is
  "Not found", so a Production sign-in cannot finish until the console there serves the callback page.
- The shake is seen in `UIWindow.motionEnded` (`ios/Runner/AppDelegate.swift`); it does not reach the app delegate.
  In the simulator: Device > Shake.

## Sign-in (OAuth 2.1 + PKCE, public client)
1. Sign in uses the server built into the package (no address to type; self-hosted servers need their own build).
   Packages for testers can choose another server in the developer menu above.
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
flutter_secure_storage (Keychain), local_auth (Face ID), shared_preferences (non-secret prefs: current account, alert toggle, read positions),
crypto (SHA-256 for PKCE). The sign-in sheet is a small native bridge in AppDelegate.swift (no plugin: it must also
finish the waiting sheet when the fallback scheme arrives), url_launcher (open a conversation in Slack/GitHub), flutter_localizations + intl (ARB strings).
No analytics or crash SDKs.

## Privacy
Message content and tool arguments are never logged, written to disk or put in notifications.
How far a conversation was read is kept on the device as a session id and a transcript seq, nothing else.

## Known limitations
- Approval alerts (local notification and background refresh) are not implemented; the toggle only stores the preference.
- Sign-in has not yet been run against the test environment (hosts and Team ID pending); see API_NOTES "Still to verify live".
- The in-chat approval reply (`permission_choice`) is derived from the protocol sources and was not exercised live.
- Approval decisions and the 409/503 paths were not exercised against live data (no pending request existed).
- Queueing and steering mid-turn follow the protocol sources and unit tests; neither was exercised against a live daemon.
- Resuming a turn after a reconnect follows the protocol sources and unit tests; not exercised against a live daemon.
  A chat reopened mid-turn does not attach to the running turn (the console's `attach` probe), and a turn that
  goes quiet on an open connection is not probed (the console's stall watch).
- A live turn is shown from the chat stream until its reply is in the stored transcript (or, failing that, 3 s
  after the chat goes quiet); until then the turn's stored rows are hidden as a whole, not merged row by row.
- Only English strings. Settings → Privacy opens agentconnect.md/privacy, Support opens the docs (no support page yet).
- Earlier messages load one page per tap ("Load earlier messages"), not on scroll; tool bodies use the tool-body
  endpoint.
