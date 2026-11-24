# Working on this app

AgentConnect is one Flutter codebase with two looks: **iOS follows Apple's Human Interface Guidelines (HIG);
Android keeps Material.** The same code also builds a **Mac app** with a desktop shell of its own (see
"macOS rules" below). Product behavior, screens and the API are described in `README.md` and `API_NOTES.md`.
This file is the set of rules to follow when you change UI.

## Before you finish

```
flutter pub get && flutter gen-l10n
flutter analyze        # must report no issues
flutter test           # must pass
```

- UI strings go in `lib/l10n/app_en.arb`. The generated `lib/l10n/app_localizations*.dart` are not committed.
- For a visual change, also build and look at it: `flutter build ios --simulator --debug`, then run it on an iOS
  simulator. Signing in needs a person (third-party login), so ask for that step instead of working around it.
- A change to shared code must still build for the Mac: `flutter build macos --debug`. For a visual change there,
  run `build/macos/Build/Products/Debug/AgentConnect.app` and look at a narrow (760 pt) and a wide window.
- Say plainly what you did not verify (for example: no Android build, haptics on a simulator).

## The platform rule

Every iOS-specific choice is behind `isIOS` from `lib/ui/platform.dart`.

- Use `isIOS`, not `Platform.isIOS` or `Theme.of(context).platform`: tests switch platform through it.
- An iOS change must leave Android exactly as it was. Keep the existing widget tree in the `else` branch; do not
  "tidy" it while you are there.
- When both platforms need the same new behavior, write it once with no branch.
- A new platform split gets a case in `test/platform_ui_test.dart` (iOS shows X, Android shows Y). Set
  `debugDefaultTargetPlatformOverride` and reset it to null before the test ends.

## iOS rules

### Use the shared pieces, not the raw widgets

| You need | Use | Do not use directly |
|---|---|---|
| An icon | `AppIcons.x` (`lib/ui/icons.dart`) | `Icons.x`, `CupertinoIcons.x` |
| Bottom tabs | `AppTabBar` (`lib/ui/tab_bar.dart`) | `NavigationBar`, `CupertinoTabBar` |
| Yes/no confirmation | `confirmDialog` (`lib/ui/adaptive.dart`) | `showDialog` + `AlertDialog` |
| A short list of actions | `showActionMenu` | a hand-built bottom sheet of `ListTile`s |
| Indeterminate progress | `Spinner` | `CircularProgressIndicator` |
| Pull to refresh | `RefreshIndicator.adaptive` | `RefreshIndicator` |
| A switch | `Switch.adaptive`, `SwitchListTile.adaptive` | `Switch`, `SwitchListTile` |
| 2–4 views in one place | `Segmented` (`lib/ui/widgets.dart`) | underlined top tabs |
| Haptic feedback | `Haptics` (`lib/ui/platform.dart`) | `HapticFeedback` |
| Pushing a screen | `push` and the `open…` helpers in `lib/features/nav.dart` | a custom route or transition |
| Content that needs room | `showAppSheet` (`lib/ui/adaptive.dart`) | `showModalBottomSheet` |

If a shared piece is missing what you need, extend it there so both platforms stay in one place.

### Icons

- Adding an icon: add one getter to `AppIcons`, named after the Material icon, returning the Material glyph on
  Android and the matching `CupertinoIcons` glyph on iOS. Check that the Cupertino name exists; the set is smaller
  than Material's and has no key, robot or slashed-cloud glyphs.
- Pick the iOS glyph by meaning, and look at it rendered. Example: sign out is `square_arrow_left` (arrow leaving
  the box); `square_arrow_right` reads as "sign in".
- Tab icons: outlined when unselected, the filled variant when selected (`AppIcons.homeSelected`, …).
- An icon-only button needs a `tooltip` (or `Semantics` label).

### Navigation

- Primary destinations are the bottom tab bar: 2–5 tabs, one-word labels. No drawer or hamburger menu, no
  floating action button, no top tab bar.
- A tab's root screen: `AppBar(centerTitle: false, toolbarHeight: rootAppBarHeight, title: rootTitle(text))`.
  That is a large left title on iOS and the normal title on Android.
- A pushed screen: plain `AppBar(title: Text(...))`. The theme centers it at 17 pt on iOS and supplies the back
  chevron. Do not set a custom `leading` back button.
- A two-line title: `Column(crossAxisAlignment: navTitleAlign, …)`, and give any `Row` inside it
  `mainAxisSize: MainAxisSize.min`.
- Never block the back swipe from the left edge (no `PopScope` that refuses to pop, no horizontal drag that starts
  at the edge). A sheet must close by swiping down as well as by its close button.
- Page-level actions go in the navigation bar (top right). The main action of a screen goes at the bottom, in
  thumb reach.

### Alerts, menus and sheets

- Confirm before anything that cannot be undone, with `confirmDialog(..., destructive: true)`. Button labels are
  verbs ("Sign out"), not "OK" / "Yes".
- A choice of actions on one item (long press, "+" button) is `showActionMenu`. iOS shows it without icons and
  with Cancel; pass the icon anyway for Android.
- Content that needs room (filters, pickers, the workspace) is `showAppSheet` with
  `showDragHandle: true` and `useSafeArea: true`: a bottom sheet on phones, a dialog on the Mac.
