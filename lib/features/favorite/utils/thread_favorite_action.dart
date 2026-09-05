import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/favorite_note_dialog.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Whether thread [tid] is known to be in the current user's favorites.
///
/// The thread page can not tell by itself, only records seen by [FavoriteRepository] in this app run count.
bool isThreadFavorited(BuildContext context, {required String tid}) {
  final uid = context.read<AuthenticationRepository>().currentUser?.uid;
  return uid != null && context.repo<FavoriteRepository>().cachedFavid(uid: uid, tid: tid) != null;
}

/// Add thread [tid] to favorites, or remove it when it is known to be favorited.
///
/// Shows the note dialog, the confirm dialog and the result snack bars. Returns true when the known favorite state
/// changed so the caller can rebuild its menu.
Future<bool> toggleThreadFavorite(BuildContext context, {required String tid}) async {
  final uid = context.read<AuthenticationRepository>().currentUser?.uid;
  if (uid == null) {
    showSnackBar(context: context, message: context.t.threadPage.needLogin);
    return false;
  }
  final repository = context.repo<FavoriteRepository>();
  final favid = repository.cachedFavid(uid: uid, tid: tid);
  if (favid != null) {
    return _remove(context, repository: repository, uid: uid, tid: tid, favid: favid);
  }
  return _add(context, repository: repository, uid: uid, tid: tid);
}

Future<bool> _add(
  BuildContext context, {
  required FavoriteRepository repository,
  required int uid,
  required String tid,
}) async {
  final tr = context.t.threadPage.favorite;
  final description = await showFavoriteNoteDialog(context);
  if (description == null || !context.mounted) {
    return false;
  }
  final result = await repository.addFavorite(tid: tid, description: description).run();
  if (!context.mounted) {
    return false;
  }
  switch (result) {
    case Left(:final value):
      showSnackBar(context: context, message: tr.failed(err: value.message ?? '$value'));
      return false;
    case Right(value: FavoriteAdded(:final favid)):
      if (favid != null) {
        repository.remember(uid: uid, tid: tid, favid: favid);
      }
      showSnackBar(context: context, message: tr.added);
      return favid != null;
    case Right(value: FavoriteAlreadyExists()):
      showSnackBar(context: context, message: tr.alreadyAdded);
      // The forum does not tell which record it is; look it up so the menu can offer to remove it.
      final known = (await repository.findFavid(tid: tid, uid: uid).run()).toNullable();
      return known != null;
    case Right(value: FavoriteAddFailed(:final message)):
      showSnackBar(context: context, message: tr.failed(err: message));
      return false;
  }
}

Future<bool> _remove(
  BuildContext context, {
  required FavoriteRepository repository,
  required int uid,
  required String tid,
  required String favid,
}) async {
  final tr = context.t.threadPage.favorite;
  final confirmed = await showQuestionDialog(
    context: context,
    title: tr.remove,
    message: tr.removeConfirm,
    dangerous: true,
  );
  if (confirmed != true || !context.mounted) {
    return false;
  }
  final result = await repository.removeFavorite(favid: favid).run();
  if (!context.mounted) {
    return false;
  }
  switch (result) {
    case Left(:final value):
      showSnackBar(context: context, message: tr.failed(err: value.message ?? '$value'));
      return false;
    case Right(value: FavoriteRemoveResult(removed: true)):
      repository.forget(uid: uid, tid: tid);
      showSnackBar(context: context, message: tr.removed);
      return true;
    case Right(:final value):
      showSnackBar(context: context, message: tr.failed(err: value.message ?? ''));
      return false;
  }
}
