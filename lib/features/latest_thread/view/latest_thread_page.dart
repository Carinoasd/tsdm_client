import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page to show info about latest thread page.
class LatestThreadPage extends StatefulWidget {
  /// Constructor.
  const LatestThreadPage({required this.url, this.title, this.repository, super.key});

  /// Url the the page.
  final String url;

  /// App bar title, e.g. the guide module name (最新热门); the generic "latest thread" title when null.
  final String? title;

  /// Repository override (tests); the real one is used when null.
  final LatestThreadRepository? repository;

  @override
  State<LatestThreadPage> createState() => _LatestThreadPageState();
}

class _LatestThreadPageState extends State<LatestThreadPage> {
  late final EasyRefreshController _refreshController;

  Widget _buildBody(BuildContext context, LatestThreadState state) {
    _refreshController
      ..finishRefresh()
      ..finishLoad();

    return EasyRefresh(
      controller: _refreshController,
      header: const MaterialHeader(),
      footer: const MaterialFooter(),
      onRefresh: () async {
        context.read<LatestThreadBloc>().add(LatestThreadRefreshRequested(widget.url));
      },
      onLoad: () async {
        if (state.nextPageUrl == null) {
          _refreshController.finishLoad(IndicatorResult.noMore);
          return;
        }
        context.read<LatestThreadBloc>().add(LatestThreadLoadMoreRequested());
      },
      child: state.threadList.isEmpty
          // The guide page can be empty (最新精华 has no threads); say so instead of showing a blank list.
          ? ListView(
              padding: edgeInsetsL12T4R12.add(context.safePadding()),
              children: [
                Padding(
                  padding: edgeInsetsL12T12R12B12,
                  child: Text(
                    context.t.latestThreadPage.empty,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ],
            )
          : ListView.separated(
              padding: edgeInsetsL12T4R12.add(context.safePadding()),
              itemCount: state.threadList.length,
              itemBuilder: (context, index) {
                return LatestThreadCard(state.threadList[index]);
              },
              separatorBuilder: (context, index) => sizedBoxW4H4,
            ),
    );
  }

  @override
  void initState() {
    super.initState();
    _refreshController = EasyRefreshController(controlFinishLoad: true, controlFinishRefresh: true);
  }

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => widget.repository ?? LatestThreadRepository()),
        BlocProvider(
          create: (context) =>
              LatestThreadBloc(latestThreadRepository: context.repo())..add(LatestThreadRefreshRequested(widget.url)),
        ),
      ],
      child: BlocBuilder<LatestThreadBloc, LatestThreadState>(
        builder: (context, state) {
          final body = switch (state.status) {
            LatestThreadStatus.initial || LatestThreadStatus.loading => const CenteredCircularIndicator(),
            LatestThreadStatus.failed => buildRetryButton(context, () {
              context.read<LatestThreadBloc>().add(LatestThreadRefreshRequested(widget.url));
            }),
            LatestThreadStatus.success => _buildBody(context, state),
          };

          return Scaffold(
            appBar: AppBar(title: Text(widget.title ?? context.t.latestThreadPage.title)),
            body: SafeArea(bottom: false, child: body),
          );
        },
      ),
    );
  }
}
