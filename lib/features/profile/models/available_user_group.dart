import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// User groups, for witch current user can switch to.
final class AvailableUserGroup {
  /// Constructor.
  const AvailableUserGroup({required this.name, required this.gid, required this.infoUrl, this.switchUrl});

  /// User group name.
  final String name;

  /// Group id.
  final int gid;

  /// Url of page introducing user group permissions.
  final String infoUrl;

  /// The url of the group's switch window (`home.php?mod=spacecp&ac=usergroup&do=switch&groupid=…`) the list of the
  /// forum's app API names (plugin 3.0.0, the `switch` action of the row); null for a group parsed from the web
  /// page, which is switched by posting to the fixed switch url.
  final String? switchUrl;

  /// The current user group and the groups the member can switch to in the user group list of the forum's app API
  /// (plugin 3.0.0, `type: form`, `form: usergroup`, `do: expiry`) [form]: only the rows whose actions offer
  /// `switch` (the website prints 切换 there); a group the member can only buy, renew or leave is not one. Null when
  /// the answer is not that list.
  static (String currentUserGroup, List<AvailableUserGroup> availableGroups)? parseApi(SmallFormFields form) {
    final json = form.json;
    final kind = json['do'];
    if (kind != 'expiry' && kind != 'list') {
      return null;
    }
    final groups = <AvailableUserGroup>[];
    for (final row in tsdmAppList(json['groups'])) {
      final gid = tsdmAppInt(row['gid']);
      final name = tsdmAppText(row['title']).trim();
      final action = tsdmAppList(row['actions']).where((a) => a['do'] == 'switch').firstOrNull;
      final url = tsdmAppText(action?['url']);
      if (gid <= 0 || name.isEmpty || url.isEmpty) {
        continue;
      }
      final uri = Uri.tryParse(url);
      final query = uri == null || !isForumScriptUri(uri, 'home.php') ? null : uniqueQueryParameters(uri);
      if (query == null || query['ac'] != 'usergroup' || query['do'] != 'switch' || query['groupid'] != '$gid') {
        continue;
      }
      groups.add(AvailableUserGroup(name: name, gid: gid, infoUrl: '', switchUrl: url));
    }
    return (tsdmAppText(tsdmAppMap(json['current'])['title']).trim(), groups);
  }

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
