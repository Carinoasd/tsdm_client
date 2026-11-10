import 'package:tsdm_client/features/moderate/models/thread_perms.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// An attachment of the edited post, as the edit form lists it (`attach.used` of the forum's app API, plugin 3.0.0):
/// the website's attachment list of the edit page.
final class EditAttachment {
  /// Constructor.
  const EditAttachment({required this.aid, required this.filename, required this.isImage});

  /// The attachment id.
  final int aid;

  /// The file name.
  final String filename;

  /// An image (`isimage` other than 0: the forum keeps -1 for an image shown in the post).
  final bool isImage;
}

/// The attachments the edit form [json] lists for the edited post (`attach.used`), in its order; empty for a new
/// thread, a reply, or an answer without the list.
List<EditAttachment> editAttachmentsOf(Map<String, dynamic>? json) {
  final attach = tsdmAppMap(json?['attach']);
  final used = attach['used'];
  final seen = <int>{};
  return [
    for (final e in used is List ? used : const [])
      if (e is Map && tsdmAppInt(e['aid']) > 0 && seen.add(tsdmAppInt(e['aid'])))
        EditAttachment(
          aid: tsdmAppInt(e['aid']),
          filename: tsdmAppText(e['filename']),
          isImage: tsdmAppInt(e['isimage']) != 0,
        ),
  ];
}

/// The query parameter of the editor's route telling whether the attachments of the edited floor may be deleted
/// ([editedFloorAttachmentDeletion]): `1` or `0`, left out when the page of the floor did not tell.
const editAttachmentDeletionQuery = 'delattach';

/// Whether the editor of floor [post] offers deleting its attachments, as the page the floor is on told the account
/// it was served to ([viewerUid]); null when it does not tell: the editor then offers it as before, and the forum
/// decides when asked.
///
/// The account's own floor is never told: deleting the own attachments comes with editing the floor. A floor of
/// another member (one the page names: an anonymous floor names none) is the moderators' to delete from, as [perms]
/// say (`perms.allow_delattach` of the forum's app API, plugin 3.8.0: [ThreadPerms.allowDeleteAttachments]); an
/// answer without the flag (an older plugin, the web page) tells nothing.
bool? editedFloorAttachmentDeletion(Post post, {required int? viewerUid, required ThreadPerms? perms}) {
  final author = int.tryParse(post.author.uid ?? '');
  if (author == null || author <= 0 || viewerUid == null || viewerUid <= 0 || author == viewerUid) {
    return null;
  }
  return perms?.allowDeleteAttachments;
}

/// What [editAttachmentDeletionQuery] of the editor's route [query] says; null when it says nothing.
bool? editAttachmentDeletionOf(Map<String, String> query) => switch (query[editAttachmentDeletionQuery]) {
  '1' => true,
  '0' => false,
  _ => null,
};

/// The edit form [json] once attachment [aid] was deleted (`forum.php?mod=ajax&action=deleteattach`), as the website's
/// edit page leaves its form: the attachment out of the list and its fields (`attachupdate[aid]`, `attachnew[aid][…]`)
/// no longer posted, and `delattachop` 1 so the forum updates the post's attachment mark when the edit is saved.
Map<String, dynamic> editFormWithoutAttachment(Map<String, dynamic> json, int aid) {
  final attach = Map<String, dynamic>.of(tsdmAppMap(json['attach']));
  final used = attach['used'];
  attach['used'] = [
    for (final e in used is List ? used : const [])
      if (!(e is Map && tsdmAppInt(e['aid']) == aid)) e,
  ];
  attach['fields'] = {
    for (final MapEntry(:key, :value) in tsdmAppMap(attach['fields']).entries)
      if (key != 'attachupdate[$aid]' && !key.startsWith('attachnew[$aid]')) key: value,
  };
  final submit = Map<String, dynamic>.of(tsdmAppMap(json['submit']));
  final fields = Map<String, dynamic>.of(tsdmAppMap(submit['fields']));
  if (fields.containsKey('delattachop')) {
    fields['delattachop'] = '1';
  }
  submit['fields'] = fields;
  return {...json, 'attach': attach, 'submit': submit};
}
