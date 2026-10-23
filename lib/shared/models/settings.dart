part of 'models.dart';

/// Keys for all settings.
// ignore_for_file: public_member_api_docs
enum SettingsKeys<T> implements Comparable<SettingsKeys<T>> {
  /// Net client config: Accept.
  netClientAccept<String>(
    name: 'netClientAccept',
    type: String,
    defaultValue:
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  ),

  /// Net client config: Accept-Encoding.
  ///
  /// FormatException happens in some page, current found in 301 request in
  /// redirect
  /// url in notice page.
  /// After debugging like this:
  /// https://github.com/flutter/flutter/issues/32558#issuecomment-886022246
  /// Remove "gzip" encoding in "Accept-Encoding" can fix this.
  ///
  /// See dio interceptor `_GzipEncodingChecker` for more details.
  netClientAcceptEncoding<String>(name: 'netClientAcceptEncoding', type: String, defaultValue: 'gzip, deflate, br'),

  /// Net client config: Accept-Language.
  netClientAcceptLanguage<String>(
    name: 'dioAcceptLanguage',
    type: String,
    defaultValue: 'zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6,zh-TW;q=0.5',
  ),

  /// Net client config: User-Agent.
  netClientUserAgent<String>(
    name: 'dioUserAgent',
    type: String,
    defaultValue: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0',
  ),

  /// Remember window size after window size changed on desktop platforms.
  ///
  /// Disable this config will never update [windowSize].
  windowRememberSize<bool>(name: 'windowRememberSize', type: bool, defaultValue: true),

  /// Restore maximization when remembering the desktop window size.
  windowMaximized<bool>(name: 'windowMaximized', type: bool, defaultValue: false),

  /// Window size config on desktop platforms.
  windowSize<Size>(name: 'windowSize', type: Size, defaultValue: Size(800, 600)),

  /// Remember window position after window position changed on desktop
  /// platforms.
  ///
  /// Disable this config will never update [windowPosition].
  windowRememberPosition<bool>(name: 'windowRememberPosition', type: bool, defaultValue: true),

  /// Window position config on desktop platforms.
  windowPosition<Offset>(name: 'windowPosition', type: Offset, defaultValue: Offset.zero),

  /// Window whether in the center of screen config on desktop platforms.
  ///
  /// Enable this config will disable [windowPosition] and
  /// [windowRememberPosition].
  windowInCenter<bool>(name: 'windowInCenter', type: bool, defaultValue: false),

  /// Login user username.
  loginUsername<String>(name: 'loginUsername', type: String, defaultValue: ''),

  /// Login user uid.
  loginUid<int>(name: 'loginUid', type: int, defaultValue: 0),

  /// Login user email address.
  loginEmail<String>(name: 'loginEmail', type: String, defaultValue: ''),

  /// Default app theme mode.
  ///
  /// 0: [ThemeMode.system]
  /// 1: [ThemeMode.light]
  /// 2: [ThemeMode.dark]
  themeMode<int>(name: 'ThemeMode', type: int, defaultValue: 0),

  /// Locale
  ///
  /// Empty means follow system locale.
  locale<String>(name: 'locale', type: String, defaultValue: ''),

  /// Default feeling when check in
  checkinFeeling<String>(name: 'checkInFeeling', type: String, defaultValue: 'kx'),

  /// Default check in message when check in
  checkinMessage<String>(name: 'checkInMessage', type: String, defaultValue: '每日签到'),

  /// Show shortcut widget that to redirect to latest thread or subreddit in
  /// forum card.
  showShortcutInForumCard<bool>(name: 'showShortcutInForumCard', type: bool, defaultValue: false),

  /// Default accent color.
  ///
  /// Less than zero represents default color.
  accentColor<int>(
    name: 'accentColor',
    type: int,
    defaultValue: 4280391411, // PrimaryColors.blue
  ),

  /// Using system color (usually wallpaper color) as app accent color.
  accentColorFollowSystem<bool>(name: 'accentColorFollowSystem', type: bool, defaultValue: false),

  /// Show badge or unread notice count on notice button.
  showUnreadInfoHint<bool>(name: 'showUnreadInfoHint', type: bool, defaultValue: true),

  /// View latest posts in thread first, in other words, posts are sorted in
  /// desc order.
  threadReverseOrder<bool>(name: 'threadReverseOrder', type: bool, defaultValue: false),

  /// Center align the info row in thread card.
  threadCardInfoRowAlignCenter<bool>(name: 'threadCardInfoRowAlignCenter', type: bool, defaultValue: false),

  /// Show last replied author's username in info row in `ThreadCard`.
  threadCardShowLastReplyAuthor<bool>(name: 'threadCardShowLastReplyAuthor', type: bool, defaultValue: true),

  /// Highlight recent thread (published in recent 24 hours).
  threadCardHighlightRecentThread<bool>(name: 'threadCardHighlightRecentThread', type: bool, defaultValue: true),

