import 'package:flutter/material.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/report_handling/repository/admin_report_source.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/report_handling/view/report_handling_page.dart';

/// Handling reports for an account that may read the admin API's reports (`adminreport`): those of the whole forum
/// first, with the panel's one forum at a time ([panel]) beside them when the forum offers its page.
///
/// The second login asked here (a dialog) is the one the other admin pages use: the token is kept as long as the forum
/// keeps it ([AdminSession]).
class AdminReportPage extends StatefulWidget {
  /// Constructor.
  const AdminReportPage({required this.writable, this.panel, this.repository, super.key});

  /// The account may post `adminreport`: handling and deleting offered.
  final bool writable;

  /// The panel's reports, null when not offered.
  final ReportSource? panel;

  /// Injected for tests; the app's client otherwise.
  final AdminRepository? repository;

  @override
  State<AdminReportPage> createState() => _AdminReportPageState();
}

class _AdminReportPageState extends State<AdminReportPage> with AdminPageSession {
  @override
  late final AdminRepository adminRepository = widget.repository ?? AdminRepository.network();

  late final _whole = AdminReportSource(repository: adminRepository, writable: widget.writable, reauth: reauth);

  @override
  Widget build(BuildContext context) => switch (widget.panel) {
    final panel? => ReportHandlingPage(source: panel, wholeForum: _whole),
    null => ReportHandlingPage(source: _whole),
  };
}
