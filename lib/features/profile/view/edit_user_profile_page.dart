import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputFormatter;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/profile/bloc/edit_user_profile_bloc.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart' as eup;
import 'package:tsdm_client/features/profile/repository/edit_user_profile_repository.dart';
import 'package:tsdm_client/features/profile/widgets/select_birthday_dialog.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

typedef _Keys = UserProfileKeys;

const _profileFieldTextMaxLines = 10;
const _profileFieldTextMinLines = 3;

/// Page allow showing and editing current user's profile.
class EditUserProfilePage extends StatefulWidget {
  /// Constructor.
  const EditUserProfilePage({super.key});

  @override
  State<EditUserProfilePage> createState() => _EditUserProfilePageState();
}

class _EditUserProfilePageState extends State<EditUserProfilePage> {
  final formKey = GlobalKey<FormState>();

  /// Callback called when a profile list tile with limited selectable choices is pressed.
  ///
  /// 1. Show a dialog for user to update profile value.
  /// 2. Save new value, if any.
  Future<void> _spawnSelectionDialog<Value>({
    required BuildContext context,
    required eup.UserProfile profile,
    required String title,
    required List<(Value, String)> valueNamePairs,
    required eup.UserProfile Function(eup.UserProfile, Value) onValueUpdated,
    Value? currentValue,
    IconData? icon,
  }) async {
    final newValue = await _showSelectionDialog<Value>(
      context: context,
      title: title,
      icon: icon,
      currentValue: currentValue,
      valueNamePairs: valueNamePairs,
    );

    if (newValue == null || !context.mounted) {
      return;
    }
    context.read<EditUserProfileBloc>().add(
      EditUserProfileSaveProfileRequested(onValueUpdated(profile, newValue)),
    );
  }

  Future<void> _spawnTextFieldDialog({
    required BuildContext context,
    required eup.UserProfile profile,
    required String title,
    required String currentValue,
    required eup.UserProfile Function(eup.UserProfile, String) onValueUpdated,
    FormFieldValidator<String>? validator,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    InputDecoration? inputDecoration,
    int? maxLines = 1,
    int? minLines,
    IconData? icon,
  }) async {
    final newValue = await _showTextFieldDialog(
      context: context,
      title: title,
      icon: icon,
      profile: profile,
      initialText: currentValue,
      onValueUpdated: onValueUpdated,
      validator: validator,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      inputDecoration: inputDecoration,
      maxLines: maxLines,
      minLines: minLines,
    );

    if (newValue == null || !context.mounted) {
      return;
    }
    context.read<EditUserProfileBloc>().add(
      EditUserProfileSaveProfileRequested(onValueUpdated(profile, newValue)),
    );
  }

  /// A text field of the profile: the row, and its dialog with the same icon.
  Widget _textTile({
    required BuildContext context,
    required eup.UserProfile profile,
    required IconData icon,
    required String title,
    required String? value,
    required eup.UserProfile Function(eup.UserProfile, String) onValueUpdated,
    eup.Visibility? visibility,
    FutureOr<void> Function(eup.Visibility)? onVisibilityChanged,
    bool multiline = false,
    bool editable = true,
  }) => _buildProfileListTile<String?>(
    context: context,
    icon: icon,
    title: title,
    subtitle: value ?? '',
    value: value,
    visibility: visibility,
    onVisibilityChanged: onVisibilityChanged,
    onTap: !editable
        ? null
        : (v) async => _spawnTextFieldDialog(
            context: context,
            profile: profile,
            title: title,
            icon: icon,
            currentValue: v ?? '',
            onValueUpdated: onValueUpdated,
            maxLines: multiline ? _profileFieldTextMaxLines : 1,
            minLines: multiline ? _profileFieldTextMinLines : null,
          ),
  );

  void _save(BuildContext context, eup.UserProfile profile) =>
      context.read<EditUserProfileBloc>().add(EditUserProfileSaveProfileRequested(profile));

