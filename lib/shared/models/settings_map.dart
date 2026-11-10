// All public fields in the map is defined in settings keys.
// ignore_for_file: public_member_api_docs

part of 'models.dart';

/// All settings and their keys.
@MappableClass()
class SettingsMap with SettingsMapMappable {
  /// Constructor.
  const SettingsMap({
    required this.netClientAccept,
    required this.netClientAcceptEncoding,
    required this.netClientAcceptLanguage,
    required this.netClientUserAgent,
    required this.windowRememberSize,
    required this.windowSize,
    required this.windowRememberPosition,
    required this.windowPosition,
    required this.windowInCenter,
    required this.loginUsername,
    required this.loginUid,
    required this.loginEmail,
    required this.themeMode,
    required this.locale,
    required this.checkinFeeling,
    required this.checkinMessage,
    required this.showShortcutInForumCard,
    required this.accentColor,
    required this.accentColorFollowSystem,
    required this.showUnreadInfoHint,
    required this.threadReverseOrder,
    required this.threadCardInfoRowAlignCenter,
    required this.threadCardShowLastReplyAuthor,
    required this.threadCardHighlightRecentThread,
    required this.threadCardHighlightAuthorName,
    required this.threadCardHighlightInfoRow,
    required this.netClientProxy,
    required this.netClientUseProxy,
    required this.autoCheckin,
    required this.showUnreadNoticeBadge,
    required this.showUnreadPersonalMessageBadge,
    required this.showUnreadBroadcastMessageBadge,
    required this.autoSyncNoticeSeconds,
    required this.enableDebugOperations,
    required this.fontFamily,
    required this.enableEditorBBCodeParser,
    required this.enableUpdateCheckOnStartup,
    required this.editorRecentUsedCustomColors,
    required this.useDetectedProxyWhenStartup,
    required this.enableAutoClearImageCache,
    required this.autoClearImageCacheDuration,
    required this.collapseAppBarWhenScroll,
    required this.threadFloorInteractionMode,
    required this.textScaleFactor,
    required this.threadContentScale,
    this.threadContentLineHeight = PostTypography.defaultLineHeight,
    this.threadContentParagraphSpacing = PostTypography.defaultParagraphSpacing,
    this.threadContentSplitLongParagraphs = false,
    this.threadLinkCard = true,
    this.threadContentMaxWidth = 0,
    this.threadCardShowExcerpt = true,
    this.threadCardThumbnailMode = 1,
    this.chineseDisplayMode = 0,
    this.threadCardExternalThumbnails = false,
    this.homeLayout = '',
    this.windowMaximized = false,
    this.enableBackgroundMessageService = false,
    this.notificationPermissionPrompted = false,
    this.backgroundSyncAllAccounts = false,
    this.notificationHideContent = false,
    this.notificationDirectReply = true,
    this.readingTimeStats = true,
    this.notifyReply = true,
    this.notifyMention = true,
    this.notifyRate = true,
    this.notifyPersonalMessage = true,
    this.notifySystem = true,
    this.notifyFollowedThread = true,
    this.followedThreadCheckMinutes = 30,
    this.notifyForumNewThread = true,
    this.notifyKeywordAlert = true,
    this.forumWatchCheckMinutes = 30,
    this.notifyQuietHours = false,
    this.notifyQuietStart = 1380,
    this.notifyQuietEnd = 480,
    this.autoDailyRedPacket = false,
    this.highRefreshRate = true,
    this.appIcon = 'default',
    this.offlineThreads = false,
    this.offlineThreadsLimit = 50,
    this.enableAppPostRenderer = false,
    this.postImageAutoLoad = 0,
    this.dataSaverMode = 0,
    this.editorQuickPhrases = '',
    this.editImageBeforeUpload = false,
    this.uploadImageMaxSide = 0,
    this.uploadImageQuality = 90,
    this.frequentForums = '',
    this.attachmentDownloadDirectory = '',
    this.homepagePinnedGroup = '',
    this.threadOpenPosition = 1,
    this.threadSwipePaging = false,
    this.immersiveForums = '',
    this.immersiveAllForums = false,
    this.twoPaneLayout = true,
    this.twoPaneListWidth = 0,
    this.postMediaPreview = true,
    this.inAppBrowserForForum = true,
    this.inAppBrowserForAll = false,
    this.themeModeScheduled = false,
    this.darkScheduleStart = 1320,
    this.darkScheduleEnd = 420,
    this.crossDeviceSync = true,
    this.crossDeviceSyncRateTemplates = true,
    this.crossDeviceSyncSettings = true,
    this.crossDeviceSyncDrafts = true,
    this.crossDeviceSyncBookmarks = true,
    this.crossDeviceSyncPinnedForums = true,
    this.crossDeviceSyncForumWatch = true,
  });

