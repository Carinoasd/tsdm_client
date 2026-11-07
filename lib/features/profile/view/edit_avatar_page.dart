import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/profile/bloc/edit_avatar_bloc.dart';
import 'package:tsdm_client/features/profile/models/avatar_upload.dart';
import 'package:tsdm_client/features/profile/widgets/avatar_crop_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

const _avatarMaxWidth = 100.0;
const _avatarMaxHeight = 150.0;

/// Page to edit user avatar.
class EditAvatarPage extends StatefulWidget {
  /// Constructor.
  const EditAvatarPage({super.key});

  @override
  State<EditAvatarPage> createState() => _EditAvatarPageState();
}

class _EditAvatarPageState extends State<EditAvatarPage> {
  late final TextEditingController _avatarController;

  /// Url of the avatar intend to preview before submit to server.
  String? _previewUrl;

  /// Cropping the picked image into the avatar's images.
  bool _encoding = false;

  Widget _buildContent(BuildContext context, EditAvatarState state) {
    final tr = context.t.editAvatarPage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    /// One avatar box: caption above, the image or a muted placeholder, same size either way.
    Widget avatarBlock(String caption, String? url, IconData placeholderIcon, String? placeholderText) => AppInsetBlock(
      outlined: true,
      padding: edgeInsetsL12T12R12B12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(caption, style: textTheme.labelMedium?.copyWith(color: colorScheme.outline)),
          sizedBoxW8H8,
          SizedBox(
            width: _avatarMaxWidth + 20,
            height: _avatarMaxHeight,
            child: Center(
              child: url != null
                  ? CachedImage(url, maxWidth: _avatarMaxWidth, maxHeight: _avatarMaxHeight)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(placeholderIcon, size: 32, color: colorScheme.outline),
                        if (placeholderText != null) ...[
                          sizedBoxW4H4,
                          Text(
                            placeholderText,
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );

    final busy = _encoding || state.status == EditAvatarStatus.uploading;
    final hasExternal = state.formHash != null;
    final external = (state.avatarUrl?.isNotEmpty ?? false) ? state.avatarUrl : null;

    // Form pages stay at most [appFormMaxWidth] wide, centered on wide windows. The current avatar and the preview
    // sit side by side (wrapping on narrow phones), so the change is compared before it is submitted.
    return AppCenteredList(
      maxWidth: appFormMaxWidth,
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 12, bottom: 24),
        children: [
          AppSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSectionHeader(tr.currentAvatar, icon: Icons.account_circle_outlined),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    avatarBlock(
                      tr.currentAvatar,
                      external ?? state.currentAvatar,
                      Icons.no_photography_outlined,
                      tr.noAvatar,
                    ),
                    if (hasExternal) avatarBlock(tr.preview, _previewUrl, Icons.preview_outlined, null),
                  ],
                ),
                if (state.canUpload) ...[
                  sizedBoxW12H12,
                  FilledButton.tonalIcon(
                    icon: busy ? sizedCircularProgressIndicator : const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: busy ? null : () async => _pickAndUpload(context),
                    label: Text(tr.uploadImage),
                  ),
                ],
              ],
            ),
          ),
          if (hasExternal) ...[
            const SizedBox(height: appSurfaceGap),
            AppFormSection(
              title: tr.avatarUrl,
              icon: Icons.link_outlined,
              children: [
                TextField(
                  controller: _avatarController,
                  decoration: appFieldDecoration(label: tr.avatarUrl, icon: Icons.image_outlined),
                ),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.preview_outlined),
                        onPressed: state.status == EditAvatarStatus.uploading || _avatarController.text.isEmpty
                            ? null
                            : () => setState(() => _previewUrl = _avatarController.text),
                        label: Text(tr.preview),
                      ),
                    ),
                    sizedBoxW8H8,
                    Expanded(
                      child: FilledButton.icon(
                        icon: state.status == EditAvatarStatus.uploading
                            ? sizedCircularProgressIndicator
                            : const Icon(Icons.cloud_upload_outlined),
                        onPressed: state.formHash == null || state.status == EditAvatarStatus.uploading
                            ? null
                            : () {
                                context.read<EditAvatarBloc>().add(
                                  EditAvatarUploadRequested(
                                    avatarUrl: _avatarController.text,
                                    formHash: state.formHash!,
                                  ),
                                );
                              },
                        label: Text(tr.submit),
                      ),
                    ),
                  ],
                ),
                AppNoticeBanner(message: tr.clearAvatarTip),
                Align(
                  child: TextButton.icon(
                    icon: const Icon(Icons.collections_outlined),
                    label: Text(tr.viewSharedAvatars),
                    onPressed: () async => context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '1106488'}),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Pick an image, crop its square, and upload it with the forum's avatar editor.
  Future<void> _pickAndUpload(BuildContext context) async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final bytes = picked?.files.singleOrNull?.bytes;
    if (bytes == null || !context.mounted) {
      return;
    }
    final crop = await AvatarCropPage.show(context, bytes);
    if (crop == null || !context.mounted) {
      return;
    }
    setState(() => _encoding = true);
    final images = await AvatarImages.crop(bytes, left: crop.left, top: crop.top, side: crop.side);
    if (!mounted) {
      return;
    }
    setState(() => _encoding = false);
    if (!context.mounted) {
      return;
    }
    if (images == null) {
      showSnackBar(context: context, message: context.t.editAvatarPage.imageUnreadable);
      return;
    }
    context.read<EditAvatarBloc>().add(EditAvatarImageUploadRequested(images));
  }

  @override
  void initState() {
    super.initState();
    _avatarController = TextEditingController();
  }

  @override
  void dispose() {
    _avatarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => EditAvatarBloc(context.repo())..add(const EditAvatarLoadInfoRequested()),
      child: BlocConsumer<EditAvatarBloc, EditAvatarState>(
        listenWhen: (prev, _) => prev.status == EditAvatarStatus.loading || prev.status == EditAvatarStatus.uploading,
        listener: (context, state) {
          if (state.uploadFailure case final String reason?) {
            // The image upload failed; a refused image removed the avatar the forum had, so the page is read again.
            showSnackBar(context: context, message: reason);
            context.read<EditAvatarBloc>().add(const EditAvatarLoadInfoRequested());
          } else if (state.status == EditAvatarStatus.waitingForUpload) {
            // Finished the loading state.
            setState(() {
              _avatarController.text = state.draftUrl ?? state.avatarUrl ?? '';
            });
          } else if (state.status == EditAvatarStatus.success) {
            setState(() => _previewUrl = null);
            showSnackBar(context: context, message: context.t.editAvatarPage.avatarUpdated);
            context.read<EditAvatarBloc>().add(const EditAvatarLoadInfoRequested());
          }
        },
        builder: (context, state) {
          final body = switch (state.status) {
            EditAvatarStatus.initial || EditAvatarStatus.loading => const CenteredCircularIndicator(),
            EditAvatarStatus.waitingForUpload ||
            EditAvatarStatus.success ||
            EditAvatarStatus.uploading => _buildContent(context, state),
            EditAvatarStatus.failure => buildRetryButton(
              context,
              () => context.read<EditAvatarBloc>().add(const EditAvatarLoadInfoRequested()),
            ),
          };

          return Scaffold(
            appBar: AppBar(title: Text(context.t.editAvatarPage.title)),
            body: SafeArea(top: false, bottom: false, child: body),
          );
        },
      ),
    );
  }
}
