import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'emoji_bloc.mapper.dart';

part 'emoji_event.dart';

part 'emoji_state.dart';

/// Emoji emitter.
typedef _Emit = Emitter<EmojiState>;

/// Bloc of emoji.
///
/// Controls loading emoji.
final class EmojiBloc extends Bloc<EmojiEvent, EmojiState> with LoggerMixin {
  /// Constructor.
  EmojiBloc({required EditorRepository editRepository})
    : _editorRepository = editRepository,
      super(const EmojiState(status: EmojiStatus.initial)) {
    on<EmojiEvent>(
      (event, emit) => switch (event) {
        EmojiFetchFromCacheEvent() => _onFetchFromCache(emit),
        EmojiFetchGroupEvent(:final groupId) => _onFetchGroup(groupId, emit),
      },
    );
  }

  final EditorRepository _editorRepository;

  Future<void> _onFetchFromCache(_Emit emit) async {
    emit(state.copyWith(status: EmojiStatus.loading));
    await _editorRepository.loadEmojiFromCacheOrServer().match(
      (e) {
        handle(e);
        emit(state.copyWith(status: EmojiStatus.failure));
      },
      (_) => emit(state.copyWith(status: EmojiStatus.success, emojiGroupList: _editorRepository.emojiGroupList)),
    ).run();
  }

  /// Download what group [groupId] misses, unless it is downloading or all there already.
  Future<void> _onFetchGroup(String groupId, _Emit emit) async {
    final group = state.emojiGroupList?.where((e) => e.id == groupId).firstOrNull;
    final status = state.groupProgress[groupId]?.status;
    if (group == null || status == EmojiStatus.loading || status == EmojiStatus.success) {
      return;
    }
    void tell(EmojiGroupProgress progress) {
      if (!emit.isDone) {
        emit(state.copyWith(groupProgress: {...state.groupProgress, groupId: progress}));
      }
    }

    final total = group.emojiList.length;
    tell(EmojiGroupProgress(status: EmojiStatus.loading, done: state.groupProgress[groupId]?.done ?? 0, total: total));
    final missing = await _editorRepository.downloadEmojiGroup(
      group,
      onProgress: (done, total) => tell(EmojiGroupProgress(status: EmojiStatus.loading, done: done, total: total)),
    );
    tell(
      EmojiGroupProgress(
        status: missing == 0 ? EmojiStatus.success : EmojiStatus.failure,
        done: total - missing,
        total: total,
      ),
    );
  }

  @override
  Future<void> close() async {
    _editorRepository.dispose();
    return super.close();
  }
}
