import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// The records of one page of the points changelog and where the page is in the list.
typedef ChangelogRecordsPage = ({List<PointsChange> changes, int currentPage, int totalPages});

/// The records of the changelog page [answer] (the structured answer of the forum's app API, or the web page as an
/// older plugin answers it); [pageNumber] is the page asked, the fallback when the answer names none. Null for an
/// answer without the records (the forum's message to a guest, another page).
///
/// Marked as public for testing.
ChangelogRecordsPage? changelogRecordsOf(TsdmAppPageAnswer answer, int pageNumber) {
  switch (answer) {
    case TsdmAppStructuredPage(:final json):
      final page = pointsChangelogFromApi(json, fallbackPage: pageNumber);
      if (page == null) {
        return null;
      }
      return (changes: page.changes, currentPage: page.currentPage, totalPages: page.totalPages);
    case TsdmAppWebPage(:final document):
      final tableNode = document.querySelector('table.dt');
      if (tableNode == null) {
        return null;
      }
      return (
        changes: buildChangeListFromTable(tableNode),
        currentPage: document.currentPage() ?? pageNumber,
        totalPages: document.totalPages() ?? pageNumber,
      );
  }
}

/// The date [day] as the changelog query writes it (`yyyy-MM-dd`).
String changelogQueryDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