  final String netClientAccept;
  final String netClientAcceptEncoding;
  final String netClientAcceptLanguage;
  final String netClientUserAgent;
  final bool windowRememberSize;
  final Size windowSize;
  final bool windowMaximized;
  final bool windowRememberPosition;
  final Offset windowPosition;
  final bool windowInCenter;
  final String loginUsername;
  final int loginUid;
  final String loginEmail;
  final int themeMode;
  final String locale;
  final String checkinFeeling;
  final String checkinMessage;
  final bool showShortcutInForumCard;
  final int accentColor;
  final bool accentColorFollowSystem;
  final bool showUnreadInfoHint;
  final bool threadReverseOrder;
  final bool threadCardInfoRowAlignCenter;
  final bool threadCardShowLastReplyAuthor;
  final bool threadCardHighlightRecentThread;
  final bool threadCardHighlightAuthorName;
  final bool threadCardHighlightInfoRow;

  /// Whether the thread lists show the excerpt of the first floor. Not required: backups from older versions lack it.
  final bool threadCardShowExcerpt;

  /// When the thread lists show a thumbnail, the index of a [ThreadThumbnailMode]. Not required: backups from older
  /// versions lack it.
  final int threadCardThumbnailMode;

  /// Whether the thumbnails of the thread lists load the images of other sites too. Not required: backups from older
  /// versions lack it.
  final bool threadCardExternalThumbnails;

  /// Index of a `ChineseDisplayMode`: the script the forum text is shown in. Not required: backups from older versions
  /// lack it.
  final int chineseDisplayMode;

  /// Order and visibility of the homepage blocks, see `HomeBlockLayout`. Not required: backups from older versions
  /// lack it.
  final String homeLayout;

  /// When the thread lists show a thumbnail.
  ThreadThumbnailMode get threadThumbnailMode => ThreadThumbnailMode.fromIndex(threadCardThumbnailMode);
  final String netClientProxy;
  final bool netClientUseProxy;
  final bool autoCheckin;
  final bool autoDailyRedPacket;
  final bool showUnreadNoticeBadge;
  final bool showUnreadPersonalMessageBadge;
  final bool showUnreadBroadcastMessageBadge;
  final int autoSyncNoticeSeconds;

  /// Whether the Android background message service is on. Not required: backups from older versions lack it.
  final bool enableBackgroundMessageService;

  /// Whether the auto sync polls every saved account. Not required: backups from older versions lack it.
  final bool backgroundSyncAllAccounts;

  /// Whether the system notifications only show the counts, no content. Not required: backups from older versions
  /// lack it.
  final bool notificationHideContent;

  /// See `SettingsKeys.notificationDirectReply`. Not required: backups from older versions lack it.
  final bool notificationDirectReply;

  /// See `SettingsKeys.readingTimeStats`. Not required: backups from older versions lack it.
  final bool readingTimeStats;

  /// See `SettingsKeys.notifyReply`. Not required: backups from older versions lack it.
  final bool notifyReply;

  /// See `SettingsKeys.notifyMention`. Not required: backups from older versions lack it.
  final bool notifyMention;

