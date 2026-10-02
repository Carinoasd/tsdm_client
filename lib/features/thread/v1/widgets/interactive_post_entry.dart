import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_html.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_viewer.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// An explicit interactive view beside the unchanged native post reader.
class InteractivePostEntry extends StatefulWidget {
  /// Constructor.
  const InteractivePostEntry({required this.data, required this.postId, super.key});

  /// Already-fetched post HTML, including its authored message subtree.
  final String data;

  /// Identity of the post being read, independent of the author and current account.
  final String postId;

  @override
  State<InteractivePostEntry> createState() => _InteractivePostEntryState();
}

class _InteractivePostEntryState extends State<InteractivePostEntry> {
  String? _html;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _html = interactivePostHtml(widget.data, postId: widget.postId);
  }

  @override
  void didUpdateWidget(InteractivePostEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data || oldWidget.postId != widget.postId) {
      _html = interactivePostHtml(widget.data, postId: widget.postId);
    }
  }

  Future<void> _open() async {
    final html = _html;
    if (_opening || html == null) return;
    // Read the active account now, so an account switch cannot reuse the former reader's local storage.
    final currentUid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
    setState(() => _opening = true);
    final result = await openInteractivePost(html: html, postId: widget.postId, currentUid: currentUid);
    if (!mounted) return;
    setState(() => _opening = false);
    final tr = context.t.postCard.interactiveHtml;
    final message = switch (result) {
      InteractivePostOpenResult.viewer => null,
      InteractivePostOpenResult.browser => tr.browserFallback,
      InteractivePostOpenResult.failed => tr.openFailed,
    };
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_html == null || interactivePostSourceUrl(widget.postId) == null) {
      return const SizedBox.shrink();
    }
    final tr = context.t.postCard.interactiveHtml;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: AppInsetBlock(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(supportsInteractivePostViewer ? tr.description : tr.browserDescription),
            sizedBoxW8H8,
            Wrap(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _opening ? null : _open,
                  icon: const Icon(Icons.touch_app_outlined),
                  label: Text(tr.open, textAlign: TextAlign.center),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
