import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_export.dart';
import 'package:tsdm_client/features/diagnostics/feedback.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The feedback page: what the user writes about a problem, then the diagnostics bundle with it shared, or a reply to
/// the feedback thread written with it ([FeedbackThreadOpener]).
class FeedbackPage extends StatefulWidget {
  /// Constructor.
  const FeedbackPage({this.opener, super.key});

  /// Opens the feedback thread; the app's ([FeedbackThreadOpener.of]) when null.
  final FeedbackThreadOpener? opener;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _description = TextEditingController();

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  /// Whether the thread is being opened (the login page first): a second tap meanwhile opens nothing.
  bool _opening = false;

  Future<void> _replyInThread() async {
    if (_opening) {
      return;
    }
    _opening = true;
    try {
      final opener = widget.opener ?? FeedbackThreadOpener.of(context);
      await opener.openWith(_description.text);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.diagnostics;
    return Scaffold(
      appBar: AppBar(title: Text(tr.feedback)),
      body: SafeArea(
        child: Padding(
          padding: edgeInsetsL16T16R16B16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('feedback-description'),
                  controller: _description,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
              ),
              sizedBoxW12H12,
              Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: diagnosticsExportBusy,
                      builder: (context, busy, _) => FilledButton.icon(
                        key: const ValueKey('feedback-share-bundle'),
                        icon: const Icon(Icons.ios_share_outlined),
                        label: Text(tr.shareBundle),
                        onPressed: busy
                            ? null
                            : () async => exportDiagnostics(
                                context,
                                shareOrigin: shareOriginOf(context),
                                description: _description.text,
                              ),
                      ),
                    ),
                  ),
                  sizedBoxW12H12,
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('feedback-reply-thread'),
                      icon: const Icon(Icons.forum_outlined),
                      label: Text(tr.replyFeedbackThread),
                      onPressed: _replyInThread,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
