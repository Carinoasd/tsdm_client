import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:tsdm_client/features/settings/widgets/font_scale_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/thread_content_scale_dialog.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/models/thread_floor_interaction_mode.dart';
import 'package:tsdm_client/shared/models/thread_open_position.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';

/// A setting the cross-device sync carries in the `settings` section, by its stored name ([SettingsKeys.name]).
@immutable
final class SyncedSetting<T extends Object> {
  const SyncedSetting._(this.key, this._read, {num? min, num? max}) : _min = min, _max = max;

  /// The key.
  final SettingsKeys<T> key;

  final T Function(SettingsMap settings) _read;
  final num? _min;
  final num? _max;

  /// The value in the document: the setting's value; an enum by its index.
  Object encode(SettingsMap settings) => encodeValue(_read(settings));

  /// The setting's value the document [value] stands for, null when it is not one this version accepts (another type,
  /// out of range).
  Object? decode(Object? value) {
    bool inRange(num n) => (_min == null || n >= _min) && (_max == null || n <= _max);
    if (key.type == bool) {
      return value is bool ? value : null;
    }
    if (key.type == String) {
      return value is String ? value : null;
    }
    if (key.type == int) {
      return value is int && inRange(value) ? value : null;
    }
    if (key.type == double) {
      return value is num && value.isFinite && inRange(value) ? value.toDouble() : null;
    }
    if (key.type == ThreadFloorInteractionMode) {
      return value is int && value >= 0 && value < ThreadFloorInteractionMode.values.length
          ? ThreadFloorInteractionMode.values[value]
          : null;
    }
    return null;
  }

  /// The setting's value now, as [decode] gives it.
  Object current(SettingsMap settings) => _read(settings);

  /// The value in the document of the setting's [value] (as [decode] gives it).
  Object encodeValue(Object value) => value is ThreadFloorInteractionMode ? value.index : value;

  /// The value in the document of the setting's default.
  Object get encodedDefault => encodeValue(key.defaultValue);
}

