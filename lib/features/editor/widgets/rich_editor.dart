import 'dart:math';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggester.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';
import 'package:tsdm_client/features/editor/utils/mention_trigger.dart';
import 'package:tsdm_client/features/editor/widgets/color_bottom_sheet.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_bottom_sheet.dart';
import 'package:tsdm_client/features/editor/widgets/image_dialog.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/editor/widgets/mention_suggestion_bar.dart';
import 'package:tsdm_client/features/editor/widgets/url_dialog.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Wrapped bbcode editor.
///
/// Besides the picker callbacks, an editable editor with a focus node gets the typed `@` trigger: typing `@` at the
/// start of the text or after whitespace opens the mention picker sheet, see [MentionTrigger]. Under a
/// [MentionSuggestionsScope] with authors to suggest (the thread page), the typed `@` shows them in a bar over the
/// editor instead, filtered by what is typed on, see [MentionSuggester]; the sheet stays a toolbar button away.
class RichEditor extends StatefulWidget {
  /// Constructor.
  const RichEditor({
    required this.controller,
    this.scrollController,
    this.editorFocusNode,
    this.autoFocus = false,
    super.key,
  });

  /// The readonly constructor.
  RichEditor.readonly({
    String? initialText,
    Delta? initialDelta,
    this.scrollController,
    this.editorFocusNode,
    this.autoFocus = false,
    super.key,
  }) : controller = buildBBCodeEditorController(readOnly: true, initialText: initialText, initialDelta: initialDelta);

  /// Editor controller.
  final BBCodeEditorController controller;

  /// Editor scroll controller.
  final ScrollController? scrollController;

  /// Editor focus.
  final FocusNode? editorFocusNode;

  /// Automatically focus the editor.
  final bool autoFocus;

  /// Width and height an emoji is rendered with.
  static const defaultEmojiWidth = 50.0;

  /// Width and height an emoji is rendered with.
  static const defaultEmojiHeight = 50.0;

  /// The maximum height of image.
  ///
  /// As noted somewhere else before:
  ///
  /// On the web side, images are rendered under a limit of maximum width,
  /// currently is 550.
  ///
  /// If the width of image:
  ///
  /// * larger than this limit, images are scalded down to the maximum width
  ///   while keeping the same width/height ratio.
  /// * smaller than this limit, images are rendered in the original width, no
  ///   matter the height of image.
  static const imageMaxWidth = 550.0;

  @override
  State<RichEditor> createState() => _RichEditorState();
}

class _RichEditorState extends State<RichEditor> {
  MentionTrigger? _trigger;
  MentionSuggester? _suggester;

  /// Who the enclosing [MentionSuggestionsScope] suggests, read in [didChangeDependencies].
  List<MentionSuggestion> _scopeSuggestions = const [];

  /// The suggestion bar lives in the overlay, following the editor; the portal is shown once and the bar itself is
  /// nothing while closed.
  final _suggestionPortal = OverlayPortalController();
  final _editorLink = LayerLink();
  final GlobalKey _editorKey = GlobalKey();

  /// Width of the bar when the editor's is not known yet.
  static const _fallbackBarWidth = 280.0;

  /// Rows of the bar at most.
  static const _barMaxRows = 4;

  @override
  void initState() {
    super.initState();
    _attachTrigger();
    _suggestionPortal.show();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here, not in build: the suggester tells its bar in the overlay about a change, which must not happen while
    // this widget builds.
    _scopeSuggestions = MentionSuggestionsScope.maybeOf(context) ?? const [];
    _suggester?.suggestions = _scopeSuggestions;
  }