  /// See `SettingsKeys.notifyRate`. Not required: backups from older versions lack it.
  final bool notifyRate;

  /// See `SettingsKeys.notifyPersonalMessage`. Not required: backups from older versions lack it.
  final bool notifyPersonalMessage;

  /// See `SettingsKeys.notifySystem`. Not required: backups from older versions lack it.
  final bool notifySystem;

  /// See `SettingsKeys.notifyFollowedThread`. Not required: backups from older versions lack it.
  final bool notifyFollowedThread;

  /// See `SettingsKeys.followedThreadCheckMinutes`. Not required: backups from older versions lack it.
  final int followedThreadCheckMinutes;

  /// See `SettingsKeys.notifyForumNewThread`. Not required: backups from older versions lack it.
  final bool notifyForumNewThread;

  /// See `SettingsKeys.notifyKeywordAlert`. Not required: backups from older versions lack it.
  final bool notifyKeywordAlert;

  /// See `SettingsKeys.forumWatchCheckMinutes`. Not required: backups from older versions lack it.
  final int forumWatchCheckMinutes;

  /// See `SettingsKeys.notifyQuietHours`. Not required: backups from older versions lack it.
  final bool notifyQuietHours;

  /// See `SettingsKeys.notifyQuietStart`. Not required: backups from older versions lack it.
  final int notifyQuietStart;

  /// See `SettingsKeys.notifyQuietEnd`. Not required: backups from older versions lack it.
  final int notifyQuietEnd;
  final bool enableDebugOperations;
  final String fontFamily;
  final bool enableEditorBBCodeParser;
  final bool enableUpdateCheckOnStartup;
  final List<int> editorRecentUsedCustomColors;
  final bool useDetectedProxyWhenStartup;
  final bool enableAutoClearImageCache;
  final int autoClearImageCacheDuration;
  final bool collapseAppBarWhenScroll;
  final bool notificationPermissionPrompted;
  final ThreadFloorInteractionMode threadFloorInteractionMode;

  /// Index of a [ThreadOpenPosition]. Not required: backups from older versions lack it.
  final int threadOpenPosition;

  /// Swipe the floors sideways to change pages. Not required: backups from older versions lack it.
  final bool threadSwipePaging;

  /// Forums whose threads open in immersive reading, see `ImmersiveForums`. Not required: backups from older versions
  /// lack it.
  final String immersiveForums;

  /// Every thread opens in immersive reading. Not required: backups from older versions lack it.
  final bool immersiveAllForums;

  /// Wide windows show a list page and the thread opened from it side by side. Not required: backups from older
  /// versions lack it.
  final bool twoPaneLayout;

  /// Width of the list pane dragged to, 0 while never dragged. Not required: backups from older versions lack it.
  final double twoPaneListWidth;

  /// Cards of videos in posts show cover, title and length. Not required: backups from older versions lack it.
  final bool postMediaPreview;

  /// Forum pages the app has no screen for open in the in-app browser. Not required: backups from older versions lack
  /// it.
  final bool inAppBrowserForForum;

  /// Every web link opens in the in-app browser. Not required: backups from older versions lack it.
  final bool inAppBrowserForAll;

  /// Sync the reading progress, the quick phrases and the block list across devices (the rate templates, the reading
  /// settings and the drafts each on their own switch too). Not required: backups from older
  /// versions lack it.
  final bool crossDeviceSync;

  /// With [crossDeviceSync], sync the fast rate templates. Not required: backups from older versions lack it.
  final bool crossDeviceSyncRateTemplates;

  /// With [crossDeviceSync], sync the reading and display settings. Not required: backups from older versions lack it.
  final bool crossDeviceSyncSettings;

  /// With [crossDeviceSync], sync the local drafts. Not required: backups from older versions lack it.
  final bool crossDeviceSyncDrafts;

  /// With [crossDeviceSync], sync the floor bookmarks. Not required: backups from older versions lack it.
  final bool crossDeviceSyncBookmarks;

