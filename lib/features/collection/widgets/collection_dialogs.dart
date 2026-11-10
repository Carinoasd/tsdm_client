import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The longest name the forum keeps of a collection (it cuts the rest off).
const collectionNameLimit = 30;

/// The longest description the forum keeps of a collection, and the longest reason of a thread put in one.
const collectionTextLimit = 250;

/// Tell what the forum answered [outcome]: its own words, the login page for a guest. Returns whether it was done.
Future<bool> reportCollectionOutcome(BuildContext context, CollectionOutcome outcome) async {
  final tr = context.t.collection;
  switch (outcome) {
    case CollectionDone(:final message):
      if (message.isNotEmpty) {
        showSnackBar(context: context, message: message);
      }
      return true;
    case CollectionRefused(:final message):
      showSnackBar(context: context, message: message);
    case CollectionNeedLogin():
      unawaited(context.pushNamed(ScreenPaths.login));
    case CollectionAccountChanged():
      showSnackBar(context: context, message: tr.accountChanged);
    case CollectionUnknown():
      showSnackBar(context: context, message: tr.unknown);
  }
  return false;
}

/// The fields of a collection the account writes: name, description, keywords (separated by spaces).
typedef CollectionFields = ({String title, String description, String keywords});

/// Ask the fields of a collection to create ([initial] null) or to edit; null when the dialog was closed.
Future<CollectionFields?> showCollectionEditDialog(BuildContext context, {CollectionFields? initial}) =>
    showDialog<CollectionFields>(
      context: context,
      builder: (context) => _CollectionEditDialog(initial: initial),
    );

class _CollectionEditDialog extends StatefulWidget {
  const _CollectionEditDialog({this.initial});

  final CollectionFields? initial;

  @override
  State<_CollectionEditDialog> createState() => _CollectionEditDialogState();
}

class _CollectionEditDialogState extends State<_CollectionEditDialog> {
  late final _title = TextEditingController(text: widget.initial?.title);
  late final _description = TextEditingController(text: widget.initial?.description);
  late final _keywords = TextEditingController(text: widget.initial?.keywords);

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _keywords.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.collection;
    final edit = widget.initial != null;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.collections_bookmark_outlined, title: edit ? tr.edit : tr.create),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('collection-edit-title'),
            controller: _title,
            autofocus: !edit,
            maxLength: collectionNameLimit,
            decoration: InputDecoration(labelText: tr.name),
          ),
          TextField(
            key: const ValueKey('collection-edit-description'),
            controller: _description,
            minLines: 2,
            maxLines: 5,
            maxLength: collectionTextLimit,
            decoration: InputDecoration(labelText: tr.description),
          ),
          TextField(
            key: const ValueKey('collection-edit-keywords'),
            controller: _keywords,
            decoration: InputDecoration(labelText: tr.keywords),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.general.cancel)),
        TextButton(
          key: const ValueKey('collection-edit-save'),
          onPressed: _title.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (
                  title: _title.text.trim(),
                  description: _description.text.trim(),
                  keywords: _keywords.text.trim(),
                )),
          child: Text(edit ? tr.save : tr.create),
        ),
      ],
    );
  }
}
