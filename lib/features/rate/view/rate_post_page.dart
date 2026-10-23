import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/rate/bloc/rate_bloc.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// What the rate page says it rates: the post of [username] at [floor], or without the floor when its number is not
/// known (`0`, a hot reply whose floor the forum does not tell).
String ratePostDescription(Translations t, {required String username, required String floor}) =>
    (int.tryParse(floor) ?? 0) > 0
    ? t.ratePostPage.description(username: username, floor: floor)
    : t.ratePostPage.descriptionNoFloor(username: username);

/// Page to rate a post in thread.
class RatePostPage extends StatefulWidget {
  /// Constructor.
  const RatePostPage({
    required this.username,
    required this.pid,
    required this.floor,
    required this.rateAction,
    super.key,
  });

  /// Username.
  final String username;

  /// Post id.
  final String pid;

  /// Post floor; `0` when not known (a hot reply whose floor the forum does not tell).
  final String floor;

  /// Url to do the rate action.
  final String rateAction;

  @override
  State<RatePostPage> createState() => _RatePostPageState();
}

class _RatePostPageState extends State<RatePostPage> with LoggerMixin {
  final formKey = GlobalKey<FormState>();

  /// Key in [scoreMap] may be the name attribute "威望" or id of attribute `score1` and the attribute name may
  /// surrounded by spaces like " 威望".
  ///
  /// To get the human readable name of score, check with the name of `scoreList` in `state`.
  Map<String, TextEditingController>? scoreMap;
  final reasonController = TextEditingController();

  /// Config to notice author about the rate action.
  ///
  /// Defaults to true: the author was always notified before the switch took effect. The X5 web page leaves the
  /// checkbox unchecked unless the user group forces it.
  /// This is also a part of rate action post form: sent as `sendreasonpm=on` only when on, see [_rate].
  bool noticeAuthor = true;

