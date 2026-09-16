<h1 align="center">
    <img src="./assets/images/tsdm_client.svg" width="120px" alt="tsdm_client_logo">
    <br>
    tsdm_client
</h1>

<p align="center">Official client of the 天使动漫 (Angel Anime) forum · Discuz! X5 edition</p>

<p align="center"><a href="./README.md">简体中文</a> | <a href="./README.zh-hant.md">繁體中文</a> | English</p>

<p align="center">
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/release/Carinoasd/tsdm_client?label=release" alt="release"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/downloads/Carinoasd/tsdm_client/total" alt="download_total"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/actions"><img src="https://img.shields.io/github/actions/workflow/status/Carinoasd/tsdm_client/test.yml?label=test" alt="test_ci"/></a>
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.41-blue?logo=flutter" alt="flutter"/></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Carinoasd/tsdm_client" alt="license"/></a>
</p>

## What it is

A cross-platform client for the [天使动漫 forum](https://www.tsdm39.com/). When the forum moved to Discuz! X5 in 2026 the original client could no longer parse its pages; this project took over maintenance at the forum's request, adapted the app to the X5 page structure and keeps adding features. It is the client version recognised by the forum as official.

The forum has no public API: the app requests the same pages a browser does, parses them and adds what a phone or a desktop needs on top. Releases for Android, iOS (unsigned), Windows, macOS and Linux are built by GitHub Actions; the in-app update check reads `version.json` from this repository.

The project continues [realth000/tsdm_client](https://github.com/realth000/tsdm_client) (MIT) with its full history and copyright notices; the X5 adaptation and everything since is maintained by Carinoasd.

## Download

Get the latest build from [Releases](https://github.com/Carinoasd/tsdm_client/releases/latest):

| Platform | File |
|---|---|
| Android (most phones) | `tsdm_client-arm64_v8a.apk` |
| Android (older 32-bit devices) | `tsdm_client-armeabi_v7a.apk` |
| Android (not sure which one; larger) | `tsdm_client-universal.apk` |
| iOS (unsigned, sideload yourself) | `tsdm_client.ipa` |
| Windows 10/11 (64-bit, unzip and run) | `tsdm_client-windows.zip` |
| macOS | `tsdm_client-universal.dmg` |
| Linux | `tsdm_client-linux.tar.gz` |

The three Android packages upgrade over each other: the universal APK carries a version code above the split APKs of the same version, and every package of the next version is above all of them. The only downgrade Android refuses is switching from the universal APK back to a split APK of the same version; uninstall first in that case.

The Linux build needs `libayatana-appindicator3-1` installed (Debian/Ubuntu package name; the matching ayatana-appindicator package elsewhere). It is a runtime dependency of the tray component, and the app does not start without it.

The app is not on any store. Install the APK directly on Android; "Check for updates" inside the app reads `version.json` from this repository and the in-app changelog follows the Releases page.

The package name is `com.tsdm.tsdm_client`, signed with the forum's official key, so it installs next to the original author's builds (`kzs.th000.tsdm_client`). To move over: in the old app, Settings → Export data, tick the account data and set a password → install this app → Import data with the same password → remove the old app.

## Features

### Browsing and interaction
- Home: forum statistics, the four digest modules (hot, digest, latest replies, latest posts) and the "grab the sofa" entry, each opening its full list
- Forum groups: the boards of every group with their moderators; "My favourite boards" follows the favourites set on the website
- Boards and threads: thread lists, floors, comments, ratings, purchases, attachments, spoilers, @ mentions, and a "replied" mark on threads you answered
- Favourite or unfavourite a board from its page; the favourites page has "Threads" and "Boards" tabs
- Share a thread with a friend: pick someone from your friend list and send the title and link as a private message
- Notices, private messages, chat and public messages; plain-text URLs in notices are tappable; friend requests show up as notices
- Ordinary polls can be voted on inside the app, single or multiple choice; the result shown is what the forum reports after a fresh read, and a vote is never resent automatically
- "Activities" on the home page lists the links of the forum's activity section; forum links open inside the app

### Posting and replying
- BBCode editor, quick reply templates, drafts
- Typing `@` opens a mention menu with your friends and the official @ list, filtered as you type
- "My images": keep image URLs or image-host codes on the device and insert them from the emoji panel; long-press an image in a post to save it there
- Ctrl+Enter / Alt+Enter sends on desktop

### Accounts
- Multiple accounts; automatic check-in (per account, with retry when rate-limited); the account page shows whether each account has checked in today
- Sync the notices and private messages of every account with one tap, with a per-account progress page
- Expired sessions are flagged and can be logged in again with one tap; the app tells you at start-up how many accounts expired
- Delete several accounts at once, or remove the current account from this device without a network connection
- Backup export/import, optionally encrypting the login data with a password so other devices need no re-login
- Friend list and friend requests; red packets, including the daily one
- "My achievements" and "Medal centre" on your profile page: read achievements, browse medal categories and pages with their conditions; buying, applying and claiming rewards stay on the website

### Notifications and settings
- Foreground/background polling for new messages with system notifications; a cold start from a notification goes straight to the message centre
- The settings page shows and requests the notification permission and battery-optimisation exemption (Android); the Debug section can send a test notification and export the logs
- Windows: a system notification with a sound when the automatic sync finds new notices or private messages; tapping it restores the window and opens the message centre
- The fetch window of the automatic sync follows the forum's clock, so a wrong device clock does not skip notices or messages
- Unread notices are tracked per device: a notice another device of the same account already fetched is still unread the first time it shows up here, until you view it here or mark all as read
- Android: an optional background message service keeps a foreground service running and checks for new messages at the auto sync interval while the app is in the background or was cleared; it shares the database with the in-app sync, so nothing is announced twice
- Light and dark themes, font scaling, log page in the app theme

### Platforms
- Android (arm64 / armv7 / universal), iOS (unsigned sideload), Windows, macOS, Linux; "Check for updates" reads `version.json` from this repository
- Windows: tray icon with a context menu (current account, history, favourites, manage accounts, exit); picking a page while the window is minimised restores and focuses it first

## Known issues

- On some Android devices the rotation transition briefly shows black; the layout is correct once the rotation finishes. The transition itself is not being worked on (#28).
- Board lists cannot fetch externally hosted avatars: until the app has seen that user's avatar elsewhere, the list shows the initial in a circle.
- The forum's achievement system has no content yet, so "My achievements" only shows the empty state.
- The iOS build is unsigned, has to be sideloaded and is not tested on a device.

## Reporting problems

Open an issue at [Issues](https://github.com/Carinoasd/tsdm_client/issues) with the app version, the platform and the steps. If it reproduces, attach the log from Settings → Debug → Export logs; login credentials are masked before anything is written to the log. Report security problems privately through Security → Report a vulnerability, or by private message to the forum administrator.

## Building

```bash
flutter pub get
dart run build_runner build -d   # generates the mappers and i18n
dart run gitsumu                 # generates the version / changelog info
flutter build apk --release      # needs android/key.properties pointing at your keystore
```

Linux builds need `libgtk-3-dev`, `libsqlite3-dev` and `libayatana-appindicator3-dev`; tests: `flutter test`.

Releasing: bump the version in `pubspec.yaml` (`x.y.z+N`) and add the CHANGELOG section → `dart scripts/write_version_json.dart` → tests → commit and push master → `git tag -a vX.Y.Z && git push origin vX.Y.Z`. CI builds every platform from `.github/workflows/release_build.yml` and publishes the Release with that CHANGELOG section as its notes. Android version codes: split APKs are N×10 + ABI code (armv7 2, arm64 3), the universal APK is N×10 + 9.

## License

MIT. Original work Copyright (c) 2023 realth000; modifications (C) 2026 Carinoasd. See [LICENSE](./LICENSE).

## Support development

This project is free and open source. Voluntary donations support the development and maintenance of the client and are received personally by the maintainer, Carinoasd. This is not an official forum fundraiser. All features remain available whether or not you donate.

Scan the QR code below with Alipay to donate. Click the image to view the original.

<a href="./doc/pic/alipay-donation.jpg"><img src="./doc/pic/alipay-donation.jpg" width="300" alt="Alipay QR code for voluntary donations to maintainer Carinoasd"></a>
