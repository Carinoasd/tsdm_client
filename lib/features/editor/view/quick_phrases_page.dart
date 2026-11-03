import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/editor/utils/quick_phrases.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

class _Phrase {
  const _Phrase(this.id, this.text);

  /// Told apart from the same text twice in the list.
  final int id;
  final String text;
}

/// Page to arrange the quick phrases of the editors: add, edit, drag to sort, swipe to delete.
class QuickPhrasesPage extends StatefulWidget {
  /// Constructor.
  const QuickPhrasesPage({super.key});

  @override
  State<QuickPhrasesPage> createState() => _QuickPhrasesPageState();
}

class _QuickPhrasesPageState extends State<QuickPhrasesPage> {
  late final SettingsBloc _settings = context.read<SettingsBloc>();
  var _nextId = 0;
  late List<_Phrase> _phrases = [
    for (final text in decodeQuickPhrases(_settings.state.settingsMap.editorQuickPhrases)) _Phrase(_nextId++, text),
  ];

  void _save() => _settings.add(
    SettingsValueChanged<String>(
      SettingsKeys.editorQuickPhrases,
      encodeQuickPhrases([for (final e in _phrases) e.text]),
    ),
  );

  void _apply(List<_Phrase> phrases) {
    setState(() => _phrases = phrases);
    _save();
  }

  Future<void> _add() async {
    if (_phrases.length >= quickPhraseMaxCount) {
      showSnackBar(
        context: context,
        message: context.t.bbcodeEditor.quickPhrases.full(count: quickPhraseMaxCount),
      );
      return;
    }
    final text = await _edit(null);
    if (text != null) {
      _apply([..._phrases, _Phrase(_nextId++, text)]);
    }
  }

  Future<void> _change(int index) async {
    final text = await _edit(_phrases[index].text);
    if (text != null) {
      _apply([..._phrases]..[index] = _Phrase(_phrases[index].id, text));
    }
  }

  Future<String?> _edit(String? initial) => showDialog<String>(
    context: context,
    builder: (_) => _PhraseDialog(initial: initial),
  );

  void _delete(int index) {
    final removed = _phrases[index];
    _apply([..._phrases]..removeAt(index));
    showSnackBar(
      context: context,
      message: context.t.bbcodeEditor.quickPhrases.deleted,
      clearPrevious: true,
      action: SnackBarAction(
        label: context.t.bbcodeEditor.quickPhrases.undo,
        onPressed: () {
          if (mounted && _phrases.length < quickPhraseMaxCount) {
            _apply([..._phrases]..insert(index.clamp(0, _phrases.length), removed));
          }
        },
      ),
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target == oldIndex) {
      return;
    }
    final phrases = [..._phrases];
    phrases.insert(target, phrases.removeAt(oldIndex));
    _apply(phrases);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.quickPhrases;
    final colorScheme = Theme.of(context).colorScheme;

    final Widget body;
    if (_phrases.isEmpty) {
      body = AppStateView(icon: Icons.format_quote_outlined, message: tr.empty);
    } else {
      body = AppCenteredList(
        builder: (context, horizontal, width) => ReorderableListView.builder(
          key: const ValueKey('quick-phrases-list'),
          padding: horizontal + edgeInsetsT12 + context.safePadding() + const EdgeInsets.only(bottom: 72),
          itemCount: _phrases.length,
          buildDefaultDragHandles: false,
          onReorder: _reorder,
          itemBuilder: (context, index) {
            final phrase = _phrases[index];
            return Padding(
              key: ValueKey('quick-phrase-${phrase.id}'),
              padding: const EdgeInsets.only(bottom: appSurfaceGapCompact),
              child: Dismissible(
                key: ValueKey('quick-phrase-dismiss-${phrase.id}'),
                direction: DismissDirection.endToStart,
                onDismissed: (_) => _delete(_phrases.indexWhere((e) => e.id == phrase.id)),
                background: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: edgeInsetsL16R16,
                      child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
                    ),
                  ),
                ),
                child: AppSurface(
                  onTap: () async => _change(_phrases.indexWhere((e) => e.id == phrase.id)),
                  child: Row(
                    children: [
                      Expanded(child: Text(phrase.text, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      sizedBoxW12H12,
                      ReorderableDragStartListener(
                        key: ValueKey('quick-phrase-handle-${phrase.id}'),
                        index: index,
                        child: Icon(Icons.drag_handle_outlined, color: colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: SafeArea(bottom: false, top: false, child: body),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('quick-phrases-add'),
        tooltip: tr.add,
        onPressed: _add,
        child: const Icon(Icons.add_outlined),
      ),
    );
  }
}

class _PhraseDialog extends StatefulWidget {
  const _PhraseDialog({this.initial});

  final String? initial;

  @override
  State<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends State<_PhraseDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial ?? '')
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.quickPhrases;
    return AlertDialog(
      title: Text(widget.initial == null ? tr.add : tr.edit),
      scrollable: true,
      content: TextField(
        key: const ValueKey('quick-phrase-field'),
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        maxLength: quickPhraseMaxLength,
        keyboardType: TextInputType.multiline,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(
          key: const ValueKey('quick-phrase-ok'),
          onPressed: _controller.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_controller.text),
          child: Text(context.t.general.ok),
        ),
      ],
    );
  }
}
