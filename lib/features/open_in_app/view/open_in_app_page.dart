import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/open_in_app/models/openable_forum_resource_model.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
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

    // 【修改】如果传入了初始 URL，自动填入并解析跳转
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      // 【修复】queryParameters 已经自动解码了 url，直接使用，不要再 decodeComponent
      targetController.text = widget.initialUrl!;
      // 等待第一帧渲染完毕后再自动解析，避免在 initState 中调用 setState 报错
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoOpenIfNeeded());
    }
  }

  /// 【新增】自动执行解析并跳转的逻辑
  Future<void> _autoOpenIfNeeded() async {
    if (!mounted) {
      return;
    }

    // 使用现有的 validator 逻辑解析 URL，它会自动填充 currentRoute
    final validator = availableResources[currentResourceIndex].validator();
    validator(context, targetController.text);

    if (currentRoute == null || !mounted) {
      return;
    }

    // 解析成功，直接跳转到对应的页面
    await context.pushNamed(
      currentRoute!.screenPath,
      pathParameters: currentRoute!.pathParameters,
      queryParameters: currentRoute!.queryParameters,
    );
    if (!mounted) {
      return;
    }
    context.pop();
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
                    onSelected: (selected) => selected ? setState(() => currentResourceIndex = idx) : null,
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
              validator: (v) => availableResources[currentResourceIndex].validator()(context, v).match((e) => e, (v) {
                setState(() => currentRoute = v);
                return null;
              }),
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

              await context.pushNamed(
                currentRoute!.screenPath,
                pathParameters: currentRoute!.pathParameters,
                queryParameters: currentRoute!.queryParameters,
              );
              if (!context.mounted) {
                return;
              }
              context.pop();
            },
          ),
        ],
      ),
    );
  }
}
