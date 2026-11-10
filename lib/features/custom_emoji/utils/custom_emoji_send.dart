import 'package:flutter/widgets.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_reuse.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_grid.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/attachment_upload.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

final class _CustomEmojiSend with LoggerMixin {
  const _CustomEmojiSend();
}

/// Put the custom emoji [emoji] into the post being written as an attachment ([CustomEmojiSender]), as the post
/// editor and the reply bar do: the code of the attachment it already is in the post ([inPost], by SHA-256 of the
/// image; [used], the attachments of an edited post), of the account's unused upload of the image the form lists
/// ([unused]), else of a new upload through [repo] to [upload], remembered for the account
/// ([CustomEmojiStore.rememberUpload]). An unused upload reused and a new one are given to [bind]: bound to the post
/// when it is published ([PostFormEdits.attachNew]).
///
/// Null when it cannot go up, told in a snack bar of [context]; also when the upload came back for an account no
/// longer in use, or when [stillHere] says the post is gone meanwhile: nothing is bound then.
Future<String?> sendCustomEmojiAttachment(
  BuildContext context, {
  required CustomEmoji emoji,
  required PostEditRepository repo,
  required AttachmentUpload? upload,
  required Set<int> unused,
  required Set<int> used,
  required Map<String, int> inPost,
  required void Function(int aid) bind,
  required bool Function() stillHere,
}) async {
  final store = CustomEmojiStore.app;
  final uid = repo.ownerUid;
  final tr = context.t.shareReceive;
  final file = store?.fileOf(emoji);
  if (store == null || upload == null || !upload.image || uid == null || file == null) {
    showSnackBar(context: context, message: tr.uploadUnavailable);
    return null;
  }
  final decision = decideCustomEmojiAttachment(
    sha256: emoji.sha256,
    inPost: inPost,
    remembered: store.uploadedAid(uid, emoji.sha256),
    unused: unused,
    used: used,
  );
  switch (decision) {
    case CustomEmojiInPost(:final aid):
      inPost[emoji.sha256] = aid;
      return attachmentImageBBCode(aid);
    case CustomEmojiUnused(:final aid):
      inPost[emoji.sha256] = aid;
      bind(aid);
      return attachmentImageBBCode(aid);
    case CustomEmojiUpload(:final forget):
      if (forget) store.forgetUpload(uid, emoji.sha256);
  }
  final result = await repo.uploadImage(upload, file.path).run();
  return result.match(
    (e) {
      const _CustomEmojiSend().handle(e);
      if (context.mounted) {
        showSnackBar(
          context: context,
          message: switch (e) {
            AttachmentUploadFailedException(reason: AttachmentUploadRefusal.type) => tr.uploadRefusedType(
              name: emoji.fileName,
            ),
            AttachmentUploadFailedException(reason: AttachmentUploadRefusal.size) => tr.uploadRefusedSize(
              name: emoji.fileName,
              limit: upload.maxKb ?? 0,
            ),
            AttachmentUploadFailedException(:final code?) => tr.uploadFailed(code: '$code'),
            _ => tr.uploadFailed(code: ''),
          },
        );
      }
      return null;
    },
    (aid) {
      store.rememberUpload(uid, emoji.sha256, aid);
      // Uploaded for an account no longer in use, or a post gone: not bound to anything here.
      if (!stillHere() || !repo.isCurrent) return null;
      inPost[emoji.sha256] = aid;
      bind(aid);
      return attachmentImageBBCode(aid);
    },
  );
}
