import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// Build a list of [ForumGroup]s from the given [document].
///
/// A forum group is a list of forum the grouped together, exists in the forum homepage and special pages with `gid` in
/// url query parameter.
///
/// Discuz X5 layout (both homepage and `forum.php?gid=xxx` page):
///
/// <div id="ct">
///   <div class="mn">
///     <div class="fl bm">
///       <div class="bm bmw cl">              <- expanded layout group
///         <div class="bm_h cl"><h2><a href="forum.php?gid=1">天使·后花园</a></h2></div>
///         <div id="category_1" class="bm_c">
///           <table class="fl_tb">
///             <tr><td class="fl_icn"/><td><h2/></td><td class="fl_i"/><td class="fl_by"/></tr>
///             <tr class="fl_row">...</tr>
///           </table>
///         </div>
///       </div>
///       <div class="bm bmw flg cl">          <- collapsed layout group
///         ...
///         <table class="fl_tb">
///           <tr><td class="fl_g">...</td><td class="fl_g">...</td></tr>
///         </table>
///       </div>
///     </div>
///   </div>
/// </div>
List<ForumGroup> buildGroupListFromDocument(uh.Document document) {
  final forumGroupNodeList = [
    // Style 1: With user avatar, also X5.
    ...document.querySelectorAll('div#ct > div.mn > div.fl.bm > div.bm.bmw.cl'),
    // Style 2: Without user avatar and with welcome text.
    ...document.querySelectorAll('div.mn.miku > div.forumlist > div.forumbox'),
  ];
  final forumGroupList = forumGroupNodeList.map(_buildFromBMNode).toList();
  return forumGroupList;
}

/// Build from <div class="bm bmw flg cl"> or <div class="forumbox"> [element]
ForumGroup _buildFromBMNode(uh.Element element) {
  final titleNode =
      // X5 and style 1: <div class="bm_h cl"><h2><a href="forum.php?gid=1">name</a></h2></div>
      element.querySelector('div.bm_h > h2 > a') ??
      element.querySelector('div:nth-child(1) > h2 > a') ??
      element.querySelector('div:nth-child(1) > h2') ??
      // Style 5
      element.querySelector('div.title_r > h2 > a');
  final name = titleNode?.firstEndDeepText()?.trim();
  final url = titleNode?.attributes['href'];

  final subForumNodeList =
      (element.querySelector('div.bm_c') ?? element.querySelector('div:nth-child(2)'))
          ?.querySelectorAll('table > tbody > tr')
          .toList() ??
      const [];

  final forumList = <Forum>[];
  for (final subForumNode in subForumNodeList) {
    // If children is empty, these are invisible elements in web page, skip.
    if (subForumNode.children.isEmpty) {
      continue;
    }

    // Here we can not tell whether the sub forums are in expanded layout or
    // not by checking element attributes.
    // The only way to check this is looking at the title node in sub forums.

    // Expanded layout forum layout.
    if (subForumNode.querySelector('h2') != null) {
      final forum = Forum.fromFlRowNode(subForumNode);
      if (forum != null) {
        forumList.add(forum);
      }
      continue;
    }

    // Normal layout forum has attribute class=fl_g
    final forumFlGNodeList = subForumNode.querySelectorAll('td.fl_g').toList();
    if (forumFlGNodeList.isEmpty) {
      continue;
    }
    forumList.addAll(forumFlGNodeList.map(Forum.fromFlGNode).whereType<Forum>());
  }

  // <div class="bm_h cl"><span class="y">分区版主: <a href="home.php?mod=space&username=...">name</a>, ...</span>
  final moderators = element
      .querySelectorAll('div.bm_h > span.y > a')
      .map((e) => e.firstEndDeepText()?.trim() ?? '')
      .where((e) => e.isNotEmpty)
      .toList();

  return ForumGroup(name: name ?? '', url: url ?? '', forumList: forumList, moderators: moderators);
}