  Widget _buildScoreWidget(BuildContext context, RateWindowScore score) {
    final tr = context.t.ratePostPage;
    return TextFormField(
      controller: scoreMap![score.id],
      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
      decoration: InputDecoration(
        labelText: score.name,
        helperText: tr.scoreTodayRemaining(score: score.remaining),
        helperStyle: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.secondary),
        suffixText: '${score.allowedRangeDescription} ',
        suffixStyle: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
      ),
      validator: (v) {
        if (v?.contains('.') ?? true) {
          return tr.onlyAllowIntegers;
        }
        final vv = v!.trim().parseToInt();
        if (vv == null) {
          return tr.invalidNumber;
        }
        if ((score.min, score.max) case (final int min, final int max)) {
          // The range and today's remaining of the forum's app API: what the forum checks again when the rate is
          // sent (thread_rate_range_invalid, thread_rate_ctrl); 0 rates nothing with this score.
          if (vv != 0 && (vv < min || vv > max)) {
            return tr.notInAllowedRange(range: score.allowedRangeDescription);
          }
          final left = score.todayLeft;
          if (vv != 0 && left != null && vv.abs() > left) {
            return tr.overTodayRemaining(score: score.remaining);
          }
          return null;
        }
        final allowedList = score.allowedRangeDescription.split('~');
        final allowedMinValue = allowedList.firstOrNull?.trim().parseToInt();
        final allowedMaxValue = allowedList.lastOrNull?.trim().parseToInt();
        if (allowedMinValue == null || allowedMaxValue == null) {
          return tr.unknownAllowedRange(range: score.allowedRangeDescription);
        }
        if (vv < allowedMinValue || vv > allowedMaxValue) {
          return tr.notInAllowedRange(range: score.allowedRangeDescription);
        }
        return null;
      },
    );
  }

  Future<void> _rate(BuildContext context, RateWindowInfo info) async {
    if (formKey.currentState == null || !(formKey.currentState!).validate()) {
      error('rate post page validate failed');
      return;
    }
    final pid = info.pid;
    final scores = <String, String>{};
    for (final e in scoreMap!.entries) {
      // "0" should make an empty value.
      final v = '${e.value.text.parseToInt()}';
      scores[e.key] = v == '0' ? '' : v;
    }
    final body = info.body(scores: scores, reason: reasonController.text, noticeAuthor: noticeAuthor);
    debug('going to rate pid=$pid with ${body.length} fields');

    context.read<RateBloc>().add(RateRateRequested(body));
  }

  Widget _buildBody(BuildContext context, RateState state) {
    final tr = context.t.ratePostPage;

    if (state.status == RateStatus.gotInfo && scoreMap == null) {
      scoreMap = Map.fromEntries(state.info!.scoreList.map((e) => MapEntry(e.id, TextEditingController(text: '0'))));
      // The form of the forum's app API starts the switch as served (the site's ratenotify plugin checks it, as on
      // the website); the window parsed from the web page keeps the app's default.
      if (state.info!.isFromApi) {
        noticeAuthor = state.info!.noticeAuthorPreset;
      }
    }

    if (state.status == RateStatus.initial || state.status == RateStatus.fetchingInfo) {
      return const CenteredCircularIndicator();
    }

    if (state.status == RateStatus.failed) {
      return const CenteredCircularIndicator();
    }

    final scoreWidgetList = state.info!.scoreList.map((e) => _buildScoreWidget(context, e)).toList();

    Widget? defaultReasonButton;
    if (state.info?.defaultReasonList.isNotEmpty ?? false) {
      defaultReasonButton = Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: IconButton(
          icon: const Icon(Icons.arrow_drop_down_outlined),
          onPressed: () async => showDialog(
            context: context,
            builder: (_) => RootPage(
              DialogPaths.selectRateReason,
              CustomAlertDialog.sync(
                title: Text(tr.reason),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: state.info!.defaultReasonList
                      .map(
                        (e) => ListTile(
                          leading: Icon(
                            e == reasonController.text ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                            color: e == reasonController.text ? Theme.of(context).colorScheme.primary : null,
                          ),
                          title: Text(e),
                          onTap: () {
                            context.pop();
                            setState(() {
                              reasonController.text = e;
                            });
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: AppCenteredList(
              maxWidth: appFormMaxWidth,
              // Not a lazy list: every score field stays built, so the form validates all of them.
              builder: (context, horizontal, width) => SingleChildScrollView(
                padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Body title: whom and which floor is rated.
                    AppSurface(
                      child: Row(
                        children: [
                          const AppIconTile(Icons.star_rate_outlined),
                          sizedBoxW12H12,
                          Expanded(
                            child: Text(
                              ratePostDescription(context.t, username: widget.username, floor: widget.floor),
                              style: Theme.of(
                                context,
                              ).textTheme.titleMedium?.copyWith(color: colorScheme.secondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    appListSeparator,
                    AppFormSection(
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            // Score fields carry a helper and a range: one per row on phones, more on wide windows
                            // and fewer again with large text. Heights follow the content, errors are never clipped.
                            final fit = (constraints.maxWidth / MediaQuery.textScalerOf(context).scale(220)).floor();
                            final perRow = fit < 1 ? 1 : (fit > 3 ? 3 : fit);
                            final fieldWidth = (constraints.maxWidth - 12 * (perRow - 1)) / perRow;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final field in scoreWidgetList) SizedBox(width: fieldWidth, child: field),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                    appListSeparator,
                    if (state.info!.selfDeduct) ...[
                      // The website says so above the form: the scores come off the rater's own credits.
                      AppNoticeBanner(message: tr.selfDeduct),
                      appListSeparator,
                    ],
                    AppFormSection(
                      gap: 4,
                      children: [
                        TextFormField(
                          controller: reasonController,
                          decoration: InputDecoration(labelText: tr.reason, suffixIcon: defaultReasonButton),
                        ),
                        // A form of the forum's app API without the checkbox: the website offers no choice either.
                        if (!state.info!.isFromApi || state.info!.noticeAuthorName != null)
                          SectionSwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: noticeAuthor || state.info!.noticeAuthorForced,
                            title: Text(tr.noticeAuthor),
                            subtitle: state.info!.noticeAuthorForced ? Text(tr.noticeAuthorForced) : null,
                            onChanged: state.info!.noticeAuthorForced
                                ? null
                                : (value) {
                                    setState(() {
                                      noticeAuthor = value;
                                    });
                                  },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Submit stays reachable above the keyboard; a refused rate shows the forum's reason right above it.
          AppBottomActionBar(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.status == RateStatus.rateFailed) ...[
                  AppNoticeBanner(tone: AppNoticeTone.error, message: state.failedReason ?? tr.failedToRate),
                  sizedBoxW8H8,
                ] else if (state.justRated) ...[
                  // Rated, and the form is still here for the next one; above the button, never over it.
                  AppNoticeBanner(message: tr.success),
                  sizedBoxW8H8,
                ],
                DebounceFilledButton(
                  shouldDebounce: state.status.isLoading(),
                  onPressed: () async => _rate(context, state.info!),
                  child: Text(tr.title),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> chooseTemplate(RateState state) async {
    final scoreList = state.info?.scoreList;
    if (scoreList == null) {
      return;
    }

    final pickResult = await context.pushNamed<FastRateTemplateModel>(
      ScreenPaths.fastRateTemplate,
      pathParameters: {'pick': 'true'},
    );
    if (pickResult == null || !context.mounted) {
      return;
    }

    // Flag indicating the first special attribute is used or not.
    // Target at the second special attribute when the first one is used and another unknown
    // name attribute occurs.
    var specialAttrUsed = false;

    // Score in `scoreMap` may have score id as key (score1) or score name as key ("威望").
    // Here we check the correct attribute name with cached score info in `state.scoreList`.
    for (final scoreEntry in scoreMap!.entries) {
      final target = scoreList.firstWhereOrNull((e) => e.id == scoreEntry.key);
      if (target == null) {
        error('unknown attr name ${scoreEntry.key} when choosing rate template');
        continue;
      }
      // Don't forget to trim the target score name.
      switch (target.name.trim()) {
        case '威望':
          scoreEntry.value.text = '${pickResult.ww}';
        case '天使币':
          scoreEntry.value.text = '${pickResult.tsb}';
        case '宣传':
          scoreEntry.value.text = '${pickResult.xc}';
        case '天然':
          scoreEntry.value.text = '${pickResult.tr}';
        case '腹黑':
          scoreEntry.value.text = '${pickResult.fh}';
        case '精灵':
          scoreEntry.value.text = '${pickResult.jl}';
        default:
          {
            if (specialAttrUsed) {
              scoreEntry.value.text = '${pickResult.special2}';
            } else {
              scoreEntry.value.text = '${pickResult.special}';
              specialAttrUsed = true;
            }
          }
      }
    }
  }

  @override
  void dispose() {
    reasonController.dispose();
    if (scoreMap != null) {
      for (final e in scoreMap!.entries) {
        e.value.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.ratePostPage;

    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => RateRepository()),
        BlocProvider(
          create: (context) =>
              RateBloc(rateRepository: context.repo())
                ..add(RateFetchInfoRequested(pid: widget.pid, rateAction: widget.rateAction)),
        ),
      ],
      child: BlocListener<RateBloc, RateState>(
        listener: (context, state) {
          // A refused rate (RateStatus.rateFailed) keeps the form and shows the reason above the submit button.
          if (state.status == RateStatus.failed) {
            // Failed to load the rate info: show reason and pop back if we should not retry.
            showSnackBar(context: context, message: state.failedReason ?? tr.failedToRate);
            if (state.shouldRetry == false) {
              // With a kept window the form is usable before the forum answered: the reason dialog or the template
              // page may be open above this page, and popping only them would leave this page behind, loading forever.
              final route = ModalRoute.of(context);
              if (route != null && !route.isCurrent) {
                Navigator.of(context).popUntil((r) => r == route);
              }
              Navigator.of(context).pop();
              return;
            }
            context.read<RateBloc>().add(RateFetchInfoRequested(pid: widget.pid, rateAction: widget.rateAction));
          }
          // An accepted rate keeps the page: the same floor may get another rate right away (RateState.justRated).
        },
        child: BlocBuilder<RateBloc, RateState>(
          builder: (context, state) {
            return Scaffold(
              appBar: AppBar(
                title: Text(tr.title),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.star_rate_outlined),
                    tooltip: context.t.fastRateTemplate.title,
                    onPressed: state.status == RateStatus.fetchingInfo || state.status == RateStatus.rating
                        ? null
                        : () => chooseTemplate(state),
                  ),
                ],
              ),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            );
          },
        ),
      ),
    );
  }
}
