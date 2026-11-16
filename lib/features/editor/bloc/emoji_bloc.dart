import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
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
    final loaded = await _editorRepository.loadEmojiFromCacheOrServer().run();
    if (loaded case Left(:final value)) {
      handle(value);
      emit(state.copyWith(status: EmojiStatus.failure));
      return;
    }
    emit(state.copyWith(status: EmojiStatus.success, emojiGroupList: _editorRepository.emojiGroupList));

    // Shown at once; the forum's list now, once a run.
    final fresh = await _editorRepository.refreshEmojiList();
    if (fresh == null || emit.isDone) {
      return;
    }
    final shown = {for (final g in state.emojiGroupList ?? const <EmojiGroup>[]) g.id: g};
    final progress = <String, EmojiGroupProgress>{};
    final again = <String>[];
    for (final group in fresh) {
      final p = state.groupProgress[group.id];
      if (p == null) {
        continue;
      }
      final before = shown[group.id];
      if (before != null && sameEmojiGroup(before, group)) {
        progress[group.id] = p;
      } else {
        // Shown already and changed: what it gained is downloaded.
        again.add(group.id);
      }
    }
    // A group that did not change stays the same object: a download running for it goes on telling its progress.
    final groups = [
      for (final g in fresh)
        if (shown[g.id] case final before? when sameEmojiGroup(before, g)) before else g,
    ];
    emit(state.copyWith(emojiGroupList: groups, groupProgress: progress));
    for (final id in again) {
      add(EmojiFetchGroupEvent(id));
    }
  }

  /// Download what group [groupId] misses, unless it is downloading or all there already.
  Future<void> _onFetchGroup(String groupId, _Emit emit) async {
    final group = state.emojiGroupList?.where((e) => e.id == groupId).firstOrNull;
    final status = state.groupProgress[groupId]?.status;
    if (group == null || status == EmojiStatus.loading || status == EmojiStatus.success) {
      return;
    }
    void tell(EmojiGroupProgress Function(EmojiGroupProgress? now) progress) {
      // The group may have changed meanwhile (the forum's list came): its own download tells then.
      final now = state.emojiGroupList?.where((e) => e.id == groupId).firstOrNull;
      if (!emit.isDone && now != null && sameEmojiGroup(now, group)) {
        emit(state.copyWith(groupProgress: {...state.groupProgress, groupId: progress(state.groupProgress[groupId])}));
      }
    }

    final total = group.emojiList.length;
    tell(
      (now) => EmojiGroupProgress(
        status: EmojiStatus.loading,
        done: now?.done ?? 0,
        total: total,
      ),
    );
    final missing = await _editorRepository.downloadEmojiGroup(
      group,
      onProgress: (done, total) => tell(
        (now) => EmojiGroupProgress(status: EmojiStatus.loading, done: done, total: total, failed: now?.failed ?? 0),
      ),
      onFailed: (failed) => tell(
        (now) => EmojiGroupProgress(status: EmojiStatus.loading, done: now?.done ?? 0, total: total, failed: failed),
      ),
    );
    tell(
      (_) => EmojiGroupProgress(
        status: missing == 0 ? EmojiStatus.success : EmojiStatus.failure,
        done: total - missing,
        total: total,
        failed: missing,
      ),
    );
  }

  @override
  Future<void> close() async {
    _editorRepository.dispose();
    return super.close();
  }
}
