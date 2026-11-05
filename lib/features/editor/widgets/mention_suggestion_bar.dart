import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggester.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// Who the editors below can suggest for a typed `@`: the authors of the thread being read.
///
/// The thread page puts it above its scaffold, so the reply bar (a bottom sheet of that scaffold) and the editor it
/// grows into see it; the post editor opened from a floor gets the list through its route. Editors without it (chat,
/// a new thread) suggest nobody.
class MentionSuggestionsScope extends InheritedWidget {
  /// Constructor.
  const MentionSuggestionsScope({required this.suggestions, required super.child, super.key});

  /// The authors, in order of appearance, without the account in use.
  final List<MentionSuggestion> suggestions;

  /// The suggestions of the nearest scope, null without one.
  static List<MentionSuggestion>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MentionSuggestionsScope>()?.suggestions;

  @override
  bool updateShouldNotify(MentionSuggestionsScope oldWidget) => !listEquals(suggestions, oldWidget.suggestions);
}

/// The suggestions of a [MentionSuggester] as a list to tap, over the editor like the candidate row of a keyboard.
///
/// Nothing while the bar is closed. Lays out at most [maxRows] rows, scrolling the rest; the caller sizes it.
class MentionSuggestionBar extends StatelessWidget {
  /// Constructor.
  const MentionSuggestionBar({required this.suggester, this.maxRows = 4, super.key});

  /// What to show and where a pick goes.
  final MentionSuggester suggester;

  /// Rows shown at most before the list scrolls.
  final int maxRows;

  /// Height of one row.
  static const rowHeight = 44.0;

  /// Radius of the avatar in a row.
  static const _avatarRadius = 14.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: suggester,
      builder: (context, _) {
        final visible = suggester.visible;
        if (visible.isEmpty) {
          return const SizedBox.shrink();
        }
        // Taps on the bar are not taps outside the editor: the focus (and the keyboard) stay.
        return TextFieldTapRegion(
          child: Material(
            color: colorScheme.surfaceContainerHigh,
            elevation: 3,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(appInnerRadius),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: rowHeight * maxRows + 8),
              child: ListView.builder(
                shrinkWrap: true,
                padding: edgeInsetsT4B4,
                itemCount: visible.length,
                itemExtent: rowHeight,
                itemBuilder: (context, index) => _row(context, visible[index]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, MentionSuggestion suggestion) {
    final avatarUrl = suggestion.avatarUrl;
    return InkWell(
      key: ValueKey('mention-suggestion-${suggestion.username}'),
      onTap: () => suggester.pick(suggestion),
      child: Padding(
        padding: edgeInsetsL12R12,
        child: Row(
          children: [
            if (avatarUrl != null)
              HeroUserAvatar(
                username: suggestion.username,
                avatarUrl: avatarUrl,
                minRadius: _avatarRadius,
                maxRadius: _avatarRadius,
                disableHero: true,
              )
            else
              const CircleAvatar(radius: _avatarRadius, child: Icon(Icons.person_outline, size: 16)),
            sizedBoxW12H12,
            Expanded(
              child: Text(
                suggestion.username,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