/// The settings the cross-device sync carries: how threads read and look, and the account's daily habits. A setting
/// tied to the device is never one of them:
///
/// * the window (size, position), the network (proxy, headers), the login, the locale and the font (installed per
///   device), the accent color (it may follow the wallpaper), the refresh rate, the two-pane layout and the widest
///   floors (the width of the screen);
/// * the notifications, the auto sync and the background service, the update check, the debug switch;
/// * the image cache and the offline threads (the storage of the device), the homepage group last opened;
/// * the quick phrases (their own section) and the switches of the sync itself.
final syncedSettings = <SyncedSetting<Object>>[
  // Theme.
  SyncedSetting._(SettingsKeys.themeMode, (s) => s.themeMode, min: 0, max: ThemeMode.values.length - 1),
  SyncedSetting._(SettingsKeys.themeModeScheduled, (s) => s.themeModeScheduled),
  SyncedSetting._(SettingsKeys.darkScheduleStart, (s) => s.darkScheduleStart, min: 0, max: 1439),
  SyncedSetting._(SettingsKeys.darkScheduleEnd, (s) => s.darkScheduleEnd, min: 0, max: 1439),
  // Text.
  SyncedSetting._(
    SettingsKeys.textScaleFactor,
    (s) => s.textScaleFactor,
    min: textScaleFactorMin,
    max: textScaleFactorMax,
  ),
  SyncedSetting._(
    SettingsKeys.threadContentScale,
    (s) => s.threadContentScale,
    min: threadContentScaleMin,
    max: threadContentScaleMax,
  ),
  SyncedSetting._(
    SettingsKeys.threadContentLineHeight,
    (s) => s.threadContentLineHeight,
    min: PostTypography.minLineHeight,
    max: PostTypography.maxLineHeight,
  ),
  SyncedSetting._(
    SettingsKeys.threadContentParagraphSpacing,
    (s) => s.threadContentParagraphSpacing,
    min: PostTypography.minParagraphSpacing,
    max: PostTypography.maxParagraphSpacing,
  ),
  SyncedSetting._(SettingsKeys.threadContentSplitLongParagraphs, (s) => s.threadContentSplitLongParagraphs),
  SyncedSetting._(SettingsKeys.threadLinkCard, (s) => s.threadLinkCard),
  // Thread lists.
  SyncedSetting._(SettingsKeys.showShortcutInForumCard, (s) => s.showShortcutInForumCard),
  SyncedSetting._(SettingsKeys.threadCardInfoRowAlignCenter, (s) => s.threadCardInfoRowAlignCenter),
  SyncedSetting._(SettingsKeys.threadCardShowLastReplyAuthor, (s) => s.threadCardShowLastReplyAuthor),
  SyncedSetting._(SettingsKeys.threadCardHighlightRecentThread, (s) => s.threadCardHighlightRecentThread),
  SyncedSetting._(SettingsKeys.threadCardHighlightAuthorName, (s) => s.threadCardHighlightAuthorName),
  SyncedSetting._(SettingsKeys.threadCardHighlightInfoRow, (s) => s.threadCardHighlightInfoRow),
  SyncedSetting._(SettingsKeys.threadCardShowExcerpt, (s) => s.threadCardShowExcerpt),
  SyncedSetting._(
    SettingsKeys.threadCardThumbnailMode,
    (s) => s.threadCardThumbnailMode,
    min: 0,
    max: ThreadThumbnailMode.values.length - 1,
  ),
  SyncedSetting._(SettingsKeys.threadCardExternalThumbnails, (s) => s.threadCardExternalThumbnails),
  // Threads.
  SyncedSetting._(SettingsKeys.threadReverseOrder, (s) => s.threadReverseOrder),
  SyncedSetting._(SettingsKeys.collapseAppBarWhenScroll, (s) => s.collapseAppBarWhenScroll),
  SyncedSetting._(
    SettingsKeys.threadOpenPosition,
    (s) => s.threadOpenPosition,
    min: 0,
    max: ThreadOpenPosition.values.length - 1,
  ),
  SyncedSetting._(SettingsKeys.threadSwipePaging, (s) => s.threadSwipePaging),
  SyncedSetting._(SettingsKeys.immersiveForums, (s) => s.immersiveForums),
  SyncedSetting._(SettingsKeys.immersiveAllForums, (s) => s.immersiveAllForums),
  SyncedSetting._(SettingsKeys.threadFloorInteractionMode, (s) => s.threadFloorInteractionMode),
  SyncedSetting._(
    SettingsKeys.postImageAutoLoad,
    (s) => s.postImageAutoLoad,
    min: 0,
    max: PostImageAutoLoad.values.length - 1,
  ),
  SyncedSetting._(SettingsKeys.enableAppPostRenderer, (s) => s.enableAppPostRenderer),
  SyncedSetting._(SettingsKeys.enableEditorBBCodeParser, (s) => s.enableEditorBBCodeParser),
  // Unread badges.
  SyncedSetting._(SettingsKeys.showUnreadInfoHint, (s) => s.showUnreadInfoHint),
  SyncedSetting._(SettingsKeys.showUnreadNoticeBadge, (s) => s.showUnreadNoticeBadge),
  SyncedSetting._(SettingsKeys.showUnreadPersonalMessageBadge, (s) => s.showUnreadPersonalMessageBadge),
  SyncedSetting._(SettingsKeys.showUnreadBroadcastMessageBadge, (s) => s.showUnreadBroadcastMessageBadge),
  // The account's daily habits.
  SyncedSetting._(SettingsKeys.autoCheckin, (s) => s.autoCheckin),
  SyncedSetting._(SettingsKeys.autoDailyRedPacket, (s) => s.autoDailyRedPacket),
  SyncedSetting._(SettingsKeys.checkinFeeling, (s) => s.checkinFeeling),
  SyncedSetting._(SettingsKeys.checkinMessage, (s) => s.checkinMessage),
];

/// The values of [syncedSettings] in [settings], by stored name: the `values` of the `settings` section.
Map<String, Object> syncedSettingsValues(SettingsMap settings) => {
  for (final s in syncedSettings) s.key.name: s.encode(settings),
};

/// What applying the document's [values] to [settings] changes: each setting of [syncedSettings] the document holds a
/// value of that this version accepts and that differs from the one of [settings]. Values it does not accept and names
/// it does not know are left alone.
List<(SettingsKeys<Object>, Object)> syncedSettingsChanges(Map<String, dynamic> values, SettingsMap settings) => [
  for (final s in syncedSettings)
    if (s.decode(values[s.key.name]) case final value? when value != s.current(settings)) (s.key, value),
];

/// The values of [syncedSettings] at their defaults, by stored name.
Map<String, Object> syncedSettingsDefaults() => {for (final s in syncedSettings) s.key.name: s.encodedDefault};

/// [current] (values of [syncedSettings] by stored name) with the document's [values] applied: each value this version
/// accepts replaces the one of its setting.
Map<String, Object> syncedSettingsApplied(Map<String, Object> current, Map<String, dynamic> values) => {
  ...current,
  for (final s in syncedSettings)
    if (s.decode(values[s.key.name]) case final value?) s.key.name: s.encodeValue(value),
};