  /// Highlight author's username in thread card.
  threadCardHighlightAuthorName<bool>(name: 'threadCardHighlightAuthorName', type: bool, defaultValue: true),
  threadCardHighlightInfoRow<bool>(name: 'threadCardHighlightInfoRow', type: bool, defaultValue: true),

  /// Show the excerpt of the first floor under the title of a thread in the lists (the forum's app API, plugin 3.1.0).
  threadCardShowExcerpt<bool>(name: 'threadCardShowExcerpt', type: bool, defaultValue: true),

  /// When the thread lists show a thumbnail of the first floor's images (the forum's app API, plugin 3.1.0): the
  /// index of a [ThreadThumbnailMode], 0 always, 1 on Wi-Fi only (the default), 2 never.
  threadCardThumbnailMode<int>(name: 'threadCardThumbnailMode', type: int, defaultValue: 1),

  /// Let the thumbnails of the thread lists load the images of other sites (`[img]` of the first floor), not only the
  /// forum's attachments. Off by default: the site of such an image learns of everyone who scrolls past the thread,
  /// while the web page only loads it once the thread is opened.
  threadCardExternalThumbnails<bool>(name: 'threadCardExternalThumbnails', type: bool, defaultValue: false),

  /// Use network proxy config below or not.
  netClientUseProxy<bool>(name: 'netClientUseProxy', type: bool, defaultValue: false),

  /// Network proxy.
  ///
  /// Manually set, in format: $domain:$port where $domain is usually localhost.
  netClientProxy<String>(name: 'netClientProxy', type: String, defaultValue: ''),

  /// Enable auto checkin for all users when app startup.
  autoCheckin<bool>(name: 'autoCheckin', type: bool, defaultValue: true),

  /// Claim the current account's daily red packet when loading the homepage, independently of auto check-in.
  autoDailyRedPacket<bool>(name: 'autoDailyRedPacket', type: bool, defaultValue: false),

  /// Show unread badge on notice card.
  ///
  /// Disabled by default because the read/unread flag is offline.
  showUnreadNoticeBadge<bool>(name: 'showUnreadNoticeBadge', type: bool, defaultValue: true),

  /// Show unread badge on personal message card.
  ///
  /// Enabled by default because the read/unread flag is provided by server.
  showUnreadPersonalMessageBadge<bool>(name: 'showUnreadPersonalMessageBadge', type: bool, defaultValue: true),

  /// Show unread badge on broadcast message card.
  ///
  /// Disabled by default because the read/unread flag is offline.
  showUnreadBroadcastMessageBadge<bool>(name: 'showUnreadBroadcastMessageBadge', type: bool, defaultValue: true),

  /// Duration of automatically fetch notice from server, in seconds.
  ///
  /// Default is 600 seconds.
  autoSyncNoticeSeconds<int>(name: 'autoSyncNoticeSeconds', type: int, defaultValue: 600),

  /// Keep an Android foreground service running that checks for new notifications at the auto sync interval while
  /// the app is in the background or was cleared (#80).
  enableBackgroundMessageService<bool>(name: 'enableBackgroundMessageService', type: bool, defaultValue: false),

  /// Let the auto sync poll every account saved on this device, not only the current one: the in-app auto sync on
  /// Android and Windows (also in the tray) and the Android background message service. Each account with its own
  /// cookie and poll, its notifications naming the account. Off: the current account only, as before.
  backgroundSyncAllAccounts<bool>(name: 'backgroundSyncAllAccounts', type: bool, defaultValue: false),

  /// Enable operations for debugging.
  enableDebugOperations<bool>(name: 'enableDebugOperations', type: bool, defaultValue: false),

  /// APP font family.
  fontFamily<String>(name: 'fontFamily', type: String, defaultValue: ''),

  /// Enable experimental BBCode parser for editor.
  ///
  /// The editor will try to parse raw bbcode text into quill delta and provide WYSIWYG experience, it is not considered
  /// to be stable but... give it a chance.
  enableEditorBBCodeParser<bool>(name: 'enableEditorBBCodeParser', type: bool, defaultValue: true),

  /// Enable the update check when app startup.
  enableUpdateCheckOnStartup<bool>(name: 'enableUpdateCheckOnStartup', type: bool, defaultValue: true),

  /// Recent used custom colors in editor.
  ///
  /// The length of the list is determined to .
  editorRecentUsedCustomColors<List<int>>(name: 'editorRecentUsedCustomColors', type: List<int>, defaultValue: []),

  /// Detect system proxy settings when app startup and use the detected value.
  useDetectedProxyWhenStartup<bool>(name: 'useDetectedProxyWhenStartup', type: bool, defaultValue: false),

