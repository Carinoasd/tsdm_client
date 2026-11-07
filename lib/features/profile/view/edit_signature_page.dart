import 'dart:async';

import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/editor/widgets/editor_frame.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/profile/bloc/edit_signature_cubit.dart';
import 'package:tsdm_client/features/profile/models/signature_form.dart';
import 'package:tsdm_client/features/profile/repository/edit_user_profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The buttons of the signature editor: the forum's own (bold, color, link, smilies, and the image when the member's
/// group allows it), with undo, redo and the clipboard.
Set<EditorFeatures> _disabledFeatures(SignatureForm form) => {
  for (final f in EditorFeatures.values)
    if (!const {
          EditorFeatures.bold,
          EditorFeatures.color,
          EditorFeatures.url,
          EditorFeatures.emoji,
          EditorFeatures.undo,
          EditorFeatures.redo,
          EditorFeatures.cut,
          EditorFeatures.copy,
          EditorFeatures.paste,
        }.contains(f) &&
        !(f == EditorFeatures.image && form.imgcode))
      f,
};

/// Page to edit the signature of the member. Pops the signature saved, if any.
class EditSignaturePage extends StatelessWidget {
  /// Constructor.
  const EditSignaturePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final cubit = EditSignatureCubit(EditUserProfileRepository());
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocConsumer<EditSignatureCubit, EditSignatureState>(
        listenWhen: (prev, curr) => prev.status == EditSignatureStatus.saving && curr.status != prev.status,
        listener: (context, state) {
          final tr = context.t.editUserProfilePage;
          if (state.status == EditSignatureStatus.saved) {
            showSnackBar(context: context, message: tr.saveSuccess);
            context.pop(state.saved);
          } else if (state.status == EditSignatureStatus.saveFailed) {
            final reason = state.reason;
            showSnackBar(
              context: context,
              message: reason == null || reason.isEmpty ? tr.saveFailed : tr.saveFailedReason(reason: reason),
            );
          }
        },
        builder: (context, state) {
          final title = Text(context.t.editUserProfilePage.signature);
          return switch ((state.status, state.form)) {
            (EditSignatureStatus.loading, _) => Scaffold(
              appBar: AppBar(title: title),
              body: const CenteredCircularIndicator(),
            ),
            (_, null) => Scaffold(
              appBar: AppBar(title: title),
              body: state.reason?.isNotEmpty ?? false
                  ? AppStateView(icon: Icons.info_outline, message: state.reason!)
                  : buildRetryButton(context, () async => context.read<EditSignatureCubit>().load()),
            ),
            (_, final SignatureForm form) => _SignatureEditor(
              form: form,
              saving: state.status == EditSignatureStatus.saving,
            ),
          };
        },
      ),
    );
  }
}

class _SignatureEditor extends StatefulWidget {
  const _SignatureEditor({required this.form, required this.saving});

  final SignatureForm form;

  final bool saving;

  @override
  State<_SignatureEditor> createState() => _SignatureEditorState();
}

class _SignatureEditorState extends State<_SignatureEditor> {
  /// The rich editor, when the member's group may use BBCode.
  BBCodeEditorController? _bbcode;

  /// The plain text editor, when it may not.
  TextEditingController? _plain;

  late final FocusNode _focusNode;

  String _value = '';

  String _read() => _bbcode?.toForumBBCode() ?? _plain?.text ?? '';

  void _onChanged() {
    final value = _read();
    if (value != _value) {
      setState(() => _value = value);
    }
  }

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    final initial = widget.form.value;
    if (widget.form.bbcode) {
      final parserEnabled = getIt.get<SettingsRepository>().currentSettings.enableEditorBBCodeParser;
      _bbcode = parserEnabled
          ? buildBBCodeEditorController(initialDelta: parseBBCodeTextToDelta(initial.isEmpty ? '\n' : initial))
          : buildBBCodeEditorController(initialText: normalizeBlockMarkerNesting(initial));
      _bbcode!.addListener(_onChanged);
    } else {
      _plain = TextEditingController(text: initial)..addListener(_onChanged);
    }
    _value = _read();
  }

  @override
  void dispose() {
    _bbcode?.dispose();
    _plain?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final form = widget.form;
    final max = form.max;
    final fits = form.fits(_value);
    final colorScheme = Theme.of(context).colorScheme;

    final editor = switch ((_bbcode, _plain)) {
      (final BBCodeEditorController c, _) => EditorFrame(
        focusNode: _focusNode,
        child: RichEditor(autoFocus: true, controller: c, editorFocusNode: _focusNode),
      ),
      (_, final TextEditingController c) => TextField(
        controller: c,
        focusNode: _focusNode,
        autofocus: true,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      _ => sizedBoxEmpty,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.editUserProfilePage.signature),
        actions: [
          IconButton(
            icon: widget.saving ? sizedCircularProgressIndicator : const Icon(Icons.cloud_upload_outlined),
            tooltip: context.t.editUserProfilePage.save,
            onPressed: widget.saving || !fits ? null : () async => context.read<EditSignatureCubit>().save(_read()),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = appCenteredPadding(constraints.maxWidth, maxWidth: appReadingMaxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(padding: horizontal.add(edgeInsetsT12), child: editor),
                ),
                if (_bbcode != null)
                  ColoredBox(
                    color: colorScheme.surfaceContainerLow,
                    child: Padding(
                      padding: horizontal.add(edgeInsetsT4),
                      child: EditorToolbar(
                        bbcodeController: _bbcode!,
                        disabledFeatures: _disabledFeatures(form),
                        editorFocusNode: _focusNode,
                      ),
                    ),
                  ),
                if (max != null)
                  Padding(
                    padding: horizontal.add(edgeInsetsT4B4),
                    child: Text(
                      '${signatureLength(_value)} / $max',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: fits ? colorScheme.outline : colorScheme.error,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
