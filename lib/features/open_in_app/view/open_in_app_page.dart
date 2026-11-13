import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/open_in_app/models/openable_forum_resource_model.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A button opens route to [OpenInAppPage],
class OpenInAppPageButton extends StatelessWidget {
  /// Constructor.
  const OpenInAppPageButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Symbols.open_in_phone),
      tooltip: context.t.openInAppPage.entryTooltip,
      onPressed: () async => context.pushNamed(ScreenPaths.openInApp),
    );
  }
}

/// A page accept different kinds of user input and try parse the desired forum resource then open in app.
///
/// Supported inputs:
///
/// * Forum url.
///   * Should be recognized by url dispatcher.
/// * User id.
/// * Username.
/// * Forum id.
/// * Thread id.
/// * Post id.
class OpenInAppPage extends StatefulWidget {
  /// Constructor.
  const OpenInAppPage({super.key, this.initialUrl, this.autoOpen = false});

  /// Optional URL passed in from a deep link.
  final String? initialUrl;

  /// Whether to automatically parse and open the [initialUrl] on page load.
  final bool autoOpen;

  @override
  State<OpenInAppPage> createState() => _OpenInAppPageState();
}

class _OpenInAppPageState extends State<OpenInAppPage> {
  final formKey = GlobalKey<FormState>();

  /// Controller of target content text.
  late final TextEditingController targetController;

  /// Current resource type in [availableResources].
  int currentResourceIndex = 0;

  /// The input was checked once (an open tapped, a deep link opened): from then on the text under the field follows
  /// every change of the input and of its kind.
  bool _checked = false;

  /// A browser launch is in flight: further taps are ignored until it answers.
  bool _launchingBrowser = false;

  final List<OpenableForumResource<dynamic>> availableResources = [
    UrlResource(),
    UsernameResource(),
    UidResource(),
    FidResource(),
    TidResource(),
    PidResource(),
  ];

  @override
  void initState() {
    super.initState();
    targetController = TextEditingController();

    // 如果传入了初始 URL，自动填入输入框
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      targetController.text = widget.initialUrl!;
      // 根据作者意见：保留填入网址的动作，但只在 widget.autoOpen 为 true 时执行自动跳转
      if (widget.autoOpen) {
        // 等待第一帧渲染完毕后再自动解析，避免在 initState 中调用 setState 报错
        WidgetsBinding.instance.addPostFrameCallback((_) => _autoOpenIfNeeded());
      }
    }
  }

  /// What the input [text] opens as the kind of input chosen, or why it opens nothing: the one check of both the text
  /// under the field and the open button.
  Either<String, RecognizedRoute> _check(String? text) =>
      availableResources[currentResourceIndex].validator()(context, text);

  /// Check the input, showing why it opens nothing from now on, and open what it names in place of this page.
  ///
  /// Replacing this page keeps the page under it (the home page, with the back button and the login state) and drops
  /// this one from the stack.
  void _open() {
    final route = _check(targetController.text);
    setState(() => _checked = true);
    if (route case Right(value: final route)) {
      context.pushReplacementNamed(
        route.screenPath,
        pathParameters: route.pathParameters,
        queryParameters: route.queryParameters,
      );
    }
  }

  /// Open the deep link [OpenInAppPage.initialUrl] when the app knows it. One it does not know stays on this page for
  /// the user to decide whether to open it in the browser; the browser is never launched on its own (#105).
  void _autoOpenIfNeeded() {
    if (!mounted) {
      return;
    }
    _open();
  }

  /// Open the link in the input box in the external browser, recognized by the app or not (#105).
  ///
  /// An unknown link from a deep link is never launched on its own: only this button launches.
  Future<void> _openInBrowser() async {
    if (_launchingBrowser) {
      return;
    }
    final tr = context.t.openInAppPage;
    final uri = parseBrowserLink(targetController.text);
    if (uri == null) {
      showSnackBar(context: context, message: tr.invalidBrowserLink, clearPrevious: true);
      return;
    }

    setState(() => _launchingBrowser = true);
    // Do not include the URL: queries and fragments may contain private forum data.
    talker.info('browser launch requested (scheme=${uri.scheme})');
    var launched = false;
    try {
      launched = await openInExternalBrowser(uri);
    } on Object catch (e, st) {
      talker.handle('failed to open link in browser: $e', st);
    }
    talker.info(launched ? 'browser launch accepted' : 'browser launch refused');
    _launchingBrowser = false;
    if (!mounted) {
      return;
    }
    setState(() {});
    if (!launched) {
      showSnackBar(context: context, message: tr.browserLaunchFailed, clearPrevious: true);
    }
  }

  @override
  void dispose() {
    targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.openInAppPage;
    final colorScheme = Theme.of(context).colorScheme;
    final isUrl = availableResources[currentResourceIndex] is UrlResource;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      // One form surface centered like the other forms: kind of input, what it accepts, the field, the actions.
      body: SafeArea(
        top: false,
        child: AppCenteredList(
          maxWidth: appFormMaxWidth,
          builder: (context, padding, _) => ListView(
            padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
            children: [
              AppFormSection(
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: availableResources
                        .mapIndexed(
                          (idx, v) => FilterChip(
                            label: Text(v.typename(context)),
                            onSelected: (selected) => selected
                                // Checked again as the new kind once checked: the field rebuilds with the form.
                                ? setState(() => currentResourceIndex = idx)
                                : null,
                            selected: currentResourceIndex == idx,
                          ),
                        )
                        .toList(),
                  ),
                  AppNoticeBanner(message: availableResources[currentResourceIndex].detail(context)),
                  Form(
                    key: formKey,
                    autovalidateMode: _checked ? AutovalidateMode.always : AutovalidateMode.disabled,
                    child: TextFormField(
                      controller: targetController,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      decoration: appFieldDecoration(
                        label: availableResources[currentResourceIndex].typename(context),
                        icon: isUrl ? Icons.link_outlined : Icons.tag,
                      ),
                      validator: (v) => _check(v).match((e) => e, (_) => null),
                    ),
                  ),
                  FilledButton.icon(
                    label: Text(tr.open),
                    icon: const Icon(Icons.open_in_new),
                    onPressed: _open,
                  ),
                  if (isUrl) ...[
                    OutlinedButton.icon(
                      key: const ValueKey('open-in-app-browser'),
                      label: Text(tr.openInBrowser),
                      icon: const Icon(Icons.open_in_browser),
                      onPressed: _launchingBrowser ? null : _openInBrowser,
                    ),
                    Text(
                      tr.browserHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
