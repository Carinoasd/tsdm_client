import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'broadcast_message_detail_cubit.mapper.dart';
part 'broadcast_message_detail_state.dart';

/// Cubit of broadcast message detail page.
final class BroadcastMessageDetailCubit extends Cubit<BroadcastMessageDetailState> with LoggerMixin {
  /// Constructor.
  BroadcastMessageDetailCubit(this._notificationRepository) : super(const BroadcastMessageDetailState());

  final NotificationRepository _notificationRepository;

  /// Fetch detail status from [pmid].
  ///
  /// Read from the forum's app API when it answers the detail as fields (plugin 4.0.0, `announcepm`, `schema` 40,
  /// [NotificationRepository.fetchAnnounceDetail]): the message as the forum stored it (`message_html`, shown by the
  /// same renderer as before) and its time. Opening it marks it read, as the web page does: it is only asked when the
  /// user opens it. Any other answer reads the web page as before; the forum's message (private messages switched
  /// off, the login prompt) or a message that is not the account's (`announce: null`) is a failure.
  Future<void> fetchDetail(String pmid) async {
    emit(state.copyWith(status: BroadcastMessageDetailStatus.loading));
    switch (await _notificationRepository.fetchAnnounceDetail(pmid).run()) {
      case Left(:final value):
        handle(value);
        error('failed to fetch broadcast message detail: $value');
        emit(state.copyWith(status: BroadcastMessageDetailStatus.failed));
        return;
      case Right(value: final AnnounceDetail detail):
        emit(
          state.copyWith(
            status: BroadcastMessageDetailStatus.success,
            dateTime: detail.dateTime,
            messageNode: detail.messageNode,
          ),
        );
        return;
      case Right(value: AnnounceDetailRefused(:final reason)):
        error('broadcast message detail refused by the forum: $reason');
        emit(state.copyWith(status: BroadcastMessageDetailStatus.failed));
        return;
      case Right(value: null):
        break;
    }
    await _notificationRepository
        .fetchDocument('$broadcastMessageDetailUrl$pmid')
        .match(
          (e) {
            handle(e);
            error('failed to fetch broadcast message detail: $e');
            emit(state.copyWith(status: BroadcastMessageDetailStatus.failed));
          },
          (v) {
            final (document, _) = v;
            // ```html
            // <div id="pm_ul" class="xld xlda mbm pml">
            // <dl class="cl">
            // <dd class="m avt"><a href="home.php?mod=space&uid=1"><img data-src="..."></a></dd>
            // <dd class="ptm">
            // <a href="home.php?mod=space&uid=1" class="xw1">USERNAME</a>
            // <span class="xg1"><span title="2026-9-1 10:00">3 天前</span></span><br />
            // <p class="pm_smry">MESSAGE</p>
            // </dd></dl></div>
            // ```
            //
            // No Discuz X5 sample available, keep the layout above with fallbacks.
            final infoNode = document.querySelector('div#pm_ul');
            final datetime = (infoNode?.querySelector('dl > dd.ptm > span.xg1') ?? infoNode?.querySelector('span.xg1'))
                ?.dateTime();
            final messageNode =
                infoNode?.querySelector('dl > dd > p.pm_smry') ??
                infoNode?.querySelector('p.pm_smry') ??
                infoNode?.querySelector('dd.ptm');
            if (datetime == null || messageNode == null) {
              error(
                'failed to build broadcast detail message page: '
                'datetime=$datetime, messageNode=${messageNode?.innerHtml}',
              );
              emit(state.copyWith(status: BroadcastMessageDetailStatus.failed));
              return;
            }
            emit(
              state.copyWith(
                status: BroadcastMessageDetailStatus.success,
                dateTime: datetime,
                messageNode: messageNode,
              ),
            );
          },
        )
        .run();
  }
}