  Widget _buildBody(BuildContext context, eup.UserProfile profile) {
    final tr = context.t.editUserProfilePage;

    // Same fields, dialogs and values as before, grouped by what they are about.
    final basic = AppTileGroup(
      title: tr.sections.basic,
      icon: Icons.person_outline,
      children: [
        _buildProfileListTile(
          context: context,
          icon: Icons.badge_outlined,
          title: tr.username,
          value: tr.username,
          subtitle: profile.usernameReadonly,
        ),
        if (profile.shows(_Keys.gender))
          _buildProfileListTile(
            context: context,
            icon: Icons.face_2_outlined,
            title: tr.gender.title,
            subtitle: switch (profile.gender) {
              eup.Gender.private => tr.gender.hide,
              eup.Gender.male => tr.gender.male,
              eup.Gender.female => tr.gender.female,
            },
            value: profile.gender,
            visibility: profile.genderVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(genderVisibility: visibility)),
            onTap: !profile.canEdit(_Keys.gender)
                ? null
                : (gender) async => _spawnSelectionDialog<eup.Gender>(
                    context: context,
                    profile: profile,
                    title: tr.gender.title,
                    icon: Icons.face_2_outlined,
                    currentValue: profile.gender,
                    valueNamePairs: [
                      (eup.Gender.private, tr.gender.hide),
                      (eup.Gender.male, tr.gender.male),
                      (eup.Gender.female, tr.gender.female),
                    ],
                    onValueUpdated: (p, v) => p.copyWith(gender: v),
                  ),
          ),
        if (profile.shows(_Keys.birthday))
          _buildProfileListTile(
            context: context,
            icon: Icons.cake_outlined,
            title: tr.birthday.title,
            subtitle:
                '${profile.birthdayYear ?? "-"} ${tr.birthday.year} '
                '${profile.birthdayMonth ?? "-"} ${tr.birthday.month} '
                '${profile.birthdayDay ?? "-"} ${tr.birthday.day}',
            value: _BirthdayInfo(
              year: profile.birthdayYear,
              month: profile.birthdayMonth,
              day: profile.birthdayDay,
              availableYears: profile.birthdayAvailableYears,
            ),
            visibility: profile.birthdayVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(birthdayVisibility: visibility)),
            onTap: !profile.canEdit(_Keys.birthday)
                ? null
                : (_) async {
                    final birthday = await showSelectBirthdayDialog(
                      context,
                      BirthdayInfo(
                        year: profile.birthdayYear,
                        month: profile.birthdayMonth,
                        day: profile.birthdayDay,
                      ),
                      profile.birthdayAvailableYears,
                    );
                    if (birthday == null || !context.mounted) {
                      return;
                    }
                    _save(
                      context,
                      profile.copyWith(
                        birthdayYear: birthday.year,
                        birthdayMonth: birthday.month,
                        birthdayDay: birthday.day,
                      ),
                    );
                  },
          ),
        if (profile.shows(_Keys.location))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.location_on_outlined,
            title: tr.location,
            value: profile.location,
            editable: profile.canEdit(_Keys.location),
            visibility: profile.locationVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(locationVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(location: v),
          ),
        if (profile.shows(_Keys.nickname))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.alternate_email_outlined,
            title: tr.nickname,
            value: profile.nickname,
            editable: profile.canEdit(_Keys.nickname),
            visibility: profile.nicknameVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(nicknameVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(nickname: v),
          ),
        if (profile.shows(_Keys.timezone))
          _buildProfileListTile(
            context: context,
            icon: Icons.schedule_outlined,
            title: tr.timezone,
            value: _TimeZoneInfo(profile.timeZone, profile.availableTimeZones),
            subtitle: profile.timeZone?.name ?? '-',
            onTap: !profile.canEdit(_Keys.timezone)
                ? null
                : (gender) async => _spawnSelectionDialog<String>(
                    context: context,
                    profile: profile,
                    title: tr.timezone,
                    icon: Icons.schedule_outlined,
                    currentValue: profile.timeZone?.value,
                    valueNamePairs: profile.availableTimeZones.map((v) => (v.value, v.name)).toList(),
                    onValueUpdated: (p, v) => p.copyWith(
                      timeZone: profile.availableTimeZones.firstWhereOrNull((e) => e.value == v),
                    ),
                  ),
          ),
      ],
    );

    final contact = AppTileGroup(
      title: tr.sections.contact,
      icon: Icons.contact_mail_outlined,
      children: [
        if (profile.shows(_Keys.qq))
          _buildProfileListTile(
            context: context,
            icon: Icons.chat_outlined,
            title: tr.qq.title,
            subtitle: '${profile.qq ?? ""}',
            value: profile.qq,
            visibility: profile.qqVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(qqVisibility: visibility)),
            onTap: !profile.canEdit(_Keys.qq)
                ? null
                : (v) async => _spawnTextFieldDialog(
                    context: context,
                    profile: profile,
                    title: tr.qq.title,
                    icon: Icons.chat_outlined,
                    currentValue: v == null ? '' : v.toString(),
                    onValueUpdated: (p, v) => p.copyWith(qq: v.parseToInt()),
                    validator: (v) {
                      if (v == null) {
                        return tr.qq.invalidQQ;
                      }

                      if (v.isEmpty) {
                        return null;
                      }

                      if (v.startsWith('0') || !RegExp('[0-9]{6,}').hasMatch(v)) {
                        return tr.qq.invalidQQ;
                      }

                      final vv = v.parseToInt();
                      if (vv == null || vv < 0) {
                        return tr.qq.invalidQQ;
                      }

                      return null;
                    },
                    keyboardType: .number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9]+'))],
                  ),
          ),
        if (profile.shows(_Keys.msn))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.forum_outlined,
            title: tr.msn,
            value: profile.msn,
            editable: profile.canEdit(_Keys.msn),
            visibility: profile.msnVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(msnVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(msn: v),
          ),
        if (profile.shows(_Keys.homepage))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.home_outlined,
            title: tr.homepage,
            value: profile.homepage,
            editable: profile.canEdit(_Keys.homepage),
            visibility: profile.homepageVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(homepageVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(homepage: v),
          ),
      ],
    );

    final aboutMe = AppTileGroup(
      title: tr.sections.aboutMe,
      icon: Icons.notes_outlined,
      children: [
        if (profile.shows(_Keys.bio))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.description_outlined,
            title: tr.bio,
            value: profile.bio,
            editable: profile.canEdit(_Keys.bio),
            visibility: profile.bioVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(bioVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(bio: v),
            multiline: true,
          ),
        if (profile.shows(_Keys.hobby))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.interests_outlined,
            title: tr.hobby,
            value: profile.hobby,
            editable: profile.canEdit(_Keys.hobby),
            visibility: profile.hobbyVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(hobbyVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(hobby: v),
            multiline: true,
          ),
        if (profile.shows(_Keys.wordsToSay))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.format_quote_outlined,
            title: tr.wordsToSay,
            value: profile.wordsToSay,
            editable: profile.canEdit(_Keys.wordsToSay),
            visibility: profile.wordsToSayVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(wordsToSayVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(wordsToSay: v),
          ),
        if (profile.shows(_Keys.skill))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.construction_outlined,
            title: tr.skills,
            value: profile.skill,
            editable: profile.canEdit(_Keys.skill),
            visibility: profile.skillVisibility,
            onVisibilityChanged: (visibility) => _save(context, profile.copyWith(skillVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(skill: v),
          ),
        if (profile.shows(_Keys.favoriteBangumi))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.live_tv_outlined,
            title: tr.favoriteBangumi,
            value: profile.favoriteBangumi,
            editable: profile.canEdit(_Keys.favoriteBangumi),
            visibility: profile.favoriteBangumiVisibility,
            onVisibilityChanged: (visibility) =>
                _save(context, profile.copyWith(favoriteBangumiVisibility: visibility)),
            onValueUpdated: (p, v) => p.copyWith(favoriteBangumi: v),
          ),
      ],
    );

    final forum = AppTileGroup(
      title: tr.sections.forum,
      icon: Icons.forum_outlined,
      children: [
        if (profile.shows(_Keys.customTitle))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.military_tech_outlined,
            title: tr.customTitle,
            value: profile.customTitle,
            editable: profile.canEdit(_Keys.customTitle),
            onValueUpdated: (p, v) => p.copyWith(customTitle: v),
          ),
        if (profile.shows(_Keys.signature))
          _textTile(
            context: context,
            profile: profile,
            icon: Icons.draw_outlined,
            title: tr.signature,
            value: profile.signature,
            editable: profile.canEdit(_Keys.signature),
            onValueUpdated: (p, v) => p.copyWith(signature: v),
            multiline: true,
          ),
        // Page style is not editable on Discuz X5 (no "styleid" select in form), hide it if no style available.
        if (profile.availablePageStyles.isNotEmpty)
          _buildProfileListTile(
            context: context,
            icon: Icons.palette_outlined,
            title: tr.pageStyle.title,
            value: _PageStyleInfo(profile.pageStyle, profile.availablePageStyles),
            subtitle: '${profile.pageStyle?.name ?? '-'} · ${tr.pageStyle.tip}',
            onTap: (gender) async => _spawnSelectionDialog<int>(
              context: context,
              profile: profile,
              title: tr.pageStyle.title,
              icon: Icons.palette_outlined,
              currentValue: profile.pageStyle?.value ?? 0,
              valueNamePairs: profile.availablePageStyles.map((v) => (v.value, v.name)).toList(),
              onValueUpdated: (p, v) => p.copyWith(
                pageStyle: profile.availablePageStyles.firstWhereOrNull((e) => e.value == v),
              ),
            ),
          ),
      ],
    );

    return Form(
      key: formKey,
      child: AppCenteredList(
        maxWidth: appFormMaxWidth,
        builder: (context, padding, _) => ListView(
          padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
          children: [
            // Edits stay on this page until uploaded with the button of the app bar.
            AppNoticeBanner(message: tr.uploadHint, icon: Icons.cloud_upload_outlined),
            // The editor of the forum's app API shows only the fields the page printed: a group may have none.
            for (final group in [basic, contact, aboutMe, forum].where((g) => g.children.isNotEmpty)) ...[
              const SizedBox(height: appSurfaceGap),
              group,
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider(
          create: (_) => EditUserProfileRepository(),
        ),
        BlocProvider(
          create: (context) => EditUserProfileBloc(context.repo())..add(const EditUserProfileLoadProfileRequested()),
        ),
      ],
      child: BlocConsumer<EditUserProfileBloc, EditUserProfileState>(
        listenWhen: (prev, curr) => prev.status == .submitting && curr.status != .submitting,
        listener: (context, state) {
          if (state.status == .success) {
            showSnackBar(context: context, message: context.t.editUserProfilePage.saveSuccess);
          } else if (state.status == .failure) {
            // The forum's words when it gave them (the field it refused, its message).
            final reason = state.failureReason;
            showSnackBar(
              context: context,
              message: reason == null || reason.isEmpty
                  ? context.t.editUserProfilePage.saveFailed
                  : context.t.editUserProfilePage.saveFailedReason(reason: reason),
            );
          }
        },
        builder: (context, state) {
          final body = switch (state.status) {
            EditUserProfileStatus.initial || EditUserProfileStatus.loading => const CenteredCircularIndicator(),
            EditUserProfileStatus.failure when state.profile == null => buildRetryButton(
              context,
              () => context.read<EditUserProfileBloc>().add(const EditUserProfileLoadProfileRequested()),
              message: state.failureReason,
            ),
            // Form pages stay at most [appFormMaxWidth] wide, centered on wide windows.
            _ => _buildBody(context, state.profile!),
          };

          return Scaffold(
            appBar: AppBar(
              title: Text(context.t.editUserProfilePage.title),
              actions: [
                IconButton(
                  icon: <EditUserProfileStatus>[.initial, .loading, .submitting].contains(state.status)
                      ? sizedCircularProgressIndicator
                      : const Icon(Icons.cloud_upload_outlined),
                  onPressed: state.status != .submitting && state.status != .loading
                      ? () => context.read<EditUserProfileBloc>().add(
                          EditUserProfileUploadProfileRequested(state.profile!),
                        )
                      : null,
                  tooltip: context.t.editUserProfilePage.save,
                ),
              ],
            ),
            body: SafeArea(top: false, bottom: false, child: body),
          );
        },
      ),
    );
  }
}

Widget _buildProfileListTile<T>({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String subtitle,
  required T value,
  eup.Visibility? visibility,
  FutureOr<void> Function(eup.Visibility)? onVisibilityChanged,
  FutureOr<void> Function(T)? onTap,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  return ListTile(
    leading: Icon(icon),
    title: Text(title),
    // An empty field says so instead of leaving a blank line.
    subtitle: SingleLineText(subtitle.trim().isEmpty ? '-' : subtitle),
    titleTextStyle: Theme.of(context).textTheme.labelMedium?.copyWith(color: colorScheme.secondary),
    subtitleTextStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: subtitle.trim().isEmpty ? colorScheme.outline : colorScheme.onSurface,
    ),
    onTap: onTap == null || context.read<EditUserProfileBloc>().state.status == .submitting
        ? null
        : () async => onTap.call(value),
    contentPadding: edgeInsetsL16R16,
    trailing: visibility == null
        ? null
        : IconButton(
            icon: Icon(switch (visibility) {
              eup.Visibility.public => Symbols.visibility,
              eup.Visibility.friendsOnly => Symbols.visibility_lock,
              eup.Visibility.private => Symbols.visibility_off,
            }),
            onPressed: context.read<EditUserProfileBloc>().state.status == .submitting
                ? null
                : () async {
                    final tr = context.t.editUserProfilePage.visibility;
                    final v = await _showSelectionDialog(
                      context: context,
                      title: '${tr.title} - $title',
                      icon: Symbols.visibility_lock,
                      currentValue: visibility,
                      valueNamePairs: [
                        (eup.Visibility.public, tr.public),
                        (eup.Visibility.friendsOnly, tr.friendsOnly),
                        (eup.Visibility.private, tr.private),
                      ],
                    );
                    if (v == null || !context.mounted) {
                      return;
                    }
                    await onVisibilityChanged?.call(v);
                  },
            tooltip: switch (visibility) {
              eup.Visibility.public => context.t.editUserProfilePage.visibility.public,
              eup.Visibility.friendsOnly => context.t.editUserProfilePage.visibility.friendsOnly,
              eup.Visibility.private => context.t.editUserProfilePage.visibility.private,
            },
          ),
  );
}

/// Show a dialog provides a list of choices.
///
/// Each choice is a value of type [Value], corresponding human readable description saved in tuple list
/// [valueNamePairs].
///
/// [title] is the title of dialog.
///
/// [currentValue] is the current selected value.
Future<Value?> _showSelectionDialog<Value>({
  required BuildContext context,
  required String title,
  required List<(Value, String)> valueNamePairs,
  Value? currentValue,
  IconData? icon,
}) async => showDialog<Value>(
  context: context,
  builder: (context) => RootPage(
    DialogPaths.editUserProfile,
    CustomAlertDialog.sync(
      clipBehavior: Clip.hardEdge,
      contentPadding: .zero,
      title: icon == null ? Text(title) : AppDialogTitle(icon: icon, title: title),
      content: Column(
        children: valueNamePairs
            .map(
              (v) => SelectableListTile(
                selected: currentValue == v.$1,
                title: Text(v.$2),
                onTap: () => context.pop(v.$1),
              ),
            )
            .toList(),
      ),
    ),
  ),
);

/// Show a dialog provides a text field waiting for input.
///
/// * [title] is the title of dialog.
/// * [initialText] is the initial text of text field.
/// * [onValueUpdated] is the callback invoked when dialog is saved (value updated).
/// * [validator] is an optional validator of the text input.
Future<String?> _showTextFieldDialog({
  required BuildContext context,
  required eup.UserProfile profile,
  required String title,
  required String initialText,
  required eup.UserProfile Function(eup.UserProfile, String) onValueUpdated,
  FormFieldValidator<String>? validator,
  TextInputType? keyboardType,
  List<TextInputFormatter>? inputFormatters,
  InputDecoration? inputDecoration,
  int? maxLines,
  int? minLines,
  IconData? icon,
}) async => showDialog<String>(
  context: context,
  builder: (context) => RootPage(
    DialogPaths.editUserProfile,
    _TextFieldDialog(
      profile: profile,
      title: title,
      icon: icon,
      initialText: initialText,
      onValueUpdated: onValueUpdated,
      validator: validator,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      inputDecoration: inputDecoration,
      maxLines: maxLines,
      minLines: minLines,
    ),
  ),
);

class _TextFieldDialog extends StatefulWidget {
  const _TextFieldDialog({
    required this.profile,
    required this.title,
    required this.initialText,
    required this.onValueUpdated,
    this.icon,
    this.validator,
    this.keyboardType,
    this.inputFormatters,
    this.inputDecoration,
    this.maxLines,
    this.minLines,
  });

  /// The original profile.
  final eup.UserProfile profile;

  /// Dialog title.
  final String title;

  /// Icon of the field, shown in the title.
  final IconData? icon;

  /// Initial text.
  final String initialText;

  /// Callback to invoke when dialog is closed and text updated.
  final eup.UserProfile Function(eup.UserProfile, String) onValueUpdated;

  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final InputDecoration? inputDecoration;
  final int? maxLines;
  final int? minLines;

  /// Optional validator of text.
  final FormFieldValidator<String>? validator;

  @override
  State<_TextFieldDialog> createState() => _TextFieldDialogState();
}

class _TextFieldDialogState extends State<_TextFieldDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomAlertDialog.sync(
      clipBehavior: Clip.hardEdge,
      title: widget.icon == null ? Text(widget.title) : AppDialogTitle(icon: widget.icon!, title: widget.title),
      content: Form(
        key: formKey,
        child: Padding(
          padding: edgeInsetsT4,
          child: TextFormField(
            autofocus: true,
            controller: controller,
            validator: widget.validator,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.inputFormatters,
            // Filled and rounded like the other forms; a caller's decoration still wins.
            decoration: widget.inputDecoration ?? appFieldDecoration(),
            maxLines: widget.maxLines,
            minLines: widget.minLines,
          ),
        ),
      ),
      actions: [
        TextButton(
          child: Text(context.t.general.cancel),
          onPressed: () => Navigator.of(context).pop(),
        ),
        FilledButton(
          child: Text(context.t.general.ok),
          onPressed: () async {
            // Validate
            if (formKey.currentState == null || !(formKey.currentState!).validate()) {
              return;
            }
            Navigator.of(context).pop(controller.text);
          },
        ),
      ],
    );
  }
}

/// Data class to pass birthday related info for editing.
final class _BirthdayInfo {
  const _BirthdayInfo({
    required this.year,
    required this.month,
    required this.day,
    required this.availableYears,
  });

  final int? year;
  final int? month;
  final int? day;
  final List<int> availableYears;
}

/// Data class to pass web page style info for editing.
final class _PageStyleInfo {
  const _PageStyleInfo(this.style, this.availableStyles);

  final eup.PageStyle? style;
  final List<eup.PageStyle> availableStyles;
}

/// Data class to pass time zone info for editing.
final class _TimeZoneInfo {
  const _TimeZoneInfo(this.timeZone, this.availableTimeZones);

  final eup.TimeZone? timeZone;
  final List<eup.TimeZone> availableTimeZones;
}
