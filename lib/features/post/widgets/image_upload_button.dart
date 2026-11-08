import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Where images to upload come from.
enum ImageUploadSource {
  /// Picked from the gallery or the files.
  gallery,

  /// A photo taken now (mobile).
  camera,

  /// The clipboard.
  clipboard,
}

/// The button of the post editor uploading images: a menu of where they come from ([ImageUploadSource]) and whether
/// they open the image editor first, as [editsByDefault] when the menu opens from a tap, always when it opens from a
/// long press. [onPicked] gets the choice.
class ImageUploadButton extends StatefulWidget {
  /// Constructor.
  const ImageUploadButton({required this.editsByDefault, required this.onPicked, super.key});

  /// Whether images open the editor before every upload (the setting).
  final bool editsByDefault;

  /// Called with the source picked and whether to edit first.
  final void Function(ImageUploadSource source, {required bool edit}) onPicked;

  @override
  State<ImageUploadButton> createState() => _ImageUploadButtonState();
}

class _ImageUploadButtonState extends State<ImageUploadButton> {
  final _menu = MenuController();
  late bool _edit = widget.editsByDefault;

  void _open({required bool edit}) {
    setState(() => _edit = edit);
    _menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.imageUpload;
    MenuItemButton item(ImageUploadSource source, IconData icon, String label) => MenuItemButton(
      leadingIcon: Icon(icon),
      onPressed: () => widget.onPicked(source, edit: _edit),
      child: Text(label),
    );
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        item(ImageUploadSource.gallery, Icons.photo_library_outlined, tr.gallery),
        if (isMobile) item(ImageUploadSource.camera, Icons.photo_camera_outlined, tr.camera),
        item(ImageUploadSource.clipboard, Icons.content_paste_outlined, tr.clipboard),
        const Divider(height: 1),
        CheckboxMenuButton(
          value: _edit,
          closeOnActivate: false,
          onChanged: (v) => setState(() => _edit = v ?? false),
          child: Text(tr.editFirst),
        ),
      ],
      // The tooltip only on hover: a long press is the editor's.
      builder: (context, controller, _) => Tooltip(
        message: tr.button,
        triggerMode: TooltipTriggerMode.manual,
        child: GestureDetector(
          onLongPress: () => _open(edit: true),
          child: IconButton(
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: () => controller.isOpen ? controller.close() : _open(edit: widget.editsByDefault),
          ),
        ),
      ),
    );
  }
}
