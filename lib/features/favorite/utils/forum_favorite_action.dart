import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/favorite_note_dialog.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Whether forum [fid] is known to be in the current user's favorites.
///
/// The forum page can not tell by itself; records seen by [FavoriteRepository] in this app run count: the
/// "我收藏的版块" panel of the topics tab, the favorites list page and successful adds.
bool isForumFavorited(BuildContext context, {required String fid}) {
  final uid = context.read<AuthenticationRepository>().currentUser?.uid;
  return uid != null && context.repo<FavoriteRepository>().isForumFavorited(uid: uid, fid: fid);
}

/// Add forum [fid] to favorites, or remove it when it is known to be favorited.
///
/// Shows the note dialog, the confirm dialog and the result snack bars. Returns true when the known favorite state
/// changed so the caller can rebuild its menu.
Future<bool> toggleForumFavorite(BuildContext context, {required String fid}) async {
  final uid = context.read<AuthenticationRepository>().currentUser?.uid;
  if (uid == null) {
    showSnackBar(context: context, clearPrevious: true, message: context.t.forumPage.favorite.needLogin);
    return false;
  }
  final repository = context.repo<FavoriteRepository>();
  if (repository.isForumFavorited(uid: uid, fid: fid)) {
    return _remove(context, repository: repository, uid: uid, fid: fid);
  }
  return _add(context, repository: repository, uid: uid, fid: fid);
}

Future<bool> _add(
  BuildContext context, {
  required FavoriteRepository repository,
  required int uid,
  required String fid,
}) async {
  final tr = context.t.forumPage.favorite;
  final description = await showFavoriteNoteDialog(context, title: tr.add);
  if (description == null || !context.mounted) {
    return false;
  }
  final result = await repository.addForumFavorite(fid: fid, description: description).run();
  if (!context.mounted) {
    return false;
  }
  switch (result) {
    case Left(:final value):
      showSnackBar(
        context: context,
        clearPrevious: true,
        message: tr.failed(err: value.message ?? '$value'),
      );
      return false;
    case Right(value: FavoriteAdded(:final favid)):
      if (favid != null) {
        repository.rememberForum(uid: uid, fid: fid, favid: favid);
      }
      showSnackBar(context: context, clearPrevious: true, message: tr.added);
      return favid != null;
    case Right(value: FavoriteAlreadyExists()):
      showSnackBar(context: context, clearPrevious: true, message: tr.alreadyAdded);
      // The forum does not tell which record it is; look it up so the menu can offer to remove it.
      final known = (await repository.findForumFavid(fid: fid, uid: uid).run()).toNullable();
      if (known != null) {
        // Favorited on the web after the topics tab fetched its panel: have it reload.
        repository.notifyForumFavoritesChanged();
      }
      return known != null;
    case Right(value: FavoriteAddFailed(:final message)):
      showSnackBar(
        context: context,
        clearPrevious: true,
        message: tr.failed(err: message),
      );
      return false;
  }
}

Future<bool> _remove(
  BuildContext context, {
  required FavoriteRepository repository,
  required int uid,
  required String fid,
}) async {
  final tr = context.t.forumPage.favorite;
  final confirmed = await showQuestionDialog(
    context: context,
    title: tr.remove,
    message: tr.removeConfirm,
    dangerous: true,
  );
  if (confirmed != true || !context.mounted) {
    return false;
  }
  // The favorites panel of forum.php lists the forum but not the record id; look it up first when needed.
  var favid = repository.cachedForumFavid(uid: uid, fid: fid);
  if (favid == null) {
    switch (await repository.findForumFavid(fid: fid, uid: uid).run()) {
      case Left(:final value):
        if (context.mounted) {
          showSnackBar(
            context: context,
            clearPrevious: true,
            message: tr.failed(err: value.message ?? '$value'),
          );
        }
        return false;
      case Right(:final value):
        favid = value;
    }
    if (!context.mounted) {
      return false;
    }
    if (favid == null) {
      // Not in the list anymore: it was removed elsewhere, the state is settled; the topics tab still lists it.
      repository
        ..forgetForum(uid: uid, fid: fid)
        ..notifyForumFavoritesChanged();
      showSnackBar(context: context, clearPrevious: true, message: tr.removed);
      return true;
    }
  }
  final result = await repository.removeFavorite(favid: favid, type: FavoriteType.forum).run();
  if (!context.mounted) {
    return false;
  }
  switch (result) {
    case Left(:final value):
      showSnackBar(
        context: context,
        clearPrevious: true,
        message: tr.failed(err: value.message ?? '$value'),
      );
      return false;
    case Right(value: FavoriteRemoveResult(removed: true)):
      repository.forgetForum(uid: uid, fid: fid);
      showSnackBar(context: context, clearPrevious: true, message: tr.removed);
      return true;
    case Right(:final value):
      showSnackBar(
        context: context,
        clearPrevious: true,
        message: tr.failed(err: value.message ?? ''),
      );
      return false;
  }
}
