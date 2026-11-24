import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/activities/models/forum_activity.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:universal_html/html.dart' as uh;

/// The homepage's published activity links, in their original order.
class ActivitiesPage extends StatefulWidget {
  /// [loadDocument] permits deterministic tests without network access.
  const ActivitiesPage({super.key, this.loadDocument});

  /// Optional document loader. Production uses the shared homepage repository.
  final Future<uh.Document> Function()? loadDocument;

  @override
  State<ActivitiesPage> createState() => _ActivitiesPageState();
}

class _ActivitiesPageState extends State<ActivitiesPage> {
  List<ForumActivity> _activities = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final List<ForumActivity> activities;
      if (widget.loadDocument case final loader?) {
        activities = parseForumActivities(await loader());
      } else {
        // The shared homepage: the web page parsed as before, or the structured answer of the forum's app API
        // (plugin 2.3.0), whose description of 活动专区 holds the same links since plugin 2.8.2.
        final repository = context.read<ForumHomeRepository>();
        final result = await repository.fetchHomePage(force: true).run();
        activities = switch (result) {
          Right(value: ForumHomeWebPage(:final document)) => parseForumActivities(document),
          Right(value: final ForumHomeApiPage page) => await _activitiesOf(repository, page),
          Left(:final value) => throw value,
        };
      }
      if (!mounted) return;
      setState(() {
        _activities = activities;
        _loading = false;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// The activities of the structured homepage [page]. An older plugin (2.3.0 to 2.8.1) gives the description of
  /// 活动专区 as plain text ([activitiesNeedDocument]): the page is asked once more with its document, in the
  /// background as the "我收藏的版块" panel is ([ForumHomeRepository.fetchPageDocument]), and the links read from it;
  /// a failure of that request is a failed load.
  static Future<List<ForumActivity>> _activitiesOf(ForumHomeRepository repository, ForumHomeApiPage page) async {
    if (!activitiesNeedDocument(page.json)) {
      return parseForumActivitiesFromApi(page.json);
    }
    final full = await repository.fetchPageDocument(page);
    if (full == null) {
      throw HttpRequestFailedException(null);
    }
    return parseForumActivitiesFromApi(full.json);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.activitiesPage;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            tooltip: tr.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            tooltip: tr.openForum,
            icon: const Icon(Icons.open_in_browser_outlined),
            onPressed: () async => context.dispatchAsUrl(homePage, external: true),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const CenteredCircularIndicator()
            : _failed
            ? buildRetryButton(context, _load, message: context.t.general.failedToLoad)
            : RefreshIndicator(
                onRefresh: _load,
                child: AppCenteredList(
                  builder: (context, padding, width) {
                    final columns = appColumnsFor(width);
                    final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
                    final colorScheme = Theme.of(context).colorScheme;
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: padding.copyWith(top: 12, bottom: 12),
                      children: [
                        AppSurface(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const AppIconTile(Icons.celebration_outlined, size: 36),
                              sizedBoxW12H12,
                              Expanded(
                                child: Text(
                                  tr.description,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: gap),
                        if (_activities.isEmpty)
                          AppStateView(icon: Icons.event_busy_outlined, message: tr.empty, scrollable: false),
                        for (var row = 0; row < appRowCount(_activities.length, columns); row++)
                          Padding(
                            padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                            child: AppColumnsRow(
                              row: row,
                              columns: columns,
                              count: _activities.length,
                              gap: gap,
                              itemBuilder: (context, index) {
                                final activity = _activities[index];
                                return AppSurface(
                                  onTap: () async => context.dispatchAsUrl(activity.url),
                                  child: Row(
                                    children: [
                                      const AppIconTile(Icons.event_outlined),
                                      sizedBoxW12H12,
                                      Expanded(
                                        child: Text(
                                          activity.title,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      sizedBoxW8H8,
                                      Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
      ),
    );
  }
}
