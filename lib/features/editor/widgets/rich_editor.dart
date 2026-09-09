import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/editor/utils/mention_trigger.dart';
import 'package:tsdm_client/features/editor/widgets/color_bottom_sheet.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_bottom_sheet.dart';
import 'package:tsdm_client/features/editor/widgets/image_dialog.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/editor/widgets/url_dialog.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Wrapped bbcode editor.
///
/// Besides the picker callbacks, an editable editor with a focus node gets the typed `@` trigger: typing `@` at the
/// start of the text or after whitespace opens the mention picker sheet, see [MentionTrigger].
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

  @override
  void initState() {
    super.initState();
    _attachTrigger();
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
    super.dispose();
  }

  void _attachTrigger() {
    _trigger?.dispose();
    _trigger = null;
    final focusNode = widget.editorFocusNode;
    if (widget.controller.readOnly || focusNode == null) {
      return;
    }
    _trigger = MentionTrigger(controller: widget.controller, focusNode: focusNode, pick: _pickMention)..attach();
  }

  /// Open the picker for the typed `@`, and give the focus (and the keyboard) back to the editor afterwards.
  Future<String?> _pickMention(int atOffset) async {
    final name = await showMentionPicker(context);
    if (mounted) {
      widget.editorFocusNode?.requestFocus();
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
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
