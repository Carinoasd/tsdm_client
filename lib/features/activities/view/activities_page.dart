import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/activities/models/forum_activity.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/retry_button.dart';
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
      final uh.Document document;
      if (widget.loadDocument case final loader?) {
        document = await loader();
      } else {
        final result = await context.read<ForumHomeRepository>().fetchHomePage(force: true).run();
        document = switch (result) {
          Right(:final value) => value,
          Left(:final value) => throw value,
        };
      }
      if (!mounted) return;
      setState(() {
        _activities = parseForumActivities(document);
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
      body: _loading
          ? const CenteredCircularIndicator()
          : _failed
          ? buildRetryButton(context, _load, message: context.t.general.failedToLoad)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  Padding(padding: const EdgeInsets.all(12), child: Text(tr.description)),
                  if (_activities.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(tr.empty)),
                  for (final activity in _activities)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.event_outlined),
                        title: Text(activity.title),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async => context.dispatchAsUrl(activity.url),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
