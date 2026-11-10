import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/rate/view/fast_rate_edit_template_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/adaptive_ink_response.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A score of a rate: attribute name and signed value; positive in the primary color, negative in the error color,
/// zero dimmed.
class RateScoreChip extends StatelessWidget {
  /// Constructor.
  const RateScoreChip({required this.name, required this.value, super.key});

  /// Attribute name.
  final String name;

  /// Score value.
  final int value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final valueColor = value > 0
        ? colorScheme.primary
        : value < 0
        ? colorScheme.error
        : colorScheme.outline;
    return AppInsetBlock(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${context.displayText(name)} '),
            TextSpan(
              text: '${value > 0 ? "+" : ""}$value',
              style: TextStyle(color: valueColor, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Actions in popup menu.
enum _MenuAction {
  /// Edit current template.
  edit,

  /// Delete current template.
  delete,
}

/// Card displaying a single fast rate template.
///
/// Can be used in both applying templates and editing templates. When editing one, an extra edit dialog is available
/// when tapping the card.
class FastRateTemplateCard extends StatefulWidget {
  /// Constructor.
  const FastRateTemplateCard({required this.rateTemplate, this.allowEdit = false, super.key});

  /// The initial rate template.
  final FastRateTemplateModel rateTemplate;

  /// Flag indicating the template card is editable or not.
  ///
  /// Only set to true when need it.
  final bool allowEdit;

  @override
  State<FastRateTemplateCard> createState() => _FastRateTemplateCardState();
}

class _FastRateTemplateCardState extends State<FastRateTemplateCard> {
  /// Current rate template used as state.
  late FastRateTemplateModel rateTemplate;

  Future<void> openMenu(Offset globalPosition) async {
    final tr = context.t.fastRateTemplate;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }

    RelativeRect? position;
    position = RelativeRect.fromRect(
      globalPosition & Size.zero, // Rect from the tap position
      Offset.zero & MediaQuery.of(context).size, // Bounding box for the menu
    );

    final action = await showMenu<_MenuAction>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(value: _MenuAction.edit, child: Text(tr.edit)),
        PopupMenuItem(
          value: _MenuAction.delete,
          child: Text(tr.delete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ],
    );

    if (action == null || !mounted) {
      return;
    }

    switch (action) {
      case _MenuAction.edit:
        final editResult = await context.pushNamed<FastRateTemplateModel>(
          ScreenPaths.fastRateTemplateEdit,
          pathParameters: {'editType': '${FastRateTemplateEditType.edit.index}'},
          extra: rateTemplate,
        );
        if (editResult == null || !context.mounted) {
          return;
        }
        // Save added result.
        await getIt.get<StorageProvider>().deleteFastRateTemplateByName(rateTemplate.name).run();
        await getIt.get<StorageProvider>().saveFastRateTemplate(editResult).run();
      case _MenuAction.delete:
        final delete = await showQuestionDialog(
          context: context,
          title: tr.delete,
          richMessage: tr.deleteConfirm(
            name: TextSpan(
              text: rateTemplate.name,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          dangerous: true,
        );
        if (delete != true || !context.mounted) {
          return;
        }
        await getIt.get<StorageProvider>().deleteFastRateTemplateByName(rateTemplate.name).run();
    }
  }

  Future<void> popBack() async {
    context.pop(rateTemplate);
  }

  @override
  void initState() {
    super.initState();
    rateTemplate = widget.rateTemplate;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.fastRateTemplate;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: AdaptiveInkResponse(
        onTapUp: widget.allowEdit ? (pos) async => openMenu(pos.globalPosition) : (_) async => popBack(),
        onAdaptiveContextTap: (pos) => openMenu(pos.globalPosition),
        child: Padding(
          padding: edgeInsetsL16T12R16B12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const AppIconTile(Icons.star_rate_outlined, size: 32),
                  sizedBoxW12H12,
                  Expanded(
                    child: Text(
                      rateTemplate.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (widget.allowEdit) Icon(Icons.more_vert, size: 18, color: colorScheme.outline),
                ],
              ),
              sizedBoxW8H8,
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  RateScoreChip(name: tr.ww, value: rateTemplate.ww),
                  RateScoreChip(name: tr.tsb, value: rateTemplate.tsb),
                  RateScoreChip(name: tr.xc, value: rateTemplate.xc),
                  RateScoreChip(name: tr.tr, value: rateTemplate.tr),
                  RateScoreChip(name: tr.fh, value: rateTemplate.fh),
                  RateScoreChip(name: tr.jl, value: rateTemplate.jl),
                  RateScoreChip(name: tr.special, value: rateTemplate.special),
                  RateScoreChip(name: tr.special2, value: rateTemplate.special2),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