  /// Auto clear outdated image cache.
  ///
  /// Default is disabled, to match the old behavior: the clearing runs before the homepage shows and is slow on a
  /// large cache.
  enableAutoClearImageCache<bool>(name: 'enableAutoClearImageCache', type: bool, defaultValue: false),

  /// Duration of an image cache considered as outdated for auto clear, in seconds.
  ///
  /// Images that have a long duration till last used time will be considered as outdated.
  ///
  /// Default is 7 days = 60 * 60 * 24 * 7.
  autoClearImageCacheDuration<int>(name: 'autoClearImageCacheDuration', type: int, defaultValue: 60 * 60 * 24 * 7),

  /// Hide the app bar and the breadcrumbs of the thread page while scrolling down the floors, show them again when
  /// scrolling up: more room for the floors.
  collapseAppBarWhenScroll<bool>(name: 'collapseAppBarWhenScroll', type: bool, defaultValue: true),

  /// Interaction mode on thread floors.
  threadFloorInteractionMode<ThreadFloorInteractionMode>(
    name: 'threadFloorInteractionMode',
    type: ThreadFloorInteractionMode,
    defaultValue: ThreadFloorInteractionMode.adaptiveTapMenu,
  ),

  /// Global text scale factor.
  textScaleFactor<double>(
    name: 'textScaleFactor',
    type: double,
    defaultValue: 1,
  ),

  /// Extra text scale applied on top of [textScaleFactor] to the floors in thread page only.
  ///
  /// Users reading long posts on a large screen asked for post content larger than the global scale allows
  /// (GitHub #137). Ranges from 1.0 (no extra scale) to 2.0 in steps of 0.1.
  threadContentScale<double>(
    name: 'threadContentScale',
    type: double,
    defaultValue: 1,
  ),

  /// Line height of the post content in thread page, a multiple of the font size (1.4 to 2.0).
  ///
  /// Posts written with few line breaks read as a wall of text on a phone at the line height of the body text (1.43).
  threadContentLineHeight<double>(
    name: 'threadContentLineHeight',
    type: double,
    defaultValue: PostTypography.defaultLineHeight,
  ),

  /// Space between the paragraphs of the post content in thread page, in logical pixels (0 to 16).
  threadContentParagraphSpacing<double>(
    name: 'threadContentParagraphSpacing',
    type: double,
    defaultValue: PostTypography.defaultParagraphSpacing,
  ),

  /// Cut long paragraphs of the post content after the end of a sentence (layout only, the text is not changed).
  threadContentSplitLongParagraphs<bool>(
    name: 'threadContentSplitLongParagraphs',
    type: bool,
    defaultValue: false,
  ),

  /// Ask Android for the highest refresh rate the screen offers at the current resolution.
  ///
  /// Some vendor systems keep apps that do not ask at 60Hz on 90/120Hz screens (GitHub #182). Android only.
  highRefreshRate<bool>(name: 'highRefreshRate', type: bool, defaultValue: true),

  /// Save the thread pages the user loads to read them again without network.
  ///
  /// Off by default: nothing is stored and the thread page behaves as before. Turning it off deletes what was saved.
  offlineThreads<bool>(name: 'offlineThreads', type: bool, defaultValue: false),

  /// How many threads [offlineThreads] keeps, the least recently used ones going first; one thread of one account
  /// counts once whatever number of its pages are saved.
  offlineThreadsLimit<int>(name: 'offlineThreadsLimit', type: int, defaultValue: 50),

  /// Render a floor from its bbcode with the app's own renderer instead of the html the forum printed (experimental).
  ///
  /// Only floors whose bbcode the forum's app API gives (plugin 2.7.0, the account sees the whole content) and whose
  /// tags the app renders faithfully; every other floor keeps the forum's html. Off by default.
  enableAppPostRenderer<bool>(name: 'enableAppPostRenderer', type: bool, defaultValue: false),

  /// Title of the pinned thread group (the tabs of the forum homepage block: 最新活动, 见习天使, ..., 发帖排行) last
  /// selected in the one card of the phone homepage.
  ///
  /// Kept by title, the groups have no other stable key; empty or a title the homepage no longer has selects the first
  /// group. One value for every account.
  homepagePinnedGroup<String>(name: 'homepagePinnedGroup', type: String, defaultValue: ''),

  /// The card explaining the notification permission was shown once (after a login or on the first visit of the
  /// notice page): those never ask again, only turning the auto sync or the background service on in the settings
  /// does.
  notificationPermissionPrompted<bool>(name: 'notificationPermissionPrompted', type: bool, defaultValue: false),
  ;

  const SettingsKeys({required this.name, required this.type, required this.defaultValue});

  final String name;
  final Type type;
  final T defaultValue;

  /// Ignore dynamic generic type here because the function is used to compare
  /// all types of [SettingsKeys].
  @override
  // Intend to have dynamic types.
  // ignore: avoid_dynamic
  int compareTo(SettingsKeys<dynamic> other) => name.compareTo(other.name);
}