- Do not use a snackbar for anything the person must read or act on; it is only for a short confirmation such as
  "Copied".

### Layout and touch

- Every tappable thing is at least 44 × 44 pt, including icons in rows and chips.
- Side margins are 16 pt; spacing steps are 8 / 16 / 24.
- Keep content out of the status bar, Dynamic Island and home indicator areas: `SafeArea`, or `useSafeArea` on
  sheets. Anything pinned to the bottom must clear the home indicator.
- Check the narrowest phone (375 pt wide): long titles ellipsize, rows do not overflow.
- There is no ink ripple on iOS; a pressed row dims. Do not set `splashFactory`, `splashColor` or
  `highlightColor` locally.

### Color and text

- Colors come from `context.pal` (`lib/ui/theme.dart`). No hard-coded colors, except inside brand marks.
- Every screen must read in both light and dark; check both before you finish.
- Never show state by color alone: pair it with a word or an icon (the status pills do this).
- Text uses the theme's Geist family; mono metadata uses `mono(context, …)`. Nothing below 11 pt,
  except tab bar labels and badge counts (10 pt).
- Do not clamp or disable text scaling. A row must survive larger text by wrapping or ellipsizing.

### Haptics

- Only where iOS itself would: `Haptics.selection()` when a tab, segment or option changes;
  `Haptics.light()` on send; `Haptics.medium()` when a long-press menu opens or a decision is made.
- Not on every tap, not on scroll, not on navigation.

## macOS rules

The Mac app is the same screens in a desktop shell. Every Mac-only choice is behind `isMacOS`
(`lib/ui/platform.dart`); `isApple` is iOS or the Mac (SF-style glyphs, the system spinner). The platform rule
above holds here too: a Mac change leaves iOS and Android exactly as they were, and a new split gets a case in
`test/platform_ui_test.dart`.

- **Shell**: `DesktopShell` (`lib/features/desktop/`) replaces `HomeShell`: a sidebar instead of the tab bar,
  Agents as a list with the chosen agent beside it, and Sessions laid out as the web console's session page (the
  list alone; once a conversation is open, the conversation with a side panel of Sessions · Files · Git · Tasks,
  `session_panel.dart`). A thread or task opens in that panel (`openThread`, `openTaskThread` do it), a workspace
  file opens in the conversation's column (`openWorkspaceFile` in `nav.dart`). Do not push a conversation, an agent or a new
  chat yourself: call `openConversation`, `openAgent`, `openNewChat`, `openSettings` (`lib/features/nav.dart`),
  which put it beside the list on the Mac and push it on a phone. Anything else pushed with `push` stays in the
  column it was pushed from.
- **Width**: a screen is measured against its column, not the window (`MediaQuery.sizeOf` gives the column). A
  scrolling column takes `padding: readablePadding(context, …)` so its content keeps a readable width in a wide
  pane. Check the narrowest window (760 × 520) and a wide one.
- **Pointer**: no ripple; rows show hover (the theme does this for `InkWell`). Whatever a long press opens, a
  right-click opens too (`onSecondaryTap`, Mac only). `showActionMenu` is a menu at the pointer. No haptics.
  Controls can be smaller than 44 pt (the theme sizes buttons at 34 pt).
- **Keyboard**: a message box is wrapped in `sendOnReturn` (`lib/ui/desktop_keys.dart`): Return sends,
  Shift-Return is a new line, and Return while an input method is composing is left to it. Menu bar items and
  their shortcuts live in `lib/features/desktop/desktop_menus.dart`; add a shortcut there, as a menu item, not as
  a key handler in a screen.
- **Outside the window**: the menu bar item and notifications are drawn natively (`macos/Runner`) from what
  `lib/core/desktop/presence.dart` pushes. What is worth a notification is decided in
  `lib/core/desktop/attention.dart` (pure, unit tested in `test/attention_test.dart`): change it there. A
  notification or menu row names the agent and the conversation only, never message text or what an agent
  asked to run.
- **Native bridge**: `macos/Runner/NativeBridge.swift` answers the same method channel as the iOS bridge. A new
  call both platforms need is added to both; a Mac-only one must be a harmless no-op elsewhere (`Native._try`).
- Server hosts stay in `ios/Flutter/Environment.xcconfig`; the Mac build includes that file.

## Not done yet (ask before taking these on)

- Body text is a fixed 14–15 pt rather than Dynamic Type text styles (HIG body is 17 pt).
- The tab bar and navigation bar are opaque (no blur), and large titles do not collapse on scroll.
- The agent sort menu and the remaining bottom sheets are still Material in shape.
- The "Agents" tab uses a sparkles glyph on iOS for want of a better one.
- On the Mac: Home, Infra, Approvals, Schedules and the workspace are the phone layouts in a wider column; the
  filter chips and cards are phone-sized; window state restoration, drag and drop of files into the message box
  and a notification's Approve / Deny buttons do not exist yet.

## Reference

`.claude/skills/ios-hig-design` and `.claude/skills/mobile-ios-design` hold the HIG guidance these rules come
from. Their code samples are SwiftUI: use them for the principle and write Flutter. Do not add SwiftUI or UIKit
screens to this app.