  /// With [crossDeviceSync], sync the pinned forums. Not required: backups from older versions lack it.
  final bool crossDeviceSyncPinnedForums;

  /// With [crossDeviceSync], sync the forums and keywords watched for new threads. Not required: backups from older
  /// versions lack it.
  final bool crossDeviceSyncForumWatch;

  /// The clock decides the theme. Not required: backups from older versions lack it.
  final bool themeModeScheduled;

  /// Start of the dark hours, minutes after midnight. Not required: backups from older versions lack it.
  final int darkScheduleStart;

  /// End of the dark hours, minutes after midnight. Not required: backups from older versions lack it.
  final int darkScheduleEnd;

  /// Where a thread read before opens from a list.
  ThreadOpenPosition get openPosition => ThreadOpenPosition.fromIndex(threadOpenPosition);
  final double textScaleFactor;
  final double threadContentScale;

  /// Line height of the post content. Not required: backups from older versions lack it.
  final double threadContentLineHeight;

  /// Space between the paragraphs of the post content. Not required: backups from older versions lack it.
  final double threadContentParagraphSpacing;

  /// Whether long paragraphs of the post content are cut after the end of a sentence. Not required: backups from older
  /// versions lack it.
  final bool threadContentSplitLongParagraphs;

  /// Whether the links in the post content that show the url of a thread are drawn as cards of the thread. Not
  /// required: backups from older versions lack it.
  final bool threadLinkCard;

  /// Widest the floors grow, 0: as the app lays them out. Not required: backups from older versions lack it.
  final double threadContentMaxWidth;

  /// The widest the floors grow ([threadContentMaxWidth]) in the range the settings offer, 0 for none (a value from an
  /// older backup or written by hand is clamped).
  double get readingMaxWidth => PostTypography(maxWidth: threadContentMaxWidth).clamped().maxWidth;

  /// How the post content is laid out with these settings, in the ranges the settings offer (a value from an older
  /// backup or written by hand is clamped).
  PostTypography get postTypography => PostTypography(
    lineHeight: threadContentLineHeight,
    paragraphSpacing: threadContentParagraphSpacing,
    splitLongParagraphs: threadContentSplitLongParagraphs,
  ).clamped();

  /// Whether Android runs at the highest refresh rate of the screen. Not required: backups from older versions lack it.
  final bool highRefreshRate;

  /// Name of the app icon in use, see `AppIcon`. Not required: backups from older versions lack it.
  final String appIcon;

  /// Whether the thread pages loaded are saved for reading without network. Not required: backups from older versions
  /// lack it.
  final bool offlineThreads;

  /// How many threads the offline pages are kept for. Not required: backups from older versions lack it.
  final int offlineThreadsLimit;

  /// Whether floors are rendered from their bbcode by the app (experimental). Not required: backups from older
  /// versions lack it.
  final bool enableAppPostRenderer;

  /// Title of the pinned thread group last selected on the phone homepage, empty for the first one. Not required:
  /// backups from older versions lack it.
  final String homepagePinnedGroup;

  /// When the pictures of the posts load by themselves, the index of a `PostImageAutoLoad`. Not required: backups from
  /// older versions lack it.
  final int postImageAutoLoad;

  /// When the data saver holds the large pictures back, the index of a `DataSaverMode`. Not required: backups from
  /// older versions lack it.
  final int dataSaverMode;

  /// The quick phrases of the editors' toolbar button, a JSON list of strings in the user's order (see
  /// `decodeQuickPhrases`). Not required: backups from older versions lack it.
  final String editorQuickPhrases;

  /// See `SettingsKeys.editImageBeforeUpload`. Not required: backups from older versions lack it.
  final bool editImageBeforeUpload;

  /// See `SettingsKeys.uploadImageMaxSide`. Not required: backups from older versions lack it.
  final int uploadImageMaxSide;

  /// See `SettingsKeys.uploadImageQuality`. Not required: backups from older versions lack it.
  final int uploadImageQuality;

