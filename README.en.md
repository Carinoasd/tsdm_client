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

## Latest update: 1.63.0 (2026-11-27)

- The settings can be searched; favorites, browsing history, offline threads, floor bookmarks and read later can be filtered on the device; a long press on the homepage search button opens quick open on phones.
- Shorter thread and floor menus: sharing and copying, and floor moderation, each on a sheet of their own; cross-device sync and notification categories are sub pages of the settings.
- In-app updates download from the mirror first, and Android takes the APK built for the device; smoother database and cache work; the homepage banner and the light theme cards look tidier.
- Android build number 182 installs over earlier releases and test builds.

[Download 1.63.0](https://github.com/Carinoasd/tsdm_client/releases/tag/v1.63.0) · [Full changelog](./CHANGELOG.md)

## What it is

A cross-platform client for the [天使动漫 forum](https://www.tsdm39.com/). When the forum moved to Discuz! X5 in 2026 the original client could no longer parse its pages; this project took over maintenance at the forum's request, adapted the app to the X5 page structure and keeps adding features. It is the client version recognised by the forum as official.

The forum has no public API: the app requests the same pages a browser does, parses them and adds what a phone or a desktop needs on top. Releases for Android, iOS (unsigned), Windows, macOS and Linux are built by GitHub Actions; the in-app update check reads `version.json` from this repository.

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

### Browsing and reading
- Homepage (forum statistics, guide, first-reply list, activities), forum groups and forums, threads and floors; threads you replied to or read are marked, with +N when replies arrive after your last visit
- Search inside a thread, jump to a floor, show one author only, continuous loading; the reading position is remembered, immersive reading can turn on by itself per forum
- Online storage links: Baidu, Lanzou, Quark, Aliyun and other links in a post list the provider, the extraction code and the archive password; tap a code to copy it
- Audio attachments and NetEase Cloud Music links play in the app and keep playing across pages; background playback and notification controls on Android, iOS and macOS
- Read aloud (TTS): floor by floor from the current one, with skip, pause and speed (Android, iOS, Windows, macOS)
- Simplified / Traditional Chinese display conversion; adjustable text size, line height, paragraph spacing and reading width; data saver mode
- Offline copies of threads you read (off by default), batch download from the favorites
- Export a thread as plain text, Markdown or PDF; share a floor as an image, share threads, forums and profiles as QR codes

### Posting and interaction
- BBCode editor, local drafts and the forum's draft box, quick reply and rating templates
- Reply, quote several floors, comment, rate, vote, purchase, report; typing `@` lists friends and the official @ list
- "My images" and custom emoji packs in the emoji panel
- Red packets, rewards, activities, debates and other special threads as native cards with their actions
- Attachments download in the app, with a download manager to retry, open and share

### Keeping track
- Favorites (threads and forums), collections, read later, floor bookmarks with notes, browsing history
- Follow a thread for new replies; new-thread and keyword alerts for forums
- Block users, keywords and forums

### Accounts and data
- Multiple accounts, automatic check-in and daily red packet, expired-login notice with one-tap re-login
- Cross-device sync: reading progress, phrases and block lists, optionally drafts, bookmarks, templates, read later, followed threads, "My images" and more
- Backup export and import (logins can be encrypted with a password), automatic WebDAV backup and restore
- App lock; login device management, password and security, privacy settings
- Medal center, titles and the title shop, achievements, credit transfer and exchange, friends and private messages

### Notifications
- Notices and private messages are synced in the app and in the background and posted as system notifications, for every signed-in account of the device if you want
- Each category (replies, mentions, ratings and comments, private messages, system notices…) can be turned off; quiet hours
- Android: background message service (a foreground service) and direct reply from the notification
- Windows: system notifications with sound; clicking one restores the window and opens the message center

### Forum services
- Community bank, background shop, pet center, tasks and items as pages of the app
- Game center, tribunal, CP system and jobs open in the in-app browser signed in as the current account

### Moderators and staff
- Thread and floor management: stick, highlight, digest, move, close, delete, hide, warn, remove ratings, ban and more, shown as the forum's permissions allow
- Moderator panel: moderation queue, reports, recycle bin, logs; batch rating (when the forum has that plugin)
- Staff: grant medals, titles and backgrounds, adjust credits and user groups

### Tablets and desktop
- Two panes on wide windows: the list on the left, the thread on the right, with several thread tabs and a draggable divider
- `Ctrl+K` quick open: type a thread id, a link, a forum name, a thread title or a user name
- Keyboard shortcuts (also on an iPad with a hardware keyboard), `Ctrl+Enter` to send, system tray, close to tray, boss key

### Platforms
- Android (arm64 / armv7 / universal), iOS (unsigned, sideloaded), Windows, macOS, Linux
- Android and Windows download and install updates in the app; the file is verified before it is installed
- Android: launcher shortcuts, pin a forum or a thread to the home screen, alternative app icons; iOS: home screen widgets and quick actions

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

Releasing: create a release branch from the merged master, update `pubspec.yaml` (`x.y.z+N`), add the CHANGELOG section and update all three README announcements → `dart scripts/write_version_json.dart` → tests → commit and push the release branch and `vX.Y.Z` tag. CI builds every platform from `.github/workflows/release_build.yml` and publishes the Release with that CHANGELOG section as its notes. After every platform succeeds and all seven downloads are available, merge the release commit into master to activate the in-app update notice and homepage announcements. Android version codes: split APKs are N×10 + ABI code (armv7 2, arm64 3), the universal APK is N×10 + 9.

## License

MIT. Original work Copyright (c) 2023 realth000; modifications (C) 2026 Carinoasd. See [LICENSE](./LICENSE).

## Support development

This project is free and open source. Voluntary donations support the development and maintenance of the client and are received personally by the maintainer, Carinoasd. This is not an official forum fundraiser. All features remain available whether or not you donate.

Scan the QR code below with Alipay to donate. Click the image to view the original.

<a href="./doc/pic/alipay-donation.jpg"><img src="./doc/pic/alipay-donation.jpg" width="300" alt="Alipay QR code for voluntary donations to maintainer Carinoasd"></a>
