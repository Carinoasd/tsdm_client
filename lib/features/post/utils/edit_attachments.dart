import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

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
