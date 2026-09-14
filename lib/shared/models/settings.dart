part of 'models.dart';

/// Keys for all settings.
// ignore_for_file: public_member_api_docs
enum SettingsKeys<T> implements Comparable<SettingsKeys<T>> {
  netClientAccept<String>(
    name: 'netClientAccept',
    type: String,
    defaultValue:
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  ),

  netClientAcceptEncoding<String>(name: 'netClientAcceptEncoding', type: String, defaultValue: 'gzip, deflate, br'),

  netClientAcceptLanguage<String>(
    name: 'dioAcceptLanguage',
    type: String,
    defaultValue: 'zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6,zh-TW;q=0.5',
  ),

  netClientUserAgent<String>(
    name: 'dioUserAgent',
    type: String,
    defaultValue: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0',
  ),

  windowRememberSize<bool>(name: 'windowRememberSize', type: bool, defaultValue: true),

  windowMaximized<bool>(name: 'windowMaximized', type: bool, defaultValue: false),

  windowSize<Size>(name: 'windowSize', type: Size, defaultValue: Size(800, 600)),

  windowRememberPosition<bool>(name: 'windowRememberPosition', type: bool, defaultValue: true),

  windowPosition<Offset>(name: 'windowPosition', type: Offset, defaultValue: Offset.zero),

  windowInCenter<bool>(name: 'windowInCenter', type: bool, defaultValue: false),

  loginUsername<String>(name: 'loginUsername', type: String, defaultValue: ''),

  loginUid<int>(name: 'loginUid', type: int, defaultValue: 0),

  loginEmail<String>(name: 'loginEmail', type: String, defaultValue: ''),

  themeMode<int>(name: 'ThemeMode', type: int, defaultValue: 0),

  locale<String>(name: 'locale', type: String, defaultValue: ''),

  checkinFeeling<String>(name: 'checkInFeeling', type: String, defaultValue: 'kx'),

  checkinMessage<String>(name: 'checkInMessage', type: String, defaultValue: '每日签到'),

  showShortcutInForumCard<bool>(name: 'showShortcutInForumCard', type: bool, defaultValue: false),

  accentColor<int>(
    name: 'accentColor',
    type: int,
    defaultValue: 4280391411, // PrimaryColors.blue
  ),

  accentColorFollowSystem<bool>(name: 'accentColorFollowSystem', type: bool, defaultValue: false),

  showUnreadInfoHint<bool>(name: 'showUnreadInfoHint', type: bool, defaultValue: true),

  threadReverseOrder<bool>(name: 'threadReverseOrder', type: bool, defaultValue: false),

  threadCardInfoRowAlignCenter<bool>(name: 'threadCardInfoRowAlignCenter', type: bool, defaultValue: false),

  threadCardShowLastReplyAuthor<bool>(name: 'threadCardShowLastReplyAuthor', type: bool, defaultValue: true),

  threadCardHighlightRecentThread<bool>(name: 'threadCardHighlightRecentThread', type: bool, defaultValue: true),

  threadCardHighlightAuthorName<bool>(name: 'threadCardHighlightAuthorName', type: bool, defaultValue: true),
  threadCardHighlightInfoRow<bool>(name: 'threadCardHighlightInfoRow', type: bool, defaultValue: true),

  netClientUseProxy<bool>(name: 'netClientUseProxy', type: bool, defaultValue: false),

  netClientProxy<String>(name: 'netClientProxy', type: String, defaultValue: ''),

  autoCheckin<bool>(name: 'autoCheckin', type: bool, defaultValue: true),

  showUnreadNoticeBadge<bool>(name: 'showUnreadNoticeBadge', type: bool, defaultValue: true),

  showUnreadPersonalMessageBadge<bool>(name: 'showUnreadPersonalMessageBadge', type: bool, defaultValue: true),

  showUnreadBroadcastMessageBadge<bool>(name: 'showUnreadBroadcastMessageBadge', type: bool, defaultValue: true),

  autoSyncNoticeSeconds<int>(name: 'autoSyncNoticeSeconds', type: int, defaultValue: 600),

  enableDebugOperations<bool>(name: 'enableDebugOperations', type: bool, defaultValue: false),

  fontFamily<String>(name: 'fontFamily', type: String, defaultValue: ''),

  enableEditorBBCodeParser<bool>(name: 'enableEditorBBCodeParser', type: bool, defaultValue: true),

  enableUpdateCheckOnStartup<bool>(name: 'enableUpdateCheckOnStartup', type: bool, defaultValue: true),

  editorRecentUsedCustomColors<List<int>>(name: 'editorRecentUsedCustomColors', type: List<int>, defaultValue: []),

  useDetectedProxyWhenStartup<bool>(name: 'useDetectedProxyWhenStartup', type: bool, defaultValue: false),

  enableAutoClearImageCache<bool>(name: 'enableAutoClearImageCache', type: bool, defaultValue: false),

  autoClearImageCacheDuration<int>(name: 'autoClearImageCacheDuration', type: int, defaultValue: 60 * 60 * 24 * 7),

  collapseAppBarWhenScroll<bool>(name: 'collapseAppBarWhenScroll', type: bool, defaultValue: true),

  threadFloorInteractionMode<ThreadFloorInteractionMode>(
    name: 'threadFloorInteractionMode',
    type: ThreadFloorInteractionMode,
    defaultValue: ThreadFloorInteractionMode.adaptiveTapMenu,
  ),

  textScaleFactor<double>(
    name: 'textScaleFactor',
    type: double,
    defaultValue: 1,
  ),

  /// 记住上次退出时的选择。
  rememberExitChoice<bool>(name: 'rememberExitChoice', type: bool, defaultValue: false),

  /// 上次退出时选择的动作：'logout' (退出账号) 或 'exit' (退出软件)。
  exitAction<String>(name: 'exitAction', type: String, defaultValue: 'exit'),
  ;

  const SettingsKeys({required this.name, required this.type, required this.defaultValue});

  final String name;
  final Type type;
  final T defaultValue;

  @override
  // Intend to have dynamic types.
  // ignore: avoid_dynamic
  int compareTo(SettingsKeys<dynamic> other) => name.compareTo(other.name);
}
