import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/space/cubit/space_write_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';

/// Value of the album select for a new album.
const _newAlbum = '\u0000new';

/// Privacy value of the chosen friends, which takes their names: not offered here.
const _chosenFriends = '2';

/// Privacy value of a password.
const _withPassword = '4';

/// Upload pictures to one of the member's albums, or to a new one.
///
/// Pops `true` once pictures are filed.
class AlbumUploadPage extends StatefulWidget {
  /// Constructor; [albumId] is the album chosen first.
  const AlbumUploadPage({this.albumId, super.key});

  /// The album chosen first.
  final int? albumId;

  @override
  State<AlbumUploadPage> createState() => _AlbumUploadPageState();
}

class _AlbumUploadPageState extends State<AlbumUploadPage> {
  final _albumName = TextEditingController();
  final _password = TextEditingController();
  late final AlbumUploadCubit _cubit;

  final _paths = <String>[];
  String? _album;
  String _privacy = '0';

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthenticationRepository>();
    _cubit = AlbumUploadCubit(
      SpaceWriteRepository(client: getIt.get<NetClientProvider>(), currentUid: () => auth.effectiveCurrentUid),
      albumId: widget.albumId,
      authChanges: auth.status,
    );
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_cubit.close());
    _albumName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    if (!mounted || result == null) return;
    setState(() {
      for (final path in result.files.map((e) => e.path).nonNulls) {
        if (!_paths.contains(path)) _paths.add(path);
      }
    });
  }

  /// The album chosen: the one the page was opened for when the form offers it, the first one, or a new one.
  String _albumOf(AlbumUploadForm form) {
    final offered = form.albums.map((e) => e.value).toSet();
    final album = _album;
    if (album != null && (album == _newAlbum || offered.contains(album))) return album;
    final preferred = '${widget.albumId}';
    if (offered.contains(preferred)) return preferred;
    return form.albums.firstOrNull?.value ?? _newAlbum;
  }

  void _send(AlbumUploadForm form) {
    final tr = context.t.spacePage.blogEdit;
    final album = _albumOf(form);
    if (album == _newAlbum && _albumName.text.trim().isEmpty) {
      showSnackBar(context: context, message: context.t.spacePage.albumUpload.emptyAlbumName);
      return;
    }
    if (album == _newAlbum && _privacy == _withPassword && _password.text.trim().isEmpty) {
      showSnackBar(context: context, message: tr.emptyPassword);
      return;
    }
    final target = album == _newAlbum
        ? AlbumTarget.create(
            _albumName.text,
            privacy: _privacy,
            password: _privacy == _withPassword ? _password.text.trim() : null,
          )
        : AlbumTarget.existing(album);
    unawaited(_cubit.upload(List.of(_paths), target));
  }

  String _reason(SpaceUploadRefusal reason) {
    final tr = context.t.spacePage.albumUpload;
    return switch (reason) {
      SpaceUploadRefusal.type => tr.refusedType,
      SpaceUploadRefusal.size => tr.refusedSize,
      SpaceUploadRefusal.rejected => tr.refusedRejected,
      SpaceUploadRefusal.failed || SpaceUploadRefusal.identityChanged => tr.refusedFailed,
    };
  }

  void _onState(BuildContext context, SpaceWriteState<AlbumUploadForm> state) {
    final tr = context.t.spacePage;
    switch (state.status) {
      case SpaceWriteStatus.done:
        showSnackBar(
          context: context,
          message: tr.albumUpload.done(count: state.filed),
        );
        context.pop(true);
      case SpaceWriteStatus.rejected:
        // The pictures the forum took leave the list (filed with the next send when filing them was refused, see
        // `pending`); those it did not take stay, marked, to try again.
        setState(() => _paths.retainWhere((p) => state.refused.any((e) => e.path == p)));
        showSnackBar(
          context: context,
          message: context.displayTextOr(
            state.message,
            state.refused.isEmpty || state.pending > 0 ? tr.sendFailed : tr.albumUpload.noneTaken,
          ),
        );
      case SpaceWriteStatus.unconfirmed:
        showSnackBar(context: context, message: context.displayTextOr(state.message, tr.unconfirmed));
      case _:
        break;
    }
  }

  Widget _photos(BuildContext context, SpaceWriteState<AlbumUploadForm> state, {required bool enabled}) {
    final theme = Theme.of(context);
    final refused = {for (final e in state.refused) e.path: e.reason};
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 110).floor().clamp(3, 8);
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [
            for (final path in _paths)
              Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(File(path), fit: BoxFit.cover, cacheWidth: 300),
                  ),
                  if (refused[path] case final SpaceUploadRefusal reason)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ColoredBox(
                        color: theme.colorScheme.errorContainer,
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            _reason(reason),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onErrorContainer),
                          ),
                        ),
                      ),
                    ),
                  if (enabled)
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        icon: const Icon(Icons.close),
                        tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                        onPressed: () => setState(() => _paths.remove(path)),
                      ),
                    ),
                ],
              ),
            // Taken by the forum, still to be filed to an album.
            if (state.pending > 0)
              Material(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_done_outlined, color: theme.colorScheme.onSecondaryContainer),
                      sizedBoxW4H4,
                      Text('${state.pending}', style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
              ),
            if (enabled)
              Material(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: _pick,
                  child: Tooltip(
                    message: context.t.spacePage.albumUpload.pick,
                    child: Icon(Icons.add_photo_alternate_outlined, size: 32, color: theme.colorScheme.primary),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _form(BuildContext context, SpaceWriteState<AlbumUploadForm> state) {
    final tr = context.t.spacePage.albumUpload;
    final form = state.form!;
    final enabled = state.status == SpaceWriteStatus.ready || state.status == SpaceWriteStatus.rejected;
    final album = _albumOf(form);
    final privacy = form.privacy.where((e) => e.value != _chosenFriends).toList();
    return AppCenteredList(
      builder: (context, side, width) => ListView(
        padding: side.copyWith(top: 12, bottom: 24).add(context.safePadding()),
        children: [
          if (state.status == SpaceWriteStatus.sending) ...[
            LinearProgressIndicator(value: state.total == 0 ? null : state.sent / state.total),
            sizedBoxW4H4,
            Text(
              state.sent < state.total ? tr.sending(sent: state.sent + 1, total: state.total) : tr.filing,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            sizedBoxW12H12,
          ],
          _photos(context, state, enabled: enabled),
          sizedBoxW16H16,
          DropdownButtonFormField<String>(
            initialValue: album,
            decoration: InputDecoration(labelText: tr.album),
            items: [
              for (final e in form.albums) DropdownMenuItem(value: e.value, child: Text(context.displayText(e.label))),
              DropdownMenuItem(value: _newAlbum, child: Text(tr.newAlbum)),
            ],
            onChanged: enabled ? (v) => setState(() => _album = v) : null,
          ),
          if (album == _newAlbum) ...[
            sizedBoxW12H12,
            TextField(
              controller: _albumName,
              enabled: enabled,
              maxLength: 50,
              decoration: InputDecoration(labelText: tr.albumName, counterText: ''),
            ),
            if (privacy.isNotEmpty) ...[
              sizedBoxW12H12,
              DropdownButtonFormField<String>(
                initialValue: privacy.any((e) => e.value == _privacy) ? _privacy : privacy.first.value,
                decoration: InputDecoration(labelText: tr.privacy),
                items: [
                  for (final e in privacy) DropdownMenuItem(value: e.value, child: Text(context.displayText(e.label))),
                ],
                onChanged: enabled ? (v) => setState(() => _privacy = v ?? '0') : null,
              ),
            ],
            if (_privacy == _withPassword) ...[
              sizedBoxW12H12,
              TextField(
                controller: _password,
                enabled: enabled,
                decoration: InputDecoration(labelText: tr.password),
              ),
            ],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage;
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<AlbumUploadCubit, SpaceWriteState<AlbumUploadForm>>(
        listener: _onState,
        builder: (context, state) {
          final body = switch (state.status) {
            SpaceWriteStatus.loading => const Center(child: CircularProgressIndicator()),
            SpaceWriteStatus.needLogin => NeedLoginPage(backUri: GoRouterState.of(context).uri, needPop: true),
            SpaceWriteStatus.identityChanged => AppStateView(
              icon: Icons.switch_account_outlined,
              message: tr.identityChanged,
            ),
            SpaceWriteStatus.loadFailed => FailureView(
              failure: state.message == null ? null : LoadFailure.fromMessage(state.message!),
              onRetry: _cubit.load,
            ),
            _ => _form(context, state),
          };
          final form = state.form;
          return Scaffold(
            appBar: AppBar(
              title: Text(tr.upload),
              actions: [
                if (form != null && state.status != SpaceWriteStatus.identityChanged)
                  IconButton(
                    icon: const Icon(Icons.cloud_upload_outlined),
                    tooltip: tr.albumUpload.send,
                    onPressed: _cubit.canSend && (_paths.isNotEmpty || state.pending > 0) ? () => _send(form) : null,
                  ),
              ],
            ),
            body: SafeArea(bottom: false, child: body),
          );
        },
      ),
    );
  }
}
