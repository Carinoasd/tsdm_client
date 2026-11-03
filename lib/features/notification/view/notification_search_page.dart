import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/notice_block_filter.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';

/// Gather all kinds of notifications.
final class _SavedNotifications {
  /// Constructor.
  const _SavedNotifications({
    required this.noticeList,
    required this.personalMessageList,
    required this.broadcastMessageList,
  });

  /// All saved notice.
  final List<NoticeV2> noticeList;

  /// All saved personal messages.
  final List<PersonalMessageV2> personalMessageList;

  /// All saved broadcast messages.
  final List<BroadcastMessageV2> broadcastMessageList;
}

/// Search and filter notifications.
class NotificationSearchPage extends StatefulWidget {
  /// Constructor.
  const NotificationSearchPage({super.key});

  @override
  State<NotificationSearchPage> createState() => _NotificationSearchPageState();
}

class _NotificationSearchPageState extends State<NotificationSearchPage> {
  _SavedNotifications? notice;

  var _searchContent = '';

  /// A titled group of results, nothing when [cards] is empty.
  List<Widget> _section(String title, IconData icon, List<Widget> cards) => [
    if (cards.isNotEmpty) ...[
      AppSectionHeader(title, icon: icon, trailing: Text('${cards.length}')),
      for (final (index, card) in cards.indexed) ...[if (index > 0) appListSeparator, card],
      appListSeparator,
    ],
  ];

  @override
  Widget build(BuildContext context) {
    if (notice == null) {
      final state = context.read<NotificationBloc>().state;
      notice = _SavedNotifications(
        noticeList: state.noticeList,
        personalMessageList: state.personalMessageList,
        broadcastMessageList: state.broadcastMessageList,
      );
    }

    final tr = context.t.noticeSearchPage;
    final trNotice = context.t.noticePage;
    // Filtered on every build (not in the snapshot): blocking or unblocking while this page is open applies at once.
    final blocked = currentBlockList(context);
    final keywords = currentKeywordBlockList(context);
    final notices = notice!.noticeList
        .where(
          (e) =>
              !isBlockedNoticeAuthor(e.authorId, blocked) &&
              !isKeywordBlockedNotice(e.data, e.authorId, keywords, type: e.ignoreType, fromIdType: e.fromIdType) &&
              e.data.contains(_searchContent),
        )
        .map(NoticeCardV2.new)
        .toList();
    final personalMessages = notice!.personalMessageList
        .where((e) => e.data.contains(_searchContent))
        .map(PersonalMessageCardV2.new)
        .toList();
    final broadcastMessages = notice!.broadcastMessageList
        .where((e) => e.data.contains(_searchContent))
        .map(BroadcastMessageCardV2.new)
        .toList();
    final empty = notices.isEmpty && personalMessages.isEmpty && broadcastMessages.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: SearchBar(
          autoFocus: true,
          hintText: tr.title,
          leading: const Icon(Icons.search_outlined),
          elevation: const WidgetStatePropertyAll(0),
          onChanged: (str) {
            setState(() {
              _searchContent = str;
            });
          },
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: empty
            ? AppStateView(icon: Icons.search_off_outlined, message: context.t.general.noData)
            : AppCenteredList(
                builder: (context, side, _) => ListView(
                  padding: side.copyWith(top: 4, bottom: 12).add(context.safePadding()),
                  children: [
                    ..._section(trNotice.noticeTab.title, Icons.notifications_outlined, notices),
                    ..._section(trNotice.privateMessageTab.title, Icons.forum_outlined, personalMessages),
                    ..._section(trNotice.broadcastMessageTab.title, Icons.campaign_outlined, broadcastMessages),
                  ],
                ),
              ),
      ),
    );
  }
}