  @override
  void didUpdateWidget(RichEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.editorFocusNode != widget.editorFocusNode) {
      _attachTrigger();
    }
  }

  @override
  void dispose() {
    _trigger?.dispose();
    _suggester?.dispose();
    super.dispose();
  }

  void _attachTrigger() {
    _trigger?.dispose();
    _trigger = null;
    _suggester?.dispose();
    _suggester = null;
    final focusNode = widget.editorFocusNode;
    if (widget.controller.readOnly || focusNode == null) {
      return;
    }
    _trigger = MentionTrigger(controller: widget.controller, focusNode: focusNode, pick: _pickMention)..attach();
    _suggester = MentionSuggester(controller: widget.controller, focusNode: focusNode)
      ..suggestions = _scopeSuggestions
      ..attach();
  }

  /// The editor changed size (the reply bar grew into the page, the keyboard came): the open bar follows once the
  /// layout is done.
  bool _onEditorResized(SizeChangedLayoutNotification _) {
    final suggester = _suggester;
    if (suggester != null && suggester.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          suggester.relayout();
        }
      });
    }
    return true;
  }

  /// Open the picker for the typed `@`, and give the focus (and the keyboard) back to the editor afterwards.
  ///
  /// Not when the thread's authors are suggested over the editor: the `@` stays and the bar does the completing.
  Future<String?> _pickMention(int atOffset) async {
    if (_suggester?.hasSuggestions ?? false) {
      return null;
    }
    final name = await showMentionPicker(context);
    if (mounted) {
      widget.editorFocusNode?.requestFocus();
    }
    return name;
  }

  /// The suggestion bar over the editor, as wide as the editor, above its top edge; when the editor is close to the
  /// top of the screen (the whole page is the editor), under its top edge instead. In the overlay, so the frame
  /// around the editor does not clip it.
  Widget _buildSuggestionBar(BuildContext overlayContext, MentionSuggester suggester) => ListenableBuilder(
    listenable: suggester,
    builder: (context, _) {
      // Laid out again when the screen turns or the keyboard moves the editor.
      MediaQuery.of(overlayContext);
      if (!suggester.isOpen) {
        return const SizedBox.shrink();
      }
      var width = _fallbackBarWidth;
      double? roomAbove;
      final editorBox = _editorKey.currentContext?.findRenderObject();
      if (editorBox is RenderBox && editorBox.hasSize && editorBox.attached) {
        width = editorBox.size.width;
        final overlayBox = Overlay.of(overlayContext).context.findRenderObject();
        if (overlayBox is RenderBox && overlayBox.hasSize) {
          roomAbove =
              editorBox.localToGlobal(Offset.zero, ancestor: overlayBox).dy - MediaQuery.paddingOf(overlayContext).top;
        }
      }
      const rowHeight = MentionSuggestionBar.rowHeight;
      final rowsAbove = roomAbove == null ? _barMaxRows : ((roomAbove - 8) / rowHeight).floor();
      final above = rowsAbove >= 2;
      return Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _editorLink,
          showWhenUnlinked: false,
          followerAnchor: above ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(0, above ? -4 : 4),
          child: SizedBox(
            width: width,
            child: MentionSuggestionBar(
              suggester: suggester,
              maxRows: above ? min(_barMaxRows, rowsAbove) : _barMaxRows,
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final editor = _buildEditor(context);
    final suggester = _suggester;
    if (suggester == null) {
      return editor;
    }
    return OverlayPortal(
      controller: _suggestionPortal,
      overlayChildBuilder: (overlayContext) => _buildSuggestionBar(overlayContext, suggester),
      child: CompositedTransformTarget(
        link: _editorLink,
        child: NotificationListener<SizeChangedLayoutNotification>(
          onNotification: _onEditorResized,
          child: SizeChangedLayoutNotifier(
            child: KeyedSubtree(key: _editorKey, child: editor),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    return BBCodeEditor(
      controller: widget.controller,
      focusNode: widget.editorFocusNode,
      autoFocus: widget.autoFocus,
      scrollController: widget.scrollController,
      imageProvider: (context, url, width, height) {
        // Requirements:
        //
        // 1. If width is not larger than max width, keep the original width and height.
        // 2. If width is larger than max width, set width to max width and scale height down to the same ratio.
        // 3. Width and height can not be 0 at the same time.

        final w = width?.toDouble();
        final h = height?.toDouble();
        double? maxHeight;
        if (w != null && h != null) {
          if (w == 0) {
            // Auto width, do not limit max height.
            maxHeight = h;
          } else if (w > RichEditor.imageMaxWidth && h != 0) {
            // Width too large, it will be set to max allowed width, scale down the height.
            maxHeight = h * (RichEditor.imageMaxWidth / w);
          } else if (h == 0) {
            // Auto height.
            maxHeight = double.infinity;
          } else {
            // Normal height.
            maxHeight = h;
          }
        }

        return CachedImage(
          url,
          width: (w == null || w <= 0) ? null : w,
          height: maxHeight == null ? maxHeight : null,
          maxWidth: RichEditor.imageMaxWidth,
          maxHeight: maxHeight,
        );
      },
      // Enable this constraints if needed.
      // imageConstraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
      imagePicker: (context, url, width, height) => showImagePicker(context, url: url, width: width, height: height),
      emojiProvider: (context, code) {
        // code is supposed in
        // {:${group_id}_${emoji_id}:}
        // format.
        final data = getIt.get<ImageCacheProvider>().getEmojiCacheFromRawCodeSync(code);
        if (data == null) {
          return Text(code);
        }
        return Image.memory(data, width: RichEditor.defaultEmojiWidth, height: RichEditor.defaultEmojiHeight);
      },
      usernamePicker: showMentionPicker,
      // TODO: Implement imageBuilder in editor package.
      // imageBuilder: (String url) => CachedImageProvider(url, context),
      urlLauncher: (url) async => context.dispatchAsUrl(url),
      userMentionHandler: (username) => context.dispatchAsUrl('$usernameProfilePage$username'),
      emojiPicker: (context) async => showEmojiPicker(context),
      colorPicker: (context, initialColor) async => showColorPicker(context, initialColor, PickerType.foreground),
      backgroundColorPicker: (context, initialColor) async =>
          showColorPicker(context, initialColor, PickerType.background),
      urlPicker: (context, url, description) async => showUrlPicker(context, url: url, description: description),
    );
  }
}
