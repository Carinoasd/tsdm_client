import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_input.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Ask for an image url (or `[img]` code) and an optional name, save it as a sticker (#5).
///
/// Returns true when something was saved.
Future<bool> showCustomImageAddDialog(BuildContext context, {String? initialUrl}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _CustomImageAddDialog(initialUrl: initialUrl),
  );
  return saved ?? false;
}

class _CustomImageAddDialog extends StatefulWidget {
  const _CustomImageAddDialog({this.initialUrl});

  final String? initialUrl;

  @override
  State<_CustomImageAddDialog> createState() => _CustomImageAddDialogState();
}

class _CustomImageAddDialogState extends State<_CustomImageAddDialog> {
  late final TextEditingController _url = TextEditingController(text: widget.initialUrl ?? '');
  final _name = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final tr = context.t.bbcodeEditor.customImage;
    final url = parseCustomImageInput(_url.text);
    if (url == null) {
      setState(() => _errorText = tr.invalidUrl);
      return;
    }
    await getIt.get<StorageProvider>().addCustomImage(url: url, name: _name.text.trim());
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.customImage;
    return AlertDialog(
      icon: const Icon(Icons.add_photo_alternate_outlined),
      title: Text(tr.addTitle),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _url,
            autofocus: widget.initialUrl == null,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(labelText: tr.urlHint, errorText: _errorText),
          ),
          sizedBoxW12H12,
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: tr.nameHint),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: _save, child: Text(context.t.general.ok)),
      ],
    );
  }
}

/// The "my images" tab of both emoji pickers, the editor's sheet and the reply bar's panel: saved stickers in a grid,
/// an add tile first (#5, #338).
///
/// Tapping a sticker gives its `[img]` BBCode to [onPicked], or pops the enclosing route with it when there is none;
/// long press deletes it.
class CustomImageTab extends StatelessWidget {
  /// Constructor.
  const CustomImageTab({this.onPicked, this.padding = edgeInsetsL12R12, super.key});

  /// Called with the `[img]` BBCode of the sticker tapped, instead of popping the route.
  final void Function(String bbcode)? onPicked;

  /// Padding of the grid.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.customImage;
    final storage = getIt.get<StorageProvider>();
    return StreamBuilder<List<CustomImageEntity>>(
      stream: storage.watchCustomImages(),
      builder: (context, snapshot) {
        final images = snapshot.data ?? const <CustomImageEntity>[];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (snapshot.hasData && images.isEmpty)
              Padding(
                padding: edgeInsetsL12T4R12B12,
                child: AppNoticeBanner(icon: Icons.collections_outlined, message: tr.empty),
              ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: padding,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 72,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 72,
                ),
                itemCount: images.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Tooltip(
                      message: tr.add,
                      child: OutlinedButton(
                        // Same square with rounded corners as the thumbnails next to it.
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: () async => showCustomImageAddDialog(context),
                        child: const Icon(Icons.add_outlined),
                      ),
                    );
                  }
                  final image = images[index - 1];
                  final bbcode = customImageBBCode(image.url);
                  return Tooltip(
                    message: image.name.isEmpty ? image.url : image.name,
                    // The reply bar's panel paints its own background: the splash needs a material above it.
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(appInnerRadius),
                        onTap: () {
                          final picked = onPicked;
                          if (picked != null) {
                            picked(bbcode);
                          } else {
                            Navigator.of(context).pop(bbcode);
                          }
                        },
                        onLongPress: () async {
                          final confirmed = await showQuestionDialog(
                            context: context,
                            title: tr.delete,
                            message: tr.deleteConfirm,
                            dangerous: true,
                          );
                          if (confirmed ?? false) {
                            await storage.deleteCustomImage(image.id);
                            // Gone from the recent ones too (a URL is saved once).
                            await RecentEmojiStore.app?.remove(bbcode);
                          }
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(appInnerRadius),
                          child: CachedImage(image.url, width: 72, height: 72, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Save [imageUrl] as a sticker from the image action sheet, with a toast; one saved before keeps its name.
Future<void> saveImageAsCustomImage(BuildContext context, String imageUrl) async {
  await getIt.get<StorageProvider>().addCustomImage(url: parseCustomImageInput(imageUrl) ?? imageUrl);
  if (context.mounted) {
    showSnackBar(context: context, clearPrevious: true, message: context.t.bbcodeEditor.customImage.saved);
  }
}