  /// The pinned and recent forums of every account, see `SettingsKeys.frequentForums`.
  final String frequentForums;

  /// See `SettingsKeys.attachmentDownloadDirectory`.
  final String attachmentDownloadDirectory;

  SettingsMap copyWithKey<T>(SettingsKeys<T> key, T? value) {
    assert(
      T == key.type || T.toString() == '${key.type}?',
      'Settings value type and expected extract type MUST equal\n'
      'expected ${key.type}, but got $T',
    );

    return switch (key) {
      SettingsKeys.netClientAccept => copyWith(netClientAccept: value as String?),
      SettingsKeys.netClientAcceptEncoding => copyWith(netClientAcceptEncoding: value as String?),
      SettingsKeys.netClientAcceptLanguage => copyWith(netClientAcceptLanguage: value as String?),
      SettingsKeys.netClientUserAgent => copyWith(netClientUserAgent: value as String?),
      SettingsKeys.windowRememberSize => copyWith(windowRememberSize: value as bool?),
      SettingsKeys.windowMaximized => copyWith(windowMaximized: value as bool?),
      SettingsKeys.windowSize => copyWith(windowSize: value as Size?),
      SettingsKeys.windowRememberPosition => copyWith(windowRememberPosition: value as bool?),
      SettingsKeys.windowPosition => copyWith(windowPosition: value as Offset?),
      SettingsKeys.windowInCenter => copyWith(windowInCenter: value as bool?),
      SettingsKeys.loginUsername => copyWith(loginUsername: value as String?),
      SettingsKeys.loginUid => copyWith(loginUid: value as int?),
      SettingsKeys.loginEmail => copyWith(loginEmail: value as String?),
      SettingsKeys.themeMode => copyWith(themeMode: value as int?),
      SettingsKeys.locale => copyWith(locale: value as String?),
      SettingsKeys.checkinFeeling => copyWith(checkinFeeling: value as String?),
      SettingsKeys.checkinMessage => copyWith(checkinMessage: value as String?),
      SettingsKeys.showShortcutInForumCard => copyWith(showShortcutInForumCard: value as bool?),
      SettingsKeys.accentColor => copyWith(accentColor: value as int?),
      SettingsKeys.accentColorFollowSystem => copyWith(accentColorFollowSystem: value as bool?),
      SettingsKeys.showUnreadInfoHint => copyWith(showUnreadInfoHint: value as bool?),
      SettingsKeys.threadReverseOrder => copyWith(threadReverseOrder: value as bool?),
      SettingsKeys.threadCardInfoRowAlignCenter => copyWith(threadCardInfoRowAlignCenter: value as bool?),
      SettingsKeys.threadCardShowLastReplyAuthor => copyWith(threadCardShowLastReplyAuthor: value as bool?),
      SettingsKeys.threadCardHighlightRecentThread => copyWith(threadCardHighlightRecentThread: value as bool?),
      SettingsKeys.threadCardHighlightAuthorName => copyWith(threadCardHighlightAuthorName: value as bool?),
      SettingsKeys.threadCardHighlightInfoRow => copyWith(threadCardHighlightInfoRow: value as bool?),
      SettingsKeys.threadCardShowExcerpt => copyWith(threadCardShowExcerpt: value as bool?),
      SettingsKeys.chineseDisplayMode => copyWith(chineseDisplayMode: value as int?),
      SettingsKeys.threadCardThumbnailMode => copyWith(threadCardThumbnailMode: value as int?),
      SettingsKeys.threadCardExternalThumbnails => copyWith(threadCardExternalThumbnails: value as bool?),
      SettingsKeys.homeLayout => copyWith(homeLayout: value as String?),
      SettingsKeys.netClientProxy => copyWith(netClientProxy: value as String?),
      SettingsKeys.netClientUseProxy => copyWith(netClientUseProxy: value as bool?),
      SettingsKeys.autoCheckin => copyWith(autoCheckin: value as bool?),
      SettingsKeys.autoDailyRedPacket => copyWith(autoDailyRedPacket: value as bool?),
      SettingsKeys.showUnreadNoticeBadge => copyWith(showUnreadNoticeBadge: value as bool?),
      SettingsKeys.showUnreadPersonalMessageBadge => copyWith(showUnreadPersonalMessageBadge: value as bool?),
      SettingsKeys.showUnreadBroadcastMessageBadge => copyWith(showUnreadBroadcastMessageBadge: value as bool?),
      SettingsKeys.autoSyncNoticeSeconds => copyWith(autoSyncNoticeSeconds: value as int?),
      SettingsKeys.enableBackgroundMessageService => copyWith(enableBackgroundMessageService: value as bool?),
      SettingsKeys.backgroundSyncAllAccounts => copyWith(backgroundSyncAllAccounts: value as bool?),
      SettingsKeys.notificationHideContent => copyWith(notificationHideContent: value as bool?),
      SettingsKeys.notificationDirectReply => copyWith(notificationDirectReply: value as bool?),
      SettingsKeys.readingTimeStats => copyWith(readingTimeStats: value as bool?),
      SettingsKeys.notifyReply => copyWith(notifyReply: value as bool?),
      SettingsKeys.notifyMention => copyWith(notifyMention: value as bool?),
      SettingsKeys.notifyRate => copyWith(notifyRate: value as bool?),
      SettingsKeys.notifyPersonalMessage => copyWith(notifyPersonalMessage: value as bool?),
      SettingsKeys.notifySystem => copyWith(notifySystem: value as bool?),
      SettingsKeys.notifyFollowedThread => copyWith(notifyFollowedThread: value as bool?),
      SettingsKeys.followedThreadCheckMinutes => copyWith(followedThreadCheckMinutes: value as int?),
      SettingsKeys.notifyForumNewThread => copyWith(notifyForumNewThread: value as bool?),
      SettingsKeys.notifyKeywordAlert => copyWith(notifyKeywordAlert: value as bool?),
      SettingsKeys.forumWatchCheckMinutes => copyWith(forumWatchCheckMinutes: value as int?),
      SettingsKeys.notifyQuietHours => copyWith(notifyQuietHours: value as bool?),
      SettingsKeys.notifyQuietStart => copyWith(notifyQuietStart: value as int?),
      SettingsKeys.notifyQuietEnd => copyWith(notifyQuietEnd: value as int?),
      SettingsKeys.enableDebugOperations => copyWith(enableDebugOperations: value as bool?),
      SettingsKeys.fontFamily => copyWith(fontFamily: value as String?),
      SettingsKeys.enableEditorBBCodeParser => copyWith(enableEditorBBCodeParser: value as bool?),
      SettingsKeys.enableUpdateCheckOnStartup => copyWith(enableUpdateCheckOnStartup: value as bool?),
      SettingsKeys.editorRecentUsedCustomColors => copyWith(editorRecentUsedCustomColors: value as List<int>?),
      SettingsKeys.useDetectedProxyWhenStartup => copyWith(useDetectedProxyWhenStartup: value as bool?),
      SettingsKeys.enableAutoClearImageCache => copyWith(enableAutoClearImageCache: value as bool?),
      SettingsKeys.autoClearImageCacheDuration => copyWith(autoClearImageCacheDuration: value as int?),
      SettingsKeys.collapseAppBarWhenScroll => copyWith(collapseAppBarWhenScroll: value as bool?),
      SettingsKeys.threadOpenPosition => copyWith(threadOpenPosition: value as int?),
      SettingsKeys.threadSwipePaging => copyWith(threadSwipePaging: value as bool?),
      SettingsKeys.immersiveForums => copyWith(immersiveForums: value as String?),
      SettingsKeys.immersiveAllForums => copyWith(immersiveAllForums: value as bool?),
      SettingsKeys.twoPaneLayout => copyWith(twoPaneLayout: value as bool?),
      SettingsKeys.twoPaneListWidth => copyWith(twoPaneListWidth: value as double?),
      SettingsKeys.postMediaPreview => copyWith(postMediaPreview: value as bool?),
      SettingsKeys.inAppBrowserForForum => copyWith(inAppBrowserForForum: value as bool?),
      SettingsKeys.inAppBrowserForAll => copyWith(inAppBrowserForAll: value as bool?),
      SettingsKeys.crossDeviceSync => copyWith(crossDeviceSync: value as bool?),
      SettingsKeys.crossDeviceSyncRateTemplates => copyWith(crossDeviceSyncRateTemplates: value as bool?),
      SettingsKeys.crossDeviceSyncSettings => copyWith(crossDeviceSyncSettings: value as bool?),
      SettingsKeys.crossDeviceSyncDrafts => copyWith(crossDeviceSyncDrafts: value as bool?),
      SettingsKeys.crossDeviceSyncBookmarks => copyWith(crossDeviceSyncBookmarks: value as bool?),
      SettingsKeys.crossDeviceSyncPinnedForums => copyWith(crossDeviceSyncPinnedForums: value as bool?),
      SettingsKeys.crossDeviceSyncForumWatch => copyWith(crossDeviceSyncForumWatch: value as bool?),
      SettingsKeys.themeModeScheduled => copyWith(themeModeScheduled: value as bool?),
      SettingsKeys.darkScheduleStart => copyWith(darkScheduleStart: value as int?),
      SettingsKeys.darkScheduleEnd => copyWith(darkScheduleEnd: value as int?),
      SettingsKeys.threadFloorInteractionMode => copyWith(
        threadFloorInteractionMode: value as ThreadFloorInteractionMode?,
      ),
      SettingsKeys.textScaleFactor => copyWith(textScaleFactor: value as double?),
      SettingsKeys.threadContentScale => copyWith(threadContentScale: value as double?),
      SettingsKeys.threadContentLineHeight => copyWith(threadContentLineHeight: value as double?),
      SettingsKeys.threadContentParagraphSpacing => copyWith(threadContentParagraphSpacing: value as double?),
      SettingsKeys.threadContentSplitLongParagraphs => copyWith(threadContentSplitLongParagraphs: value as bool?),
      SettingsKeys.threadLinkCard => copyWith(threadLinkCard: value as bool?),
      SettingsKeys.threadContentMaxWidth => copyWith(threadContentMaxWidth: value as double?),
      SettingsKeys.highRefreshRate => copyWith(highRefreshRate: value as bool?),
      SettingsKeys.appIcon => copyWith(appIcon: value as String?),
      SettingsKeys.offlineThreads => copyWith(offlineThreads: value as bool?),
      SettingsKeys.offlineThreadsLimit => copyWith(offlineThreadsLimit: value as int?),
      SettingsKeys.enableAppPostRenderer => copyWith(enableAppPostRenderer: value as bool?),
      SettingsKeys.homepagePinnedGroup => copyWith(homepagePinnedGroup: value as String?),
      SettingsKeys.notificationPermissionPrompted => copyWith(notificationPermissionPrompted: value as bool?),
      SettingsKeys.postImageAutoLoad => copyWith(postImageAutoLoad: value as int?),
      SettingsKeys.dataSaverMode => copyWith(dataSaverMode: value as int?),
      SettingsKeys.editorQuickPhrases => copyWith(editorQuickPhrases: value as String?),
      SettingsKeys.editImageBeforeUpload => copyWith(editImageBeforeUpload: value as bool?),
      SettingsKeys.uploadImageMaxSide => copyWith(uploadImageMaxSide: value as int?),
      SettingsKeys.uploadImageQuality => copyWith(uploadImageQuality: value as int?),
      SettingsKeys.frequentForums => copyWith(frequentForums: value as String?),
      SettingsKeys.attachmentDownloadDirectory => copyWith(attachmentDownloadDirectory: value as String?),
    };
  }
}
