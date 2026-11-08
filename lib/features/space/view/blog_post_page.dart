import 'dart:async';

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
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';

/// Value of the category select for a new category.
const _newCategory = '\u0000new';

/// Privacy value of the chosen friends, which takes their names: not offered here.
const _chosenFriends = '2';

/// Privacy value of a password.
const _withPassword = '4';

/// Write a new blog: title, content, category (one of the author's, or a new one), who may read it.
///
/// Pops `true` once the blog is posted.
class BlogPostPage extends StatefulWidget {
  /// Constructor.
  const BlogPostPage({super.key});

  @override
  State<BlogPostPage> createState() => _BlogPostPageState();
}

class _BlogPostPageState extends State<BlogPostPage> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  final _newCategoryName = TextEditingController();
  final _password = TextEditingController();
  late final BlogPostCubit _cubit;

  String? _category;
  String? _systemCategory;
  String _privacy = '0';

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthenticationRepository>();
    _cubit = BlogPostCubit(
      SpaceWriteRepository(client: getIt.get<NetClientProvider>(), currentUid: () => auth.effectiveCurrentUid),
      authChanges: auth.status,
    );
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_cubit.close());
    _subject.dispose();
    _message.dispose();
    _newCategoryName.dispose();
    _password.dispose();
    super.dispose();
  }

  void _send() {
    final tr = context.t.spacePage.blogEdit;
    if (_message.text.trim().isEmpty) {
      showSnackBar(context: context, message: tr.emptyMessage);
      return;
    }
    if (_privacy == _withPassword && _password.text.trim().isEmpty) {
      showSnackBar(context: context, message: tr.emptyPassword);
      return;
    }
    unawaited(
      _cubit.post(
        BlogDraft(
          subject: _subject.text,
          message: _message.text,
          privacy: _privacy,
          category: _category == _newCategory ? null : _category,
          newCategory: _category == _newCategory ? _newCategoryName.text : null,
          systemCategory: _systemCategory,
          password: _privacy == _withPassword ? _password.text.trim() : null,
        ),
      ),
    );
  }

  void _onState(BuildContext context, SpaceWriteState<BlogPostForm> state) {
    final tr = context.t.spacePage;
    switch (state.status) {
      case SpaceWriteStatus.done:
        showSnackBar(context: context, message: tr.blogEdit.done);
        context.pop(true);
      case SpaceWriteStatus.rejected:
        showSnackBar(context: context, message: state.message ?? context.t.general.failedToLoad);
      case SpaceWriteStatus.unconfirmed:
        showSnackBar(context: context, message: state.message ?? tr.unconfirmed);
      case _:
        break;
    }
  }

  Widget _form(BuildContext context, SpaceWriteState<BlogPostForm> state) {
    final tr = context.t.spacePage.blogEdit;
    final form = state.form!;
    final enabled = state.status == SpaceWriteStatus.ready || state.status == SpaceWriteStatus.rejected;
    final privacy = form.privacy.where((e) => e.value != _chosenFriends).toList();
    return AppCenteredList(
      builder: (context, side, width) => ListView(
        padding: side.copyWith(top: 12, bottom: 24).add(context.safePadding()),
        children: [
          TextField(
            controller: _subject,
            enabled: enabled,
            maxLength: 80,
            decoration: InputDecoration(labelText: tr.subject, counterText: ''),
          ),
          sizedBoxW12H12,
          TextField(
            controller: _message,
            enabled: enabled,
            minLines: 10,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(labelText: tr.message, alignLabelWithHint: true),
          ),
          sizedBoxW12H12,
          DropdownButtonFormField<String?>(
            initialValue: _category,
            decoration: InputDecoration(labelText: tr.category),
            items: [
              DropdownMenuItem(child: Text(tr.noCategory)),
              for (final e in form.categories) DropdownMenuItem(value: e.value, child: Text(e.label)),
              DropdownMenuItem(value: _newCategory, child: Text(tr.newCategory)),
            ],
            onChanged: enabled ? (v) => setState(() => _category = v) : null,
          ),
          if (_category == _newCategory) ...[
            sizedBoxW12H12,
            TextField(
              controller: _newCategoryName,
              enabled: enabled,
              decoration: InputDecoration(labelText: tr.newCategoryName),
            ),
          ],
          if (form.systemCategories.isNotEmpty) ...[
            sizedBoxW12H12,
            DropdownButtonFormField<String?>(
              initialValue: _systemCategory,
              decoration: InputDecoration(labelText: tr.systemCategory),
              items: [
                const DropdownMenuItem(child: Text('—')),
                for (final e in form.systemCategories) DropdownMenuItem(value: e.value, child: Text(e.label)),
              ],
              onChanged: enabled ? (v) => setState(() => _systemCategory = v) : null,
            ),
          ],
          if (privacy.isNotEmpty) ...[
            sizedBoxW12H12,
            DropdownButtonFormField<String>(
              initialValue: privacy.any((e) => e.value == _privacy) ? _privacy : privacy.first.value,
              decoration: InputDecoration(labelText: tr.privacy),
              items: [for (final e in privacy) DropdownMenuItem(value: e.value, child: Text(e.label))],
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage;
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<BlogPostCubit, SpaceWriteState<BlogPostForm>>(
        listener: _onState,
        builder: (context, state) {
          final sending = state.status == SpaceWriteStatus.sending;
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
          return Scaffold(
            appBar: AppBar(
              title: Text(tr.newBlog),
              bottom: sending
                  ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                  : null,
              actions: [
                if (state.form != null && state.status != SpaceWriteStatus.identityChanged)
                  IconButton(
                    icon: const Icon(Icons.send_outlined),
                    tooltip: sending ? tr.blogEdit.sending : tr.blogEdit.send,
                    onPressed: _cubit.canSend ? _send : null,
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
