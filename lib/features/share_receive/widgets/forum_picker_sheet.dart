import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';

/// The forums of [groups] a thread can be written in: every forum of every group in the page's order (the favorites
/// panel first, as the forum index lists it), without link forums and forums the account may not enter.
List<(ForumGroup, List<Forum>)> postableForums(List<ForumGroup> groups) => [
  for (final group in groups)
    if (group.forumList.where(_postable).toList() case final forums when forums.isNotEmpty) (group, forums),
];

bool _postable(Forum forum) => forum.forumID > 0 && forum.redirectUrl == null && !forum.isPrivate;

/// Let the user pick the forum a shared text or image is posted to: the forum id picked, null when dismissed.
Future<int?> showForumPickerSheet(BuildContext context, List<ForumGroup> groups) async {
  final sections = postableForums(groups);
  return showCustomBottomSheet<int>(
    context: context,
    title: context.t.shareReceive.pickForum,
    childrenBuilder: (context) => [
      for (final (group, forums) in sections) ...[
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 12, right: 16),
          child: Text(
            group.name,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        for (final forum in forums)
          ListTile(
            key: ValueKey('share-forum-${forum.forumID}'),
            title: Text(forum.name),
            onTap: () => Navigator.of(context).pop(forum.forumID),
          ),
      ],
    ],
  );
}
