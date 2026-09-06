import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';

/// Searching a member's posts from the profile page: the author goes to the server by name (`srchuname`, the field
/// the search form itself sends) and the keyword may stay empty. A bare `srchuid` found nothing for testers.
void main() {
  group('buildSearchQuery', () {
    test('an author name is sent as srchuname with an empty keyword allowed', () {
      final q = buildSearchQuery(keyword: '', fid: '0', uid: '0', authorName: 'Alice', pageNumber: 1);
      expect(q, {'mod': 'forum', 'srchtxt': '', 'srchuname': 'Alice', 'searchsubmit': 'yes'});
    });

    test('a uid is still sent as srchuid, name and uid may go together', () {
      final q = buildSearchQuery(keyword: 'x', fid: '0', uid: '1000', authorName: 'Alice', pageNumber: 1);
      expect(q['srchuid'], '1000');
      expect(q['srchuname'], 'Alice');
      expect(q['srchtxt'], 'x');
    });

    test('any author and any forum add nothing, a later page adds the page', () {
      final q = buildSearchQuery(keyword: 'x', fid: '0', uid: '0', authorName: '', pageNumber: 3);
      expect(q.keys, unorderedEquals(['mod', 'srchtxt', 'searchsubmit', 'page']));
      expect(q['page'], '3');
    });

    test('a forum id is sent as srchfid[]', () {
      final q = buildSearchQuery(keyword: '', fid: '42', uid: '0', authorName: '', pageNumber: 1);
      expect(q['srchfid[]'], '42');
      expect(q.containsKey('page'), isFalse);
    });
  });
}
