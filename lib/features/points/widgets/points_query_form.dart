import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/features/points/bloc/points_bloc.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// Form to make the user points changelog query filter.
///
/// Combines and format a query form.
class PointsQueryForm extends StatefulWidget {
  /// Constructor.
  const PointsQueryForm(this.allParameters, {super.key});

  /// All available parameters that can use in query.
  final ChangelogAllParameters allParameters;

  @override
  State<PointsQueryForm> createState() => _PointsQueryFormState();
}

final class _PointsQueryFormState extends State<PointsQueryForm> {
  /// Key of the query form.
  final formKey = GlobalKey<FormState>();

  /// Current points type.
  late ChangelogPointsType? pointsType;

  /// Current operation type.
  late ChangelogOperationType? operationType;

  /// Start time of the duration of query parameter.
  String startTime = '';

  /// End time of the duration of query parameter.
  String endTime = '';

  /// Current event change type.
  late ChangelogChangeType? changeType;
  PointsChangeType pointsChangeType = PointsChangeType.unlimited;

  /// Flag to control the visibility of query filter.
  bool showQueryFilter = false;

  /// Show a modal bottom sheet of all points ext type choices.
  Future<void> pickExtType(BuildContext context) async {
    return showCustomBottomSheet(
      context: context,
      title: context.t.pointsPage.changelogTab.operationType,
      childrenBuilder: (context) {
        return widget.allParameters.extTypeList
            .map(
              (e) => SelectableListTile(
                title: Text(context.displayText(e.name)),
                selected: e == pointsType,
                onTap: () {
                  setState(() {
                    pointsType = e;
                  });
                  context.pop();
                },
              ),
            )
            .toList();
      },
    );
  }

  /// Let user pick the operation type query parameter.
  Future<void> pickOperationType(BuildContext context) async {
    return showCustomBottomSheet(
      context: context,
      title: context.t.pointsPage.changelogTab.operationType,
      childrenBuilder: (context) {
        return widget.allParameters.operationTypeList
            .map(
              (e) => SelectableListTile(
                title: Text(context.displayText(e.name)),
                selected: e == operationType,
                onTap: () {
                  setState(() {
                    operationType = e;
                  });
                  context.pop();
                },
              ),
            )
            .toList();
      },
    );
  }

  Future<void> pickChangeType(BuildContext context) async {
    return showCustomBottomSheet(
      context: context,
      title: context.t.pointsPage.changelogTab.changeType,
      childrenBuilder: (context) {
        return widget.allParameters.changeTypeList
            .map(
              (e) => SelectableListTile(
                title: Text(context.displayText(e.name)),
                selected: e == changeType,
                onTap: () {
                  setState(() {
                    changeType = e;
                  });
                  context.pop();
                },
              ),
            )
            .toList();
      },
    );
  }

  Future<void> pickDateRange(BuildContext context) async {
    final dateRange = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000, 1, 2),
      lastDate: DateTime.now(),
    );
    if (dateRange == null) {
      return;
    }
    setState(() {
      startTime = dateRange.start.yyyyMMDD();
      endTime = dateRange.end.yyyyMMDD();
    });
  }

  List<Widget> _buildContent(BuildContext context, PointsChangelogState state) {
    VoidCallback? queryCallback;
    if (pointsType != null && operationType != null && changeType != null && state.status != PointsStatus.loading) {
      queryCallback = () => context.read<PointsChangelogBloc>().add(
        PointsChangelogQueryRequested(
          ChangelogParameter(
            extType: pointsType!.extType,
            operation: operationType!.operation,
            changeType: changeType!.changeType,
            startTime: startTime,
            endTime: endTime,
            pageNumber: 1,
          ),
        ),
      );
    }

    final extType = _picker(
      label: context.t.pointsPage.changelogTab.extType,
      icon: Icons.monetization_on_outlined,
      value: pointsType?.name ?? '',
      onTap: () async => pickExtType(context),
    );
    final change = _picker(
      label: context.t.pointsPage.changelogTab.changeType,
      icon: Icons.ssid_chart_outlined,
      value: changeType?.name ?? '',
      onTap: () async => pickChangeType(context),
    );
    return [
      // Side by side while both labels fit, stacked on narrow screens or with large fonts.
      LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 480 * MediaQuery.textScalerOf(context).scale(1)
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: extType),
                  sizedBoxW8H8,
                  Expanded(child: change),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [extType, sizedBoxW12H12, change],
              ),
      ),
      _picker(
        label: context.t.pointsPage.changelogTab.operationType,
        icon: Icons.select_all_outlined,
        value: operationType?.name ?? '',
        onTap: () async => pickOperationType(context),
      ),
      _picker(
        label: context.t.pointsPage.changelogTab.dateRange,
        icon: Icons.date_range_outlined,
        value: '$startTime - $endTime',
        onTap: () async => pickDateRange(context),
        dropdown: false,
      ),
      FilledButton.icon(
        onPressed: queryCallback,
        icon: const Icon(Icons.search),
        label: Text(context.t.pointsPage.changelogTab.query),
      ),
    ];
  }

  /// A read-only field opening a picker; focusable and activated by Enter or Space too.
  Widget _picker({
    required String label,
    required IconData icon,
    required String value,
    required VoidCallback onTap,
    bool dropdown = true,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(appInnerRadius),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: dropdown ? const Icon(Icons.arrow_drop_down_outlined) : null,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(appInnerRadius),
          borderSide: BorderSide.none,
        ),
      ),
      child: Text(context.displayText(value)),
    ),
  );

  @override
  void initState() {
    super.initState();
    pointsType = widget.allParameters.extTypeList.firstOrNull;
    operationType = widget.allParameters.operationTypeList.firstOrNull;
    changeType = widget.allParameters.changeTypeList.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    // Reset the null value parameters to prevent disabled query state.
    pointsType ??= widget.allParameters.extTypeList.firstOrNull;
    operationType ??= widget.allParameters.operationTypeList.firstOrNull;
    changeType ??= widget.allParameters.changeTypeList.firstOrNull;

    return BlocBuilder<PointsChangelogBloc, PointsChangelogState>(
      builder: (context, state) {
        return AppSurface(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Padding(
            padding: showQueryFilter ? const EdgeInsets.only(right: 8, bottom: 8) : EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.filter_list, size: 20, color: Theme.of(context).colorScheme.primary),
                    sizedBoxW8H8,
                    Expanded(
                      child: Text(
                        context.t.pointsPage.changelogTab.query,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: showQueryFilter
                          ? const Icon(Icons.expand_less_outlined)
                          : const Icon(Icons.expand_more_outlined),
                      tooltip: showQueryFilter
                          ? context.t.pointsPage.changelogTab.hideFilterTip
                          : context.t.pointsPage.changelogTab.showFilterTip,
                      onPressed: () {
                        setState(() {
                          showQueryFilter = !showQueryFilter;
                        });
                      },
                    ),
                  ],
                ),
                if (showQueryFilter) ..._buildContent(context, state),
              ].insertBetween(sizedBoxW12H12),
            ),
          ),
        );
      },
    );
  }
}
