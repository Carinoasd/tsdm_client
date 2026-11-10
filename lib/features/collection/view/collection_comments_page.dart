import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/features/collection/widgets/collection_dialogs.dart';
import 'package:tsdm_client/features/collection/widgets/collection_pager.dart';
import 'package:tsdm_client/features/collection/widgets/collection_tiles.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';

/// The comments of collection [ctid], newest first, and the comment form: a rating (1 to 5 stars) while the account
/// has not rated it yet, and the text.
class CollectionCommentsPage extends StatefulWidget {
  /// Constructor.
  const CollectionCommentsPage({required this.ctid, this.repository, super.key});

  /// The collection.
  final int ctid;

  /// Repository override (tests).
  final CollectionRepository? repository;

  @override
  State<CollectionCommentsPage> createState() => _CollectionCommentsPageState();
}

class _CollectionCommentsPageState extends State<CollectionCommentsPage> {
  late final CollectionRepository _repository = widget.repository ?? CollectionRepository.network();
  late final _pager = CollectionPager<CollectionCommentPage, CollectionComment>(
    fetch: (page) => _repository.fetchComments(widget.ctid, page: page),
    itemsOf: (page) => page.comments,
    pagesOf: (page) => page.totalPages,
  );
  final _message = TextEditingController();
  int? _rate;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    unawaited(_pager.refresh());
  }

  @override
  void dispose() {
    _message.dispose();
    _pager.dispose();
    super.dispose();
  }

  Future<void> _send(CollectionCommentPage page) async {
    setState(() => _sending = true);
    final outcome = await _repository.comment(page, message: _message.text.trim(), rate: _rate);
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (await reportCollectionOutcome(context, outcome)) {
      collectionChanges.value++;
      _message.clear();
      _rate = null;
    }
    if (outcome is! CollectionRefused) {
      await _pager.refresh();
    }
  }

  Widget _composer(BuildContext context, CollectionCommentPage page) {
    final tr = context.t.collection;
    final mayRate = page.myRate == null;
    final canSend = !_sending && (_message.text.trim().isNotEmpty || (mayRate && _rate != null));
    return AppSurface(
      key: const ValueKey('collection-comment-form'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mayRate)
            Row(
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    key: ValueKey('collection-rate-$i'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon((_rate ?? 0) >= i ? Icons.star : Icons.star_border),
                    color: Theme.of(context).colorScheme.tertiary,
                    onPressed: _sending ? null : () => setState(() => _rate = _rate == i ? null : i),
                  ),
              ],
            )
          else if (page.myRate case final rate?)
            Row(
              children: [
                CollectionStars(rate.toDouble()),
                sizedBoxW8H8,
                Text(tr.rated(rate: rate), style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          TextField(
            key: const ValueKey('collection-comment-message'),
            controller: _message,
            enabled: !_sending,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(hintText: tr.comment),
          ),
          sizedBoxW8H8,
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              key: const ValueKey('collection-comment-send'),
              onPressed: canSend ? () async => _send(page) : null,
              child: Text(tr.comment),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) {
        final page = _pager.first;
        final Widget body;
        if (page == null) {
          body = _pager.loading || _pager.failure == null
              ? const CenteredCircularIndicator()
              : FailureView(failure: _pager.failure, onRetry: _pager.refresh);
        } else {
          final comments = _pager.items;
          final head = page.canComment ? 1 : 0;
          body = RefreshIndicator(
            onRefresh: _pager.refresh,
            child: AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: side.copyWith(top: 12, bottom: 24).add(context.safePadding()),
                itemCount: head + comments.length + 1,
                separatorBuilder: (_, _) => appListSeparator,
                itemBuilder: (context, index) {
                  if (index < head) {
                    return _composer(context, page);
                  }
                  final i = index - head;
                  if (i < comments.length) {
                    return CollectionCommentTile(comments[i]);
                  }
                  if (comments.isEmpty) {
                    return AppStateView(
                      icon: Icons.chat_bubble_outline,
                      message: context.t.collection.noComments,
                      scrollable: false,
                    );
                  }
                  return ListFooter(
                    status: listFooterStatus(
                      hasMore: _pager.hasMore,
                      loading: _pager.loadingMore,
                      failed: _pager.moreFailed,
                    ),
                    itemCount: comments.length,
                    failure: _pager.failure,
                    onLoadMore: _pager.loadMore,
                    onRetry: _pager.loadMore,
                  );
                },
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(page?.name ?? context.t.collection.commentsTitle)),
          body: SafeArea(bottom: false, child: body),
        );
      },
    );
  }
}
