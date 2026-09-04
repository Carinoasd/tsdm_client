import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;

/// User groups, for witch current user can switch to.
final class AvailableUserGroup {
  /// Constructor.
  const AvailableUserGroup({required this.name, required this.gid, required this.infoUrl});

  /// User group name.
  final String name;

  /// Group id.
  final int gid;

  /// Url of page introducing user group permissions.
  final String infoUrl;

  /// Build instance from `<tr>` node.
  ///
  /// Each `<tr>` node is a row in the available user group table.
  ///
  /// ```html
  /// <tr class="">
  /// <td><a href="$INFO_URL" class="xi2" target="_blank">$NAME</a></td>
  /// <td>
  /// </td>
  /// <td></td>
  /// <td></td>
  /// <td>
  /// <a href="URL_TO_SWITCH_GROUP" class="xw1 xi2" onclick="showWindow('group', this.href, 'get', 0);">切换</a>
  /// </td>
  /// </tr>
  /// ```
  static AvailableUserGroup? fromTr(uh.Element element) {
    final nameNode = element.querySelector('td:nth-child(1) > a');
    final name = nameNode?.innerText.trim();
    final infoUrl = nameNode?.attributes['href'];
    final gid = infoUrl?.tryParseAsUri().tryGetQueryParameters()?['gid']?.parseToInt();

    if (name == null || infoUrl == null || gid == null) {
      talker.error('failed to parse avaiable user group: name=$name, infoUrl=$infoUrl, gid=$gid');
      return null;
    }

    return AvailableUserGroup(name: name, infoUrl: infoUrl, gid: gid);
  }

  /// Parse current user group name and all available user groups in the info page.
  ///
  /// Marked as public for testing.
  static (String? currentUserGroup, List<AvailableUserGroup> availableGroups) parseInfoDocument(
    uh.Document document,
  ) {
    // Discuz X5: `div#ct`, Discuz X3: `div#ct_shell`.
    final rootNode = document.querySelector('div#ct_shell') ?? document.querySelector('div#ct');
    // ```html
    // <p class="tbmu"><span class="y">您目前有 <span class="xi1"> 10532 天使币</span></span>
    // 当前用户组: <font color="Red">超级版主</font></p>
    // ```
    //
    // The name of current user group is in the trailing part of `p.tbmu` and there's no better to grep it.
    final tbmuNode = rootNode?.querySelector('p.tbmu');
    final currentUserGroup =
        tbmuNode?.querySelector('font')?.innerText.trim() ?? tbmuNode?.innerText.trim().split(' ').lastOrNull;
    // Rows in header `tbody.th` have no `<td>` so they are filtered out by the parser.
    final availableUserGroups = (rootNode?.querySelectorAll('table.dt tr') ?? <uh.Element>[])
        .where((e) => e.querySelector('td') != null)
        .map(AvailableUserGroup.fromTr)
        .whereType<AvailableUserGroup>()
        .toList();
    return (currentUserGroup, availableUserGroups);
  }
}
