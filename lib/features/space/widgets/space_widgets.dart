import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// A small icon with a number beside it: the reads, the comments, the pictures.
class SpaceCount extends StatelessWidget {
  /// Constructor.
  const SpaceCount(this.icon, this.count, {super.key});

  /// What is counted.
  final IconData icon;

  /// How many.
  final int count;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: style?.color),
        const SizedBox(width: 2),
        Text('$count', style: style),
      ],
    );
  }
}

/// A blog of a blog list: its title, the beginning of it, when, its category, reads and comments; who may read it on
/// the author's own list.
class SpaceBlogCard extends StatelessWidget {
  /// Constructor.
  const SpaceBlogCard(this.blog, {super.key});

  /// The blog.
  final SpaceBlog blog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline);
    return AppSurface(
      onTap: () async => context.pushNamed(
        ScreenPaths.spaceBlog,
        queryParameters: {'uid': '${blog.uid}', 'blogId': '${blog.blogId}', 'title': blog.title},
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  blog.title,
                  style: theme.textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (blog.privacy != null) ...[
                sizedBoxW8H8,
                Tooltip(
                  message: blog.privacy,
                  child: Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.outline),
                ),
              ],
            ],
          ),
          if (blog.summary != null) ...[
            sizedBoxW4H4,
            Text(
              context.displayText(blog.summary!),
              style: theme.textTheme.bodyMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          sizedBoxW8H8,
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (blog.time != null) Text(blog.time!, style: outline),
              if (blog.category != null) Text(blog.category!, style: outline),
              if (blog.views != null) SpaceCount(Icons.visibility_outlined, blog.views!),
              if (blog.replies != null) SpaceCount(Icons.chat_bubble_outline, blog.replies!),
            ],
          ),
        ],
      ),
    );
  }
}

/// An album of an album list: its cover, name and number of pictures.
class SpaceAlbumTile extends StatelessWidget {
  /// Constructor.
  const SpaceAlbumTile(this.album, {super.key});

  /// The album.
  final SpaceAlbum album;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSurface(
      padding: EdgeInsets.zero,
      onTap: () async => context.pushNamed(
        ScreenPaths.spaceAlbum,
        queryParameters: {'uid': '${album.uid}', 'albumId': '${album.albumId}', 'name': album.name},
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ColoredBox(
              color: theme.colorScheme.surfaceContainerHighest,
              child: album.coverUrl == null
                  ? Icon(Icons.photo_library_outlined, size: 40, color: theme.colorScheme.outline)
                  : NetworkIndicatorImage(album.coverUrl!, fit: BoxFit.cover),
            ),
          ),
          Padding(
            padding: edgeInsetsL12T4R12B4.copyWith(top: 8, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    album.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (album.count != null) SpaceCount(Icons.photo_outlined, album.count!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A comment under a blog or a message on a wall: who, when, and the comment as the forum rendered it.
class SpaceBlogCommentTile extends StatelessWidget {
  /// Constructor.
  const SpaceBlogCommentTile(this.comment, {this.trailing, super.key});

  /// The comment.
  final SpaceBlogComment comment;

  /// At the end of the line of the author: the actions on the comment.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uid = comment.uid;
    final avatar = CircleAvatar(
      radius: 18,
      backgroundImage: comment.avatarUrl == null ? null : CachedImageProvider(comment.avatarUrl!),
      child: comment.avatarUrl == null ? Text(comment.author.isEmpty ? '?' : comment.author.characters.first) : null,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (uid == null)
          avatar
        else
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '$uid'}),
            child: avatar,
          ),
        sizedBoxW12H12,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.author,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (comment.time != null) ...[
                          sizedBoxW8H8,
                          Text(
                            comment.time!,
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              sizedBoxW4H4,
              munchElement(context, comment.message),
            ],
          ),
        ),
      ],
    );
  }
}
