# AgentConnect

A Flutter (Material 3) iOS app to follow your agents: approve requests from an Inbox, browse
conversations, and chat with an agent. Own theme (warm cream, magenta accent), light/dark, Dynamic Type.

## Build
Builds run on a remote macOS builder with `runbuild <project-id>` using `.airbuild/airbuild.yaml`:
`flutter pub get`, `flutter gen-l10n`, `flutter build ios --config-only`, then `airbuild-xcode archive`
(Runner.xcarchive; the app inside is ad-hoc signed by Xcode, which the iOS Keychain needs on the simulator).
Tests: `runtest <project-id> --script unit` (`flutter analyze` + `flutter test`).
Locally with Flutter: `flutter pub get && flutter gen-l10n && flutter run`.

## Getting an API key
In the Web console open Profile, then API keys, and create a key with Full access for your
organization. Enter the API base URL (ends in `/v1`, e.g. `https://api.example.test/v1`; this is not
the console address) and the key, or scan a QR code containing `{"apiBase":"...","key":"..."}`.
If the key can see several organizations you pick one. You can add several accounts in Settings.

## Architecture
- `lib/core/api`: HTTP client (`dart:io`), models, approvals. Never logs URLs, headers or bodies.
- `lib/core/auth`: accounts (keys only in the iOS Keychain, `first_unlock_this_device`), app state, Face ID/passcode (before "always allow" only).
- `lib/core/streaming`: hand-written SSE parser and org event stream (reconnect with backoff and every 5 min, stopped when the app is paused, full refresh on every connect).
- `lib/core/webchat`: live chat frames, ordering by index, WebSocket controller. Transcripts are in memory only.
- `lib/features/{signin,inbox,conversations,chat,settings}`, `lib/ui` (theme, widgets), `lib/l10n/app_en.arb` (all UI strings).
- `test/`: JSON decoding with anonymized fixtures, SSE parser, chat frames, approval dedupe.

## Dependencies
flutter_secure_storage (Keychain), local_auth (Face ID), shared_preferences (non-secret prefs: current account, alert toggle),
mobile_scanner (QR), url_launcher (open in Slack/GitHub, AirBuild link), flutter_localizations + intl (ARB strings).
No analytics or crash SDKs.

## Privacy
Message content and tool arguments are never logged, written to disk or put in notifications.

## Known limitations
- Approval alerts (local notification and background refresh) are not implemented; the toggle only stores the preference.
- The in-chat approval reply (`permission_choice`) is derived from the protocol sources and was not exercised live.
- Approval decisions and the 409/503 paths were not exercised against live data (no pending request existed).
- Chat shows streamed replies below the transcript; a finished turn is reloaded when the conversation is reopened.
- Only English strings. Privacy/Support links point to air.build placeholders.
- Only the first page of older messages loads on demand; tool bodies use the tool-body endpoint.
