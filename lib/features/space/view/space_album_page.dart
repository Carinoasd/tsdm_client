import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/view/image_gallery_page.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// The pictures of the album [albumId] of the member [uid], a grid of thumbnails; a picture opens in the gallery
/// with the others of the album loaded so far.
///
/// The member's own album (not the default one) offers to upload pictures to it.
class SpaceAlbumPage extends StatefulWidget {
  /// Constructor.
  const SpaceAlbumPage({required this.uid, required this.albumId, this.name, super.key});

  /// The owner.
  final int uid;

  /// The album; -1 is the default album.
  final int albumId;

  /// Its name, shown until the album loaded.
  final String? name;

  @override
  State<SpaceAlbumPage> createState() => _SpaceAlbumPageState();
}

class _SpaceAlbumPageState extends State<SpaceAlbumPage> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  late final SpaceListCubit<SpacePhoto> _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = SpaceListCubit<SpacePhoto>(
      firstPageUrl: spaceAlbumUrl(widget.uid, widget.albumId),
      fetch: const SpaceRepository().fetchAlbumPhotos,
      keyOf: (e) => e.picId,
    );
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    _refreshController.dispose();
    unawaited(_cubit.close());
    super.dispose();
  }

  Future<void> _upload() async {
    final changed = await context.pushNamed<bool>(
      ScreenPaths.spaceAlbumUpload,
      queryParameters: {'albumId': '${widget.albumId}'},
    );
    if (mounted && (changed ?? false)) unawaited(_cubit.refresh());
  }

  Future<void> _open(BuildContext context, List<SpacePhoto> photos, int index) => openImageGallery(
    context,
    [for (final e in photos) GalleryImage(e.imageUrl)],
    index,
  );

  Widget _grid(BuildContext context, SpaceListState<SpacePhoto> state) => AppCenteredList(
    builder: (context, side, width) {
      final padding = side
          .copyWith(top: 12, bottom: 12 + 72)
          .add(context.safePadding())
          .resolve(Directionality.of(context));
      if (state.items.isEmpty) {
        return ListView(
          padding: padding,
          children: [
            const SizedBox(height: 32),
            AppStateView(
              icon: Icons.photo_outlined,
              message: context.t.spacePage.emptyPhotos,
              scrollable: false,
            ),
          ],
        );
      }
      final columns = (width / 120).floor().clamp(3, 8);
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: padding.copyWith(bottom: 0),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: state.items.length,
              itemBuilder: (context, index) {
                final photo = state.items[index];
                return Semantics(
                  button: true,
                  label: photo.title,
                  child: GestureDetector(
                    onTap: () async => _open(context, state.items, index),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: NetworkIndicatorImage(photo.thumbUrl, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SliverPadding(
            padding: padding.copyWith(top: 0),
            sliver: SliverToBoxAdapter(
              child: ListFooter(
                status: listFooterStatus(
                  hasMore: state.nextPageUrl != null,
                  loading: state.loadingMore || state.refreshing,
                  failed: state.loadMoreFailed,
                ),
                itemCount: state.items.length,
                failure: state.failure,
                onLoadMore: _cubit.loadMore,
                onRetry: _cubit.loadMore,
              ),
            ),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final own = widget.albumId > 0 && context.read<AuthenticationRepository>().currentUser?.uid == widget.uid;
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<SpaceListCubit<SpacePhoto>, SpaceListState<SpacePhoto>>(
        listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing,
        listener: (context, state) {
          _refreshController.finishRefresh();
          if (state.failure != null && state.status == SpaceLoadStatus.success) {
            showRefreshFailedSnackBar(context, state.failure, onRetry: _cubit.refresh);
          }
        },
        builder: (context, state) {
          final body = switch (state.status) {
            SpaceLoadStatus.loading => const ThreadListSkeleton(),
            SpaceLoadStatus.needLogin => NeedLoginPage(
              backUri: GoRouterState.of(context).uri,
              needPop: true,
              popCallback: (_) => _cubit.load(),
            ),
            SpaceLoadStatus.notice => FailureView(
              failure: LoadFailure.fromMessage(state.message ?? ''),
              onRetry: _cubit.load,
            ),
            SpaceLoadStatus.failure => FailureView(failure: state.failure, onRetry: _cubit.load),
            SpaceLoadStatus.success => EasyRefresh(
              controller: _refreshController,
              header: const MaterialHeader(),
              onRefresh: _cubit.refresh,
              child: _grid(context, state),
            ),
          };
          final title = state.title ?? widget.name ?? context.t.spacePage.albums;
          final count = state.totalCount;
          return Scaffold(
            appBar: AppBar(
              title: Text(title),
              actions: [
                if (count != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        context.t.spacePage.photos(count: count),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ),
              ],
            ),
            floatingActionButton: own
                ? FloatingActionButton(
                    tooltip: context.t.spacePage.upload,
                    onPressed: _upload,
                    child: const Icon(Icons.add_photo_alternate_outlined),
                  )
                : null,
            body: SafeArea(bottom: false, child: body),
          );
        },
      ),
    );
  }
}
