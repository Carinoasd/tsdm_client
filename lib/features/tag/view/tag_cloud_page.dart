import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/tag/models/forum_tag.dart';
import 'package:tsdm_client/features/tag/repository/tag_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The forum's tags, a tap opens the threads of the tag.
class TagCloudPage extends StatefulWidget {
  /// Constructor.
  const TagCloudPage({this.repository, super.key});

  /// Repository override (tests); the real one is used when null.
  final TagRepository? repository;

  @override
  State<TagCloudPage> createState() => _TagCloudPageState();
}

class _TagCloudPageState extends State<TagCloudPage> {
  late final TagRepository _repository = widget.repository ?? TagRepository();
  List<ForumTag>? _tags;
  LoadFailure? _failure;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final result = await _repository.fetchCloud().run();
    if (!mounted) {
      return;
    }
    result.match(
      (e) {
        setState(() {
          _loading = false;
          _failure = LoadFailure.of(e);
        });
        // The tags on screen stay when a refresh fails; say so.
        if (_tags != null) {
          showRefreshFailedSnackBar(
            context,
            _failure,
            onRetry: () {
              // The snack bar outlives the page.
              if (mounted) {
                unawaited(_load());
              }
            },
          );
        }
      },
      (tags) => setState(() {
        _loading = false;
        _tags = tags;
      }),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _tags == null) {
      return const CenteredCircularIndicator();
    }
    final tags = _tags;
    if (tags == null) {
      return FailureView(failure: _failure, onRetry: _load);
    }
    if (tags.isEmpty) {
      return AppStateView(icon: Icons.sell_outlined, message: context.t.tagPage.empty);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: AppCenteredList(
        builder: (context, side, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  ActionChip(
                    key: ValueKey('tag-${tag.id}'),
                    label: Text(context.displayText(tag.count > 0 ? '${tag.name} ${tag.count}' : tag.name)),
                    onPressed: () async => context.dispatchAsUrl(tag.url),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t.tagPage.cloudTitle)),
      body: SafeArea(bottom: false, child: _buildBody(context)),
    );
  }
}
