import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/open_in_app/models/openable_forum_resource_model.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/tips.dart';

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

  /// Current parsed and recognized route parsed from user input url.
  RecognizedRoute? currentRoute;

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

  /// 自动执行解析并跳转的逻辑
  Future<void> _autoOpenIfNeeded() async {
    if (!mounted) {
      return;
    }

    // 主动触发表单校验，此时 TextFormField 的 validator 会被执行，从而更新 currentRoute
    formKey.currentState?.validate();

    // 等待一帧，让校验错误显示出来后再跳转
    await Future<void>.delayed(Duration.zero);

    // 无法识别的链接留在本页，由用户决定是否用浏览器打开，绝不自动启动浏览器 (#105)
    if (!mounted || currentRoute == null) {
      return;
    }

    // 使用 pushReplacementNamed 替换当前的中间页，
    // 这样既能保留底部的 HomePage（拥有返回键和全局登录状态），又能清除中间的过渡页面。
    context.pushReplacementNamed(
      currentRoute!.screenPath,
      pathParameters: currentRoute!.pathParameters,
      queryParameters: currentRoute!.queryParameters,
    );
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
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: ListView(
        padding: context.safePadding().add(edgeInsetsL12R12),
        children: [
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: availableResources
                .mapIndexed(
                  (idx, v) => FilterChip(
                    label: Text(v.typename(context)),
                    onSelected: (selected) => selected
                        ? setState(() {
                            currentResourceIndex = idx;
                            // A route recognized as another kind of resource is not what the input means now.
                            currentRoute = null;
                          })
                        : null,
                    selected: currentResourceIndex == idx,
                  ),
                )
                .toList(),
          ),
          sizedBoxW8H8,
          Tips(availableResources[currentResourceIndex].detail(context), enablePadding: false),
          sizedBoxW16H16,
          Form(
            key: formKey,
            child: TextFormField(
              controller: targetController,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: availableResources[currentResourceIndex].typename(context)),
              onChanged: (_) => currentRoute = null,
              // Only [currentRoute] is updated here, it is not part of the build: no setState.
              validator: (v) => availableResources[currentResourceIndex].validator()(context, v).match(
                (e) {
                  currentRoute = null;
                  return e;
                },
                (v) {
                  currentRoute = v;
                  return null;
                },
              ),
            ),
          ),
          sizedBoxW24H24,
          FilledButton.icon(
            label: Text(tr.open),
            icon: const Icon(Icons.open_in_new),
            onPressed: () async {
              if (!formKey.currentState!.validate()) {
                return;
              }
              if (currentRoute == null) {
                return;
              }

              // 手动点击也使用 pushReplacementNamed，保证路由栈干净
              context.pushReplacementNamed(
                currentRoute!.screenPath,
                pathParameters: currentRoute!.pathParameters,
                queryParameters: currentRoute!.queryParameters,
              );
            },
          ),
          if (availableResources[currentResourceIndex] is UrlResource) ...[
            sizedBoxW8H8,
            OutlinedButton.icon(
              key: const ValueKey('open-in-app-browser'),
              label: Text(tr.openInBrowser),
              icon: const Icon(Icons.open_in_browser),
              onPressed: _launchingBrowser ? null : _openInBrowser,
            ),
            sizedBoxW8H8,
            Tips(tr.browserHint, enablePadding: false),
          ],
        ],
      ),
    );
  }
}
