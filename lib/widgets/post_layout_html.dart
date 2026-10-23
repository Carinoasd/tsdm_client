import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:universal_html/html.dart' as uh;

/// The html [element] from outside a post laid out for reading as a post's content is: the line height and the
/// paragraphs of the reader's setting ([PostTypography]), for long text written like a post (the rules of a forum, a
/// self introduction). Before, they were in the body text: tight lines, nothing between paragraphs, a wall of text the
/// posts no longer are.
///
/// Only the layout is a post's: the html is not a post's content otherwise ([PostTypographyScope.postContent]), the
/// forum's style sheet for posts, the underlines of its links and the player of its video stay out.
class PostLayoutHtml extends StatelessWidget {
  /// Constructor.
  const PostLayoutHtml(this.element, {this.typography, super.key});

  /// The html.
  final uh.Element element;

  /// The layout, the reader's setting ([SettingsBloc]) when null.
  final PostTypography? typography;

  @override
  Widget build(BuildContext context) {
    final typography =
        this.typography ?? context.select<SettingsBloc, PostTypography>((e) => e.state.settingsMap.postTypography);
    return PostTypographyScope(
      // The lines are about as long as a floor's: what a short line and a long paragraph are depends on it.
      typography: typography.withLineWidth(postContentLineWidth(context)),
      postContent: false,
      child: Builder(builder: (context) => munchElement(context, element)),
    );
  }
}
