import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/utils/attachment_upload.dart' show imageContentTypeOf;
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// What loading a form of [SpaceWriteRepository] gave.
enum SpaceFormLoadKind {
  /// The form, served to the account the page belongs to.
  ready,

  /// The forum printed its message instead (no permission, the module switched off), see [SpaceFormLoad.message].
  denied,

  /// The form was served to a guest: log in again.
  loginRequired,

  /// Served to, or asked for, another account: nothing more is sent.
  identityChanged,

  /// The request failed, or the answer is not understood.
  failed,
}

/// A form of [SpaceWriteRepository] as it loaded.
final class SpaceFormLoad<T> {
  /// Constructor.
  const SpaceFormLoad(this.kind, {this.form, this.message});

  /// What it gave.
  final SpaceFormLoadKind kind;

  /// The form when [kind] is [SpaceFormLoadKind.ready].
  final T? form;

  /// The forum's words when [kind] is [SpaceFormLoadKind.denied].
  final String? message;
}

/// What is known after a form was posted once.
enum SpaceWriteOutcome {
  /// The forum did it: the blog is posted, the pictures are filed.
  done,

  /// The forum refused, see [SpaceWriteResult.message]: nothing was done.
  rejected,

  /// The request may have reached the forum: it is not sent again by itself.
  unconfirmed,

  /// The forum asks to log in: nothing was done.
  loginRequired,

  /// Nothing was sent: the account changed.
  identityChanged,
}

/// The result of a post of [SpaceWriteRepository].
final class SpaceWriteResult {
  /// Constructor.
  const SpaceWriteResult(this.outcome, {this.id, this.message});

  /// What is known.
  final SpaceWriteOutcome outcome;

  /// The blog posted, or the album the pictures went to (-1 the default album), when the forum told it.
  final int? id;

  /// The forum's words.
  final String? message;
}

/// Why a picture was not taken.
enum SpaceUploadRefusal {
  /// The forum takes no such file (by its extension).
  type,

  /// Larger than the forum takes.
  size,

  /// The forum did not take it (its uploader answered no picture).
  rejected,

  /// The request failed: the picture may or may not have reached the forum.
  failed,

  /// Nothing was sent: the account changed.
  identityChanged,
}

/// A new blog as the member wrote it.
final class BlogDraft {
  /// Constructor.
  const BlogDraft({
    required this.subject,
    required this.message,
    required this.privacy,
    this.category,
    this.newCategory,
    this.systemCategory,
    this.password,
  });

  /// Title.
  final String subject;

  /// Content, plain text.
  final String message;

  /// Who may read it, a value of [BlogPostForm.privacy].
  final String privacy;

  /// One of the author's own categories ([BlogPostForm.categories]), null for none.
  final String? category;

  /// A new category of the author's, created with the blog; wins over [category].
  final String? newCategory;

  /// One of the site's categories ([BlogPostForm.systemCategories]).
  final String? systemCategory;

  /// The password when [privacy] is `4`.
  final String? password;
}

/// Where uploaded pictures are filed: an album of the member's ([albumId]), or a new one ([newAlbumName]).
final class AlbumTarget {
  /// An album the upload page offered.
  const AlbumTarget.existing(String this.albumId) : newAlbumName = null, privacy = '0', password = null;

  /// A new album named [newAlbumName], seen by [privacy] (a value of [AlbumUploadForm.privacy]).
  const AlbumTarget.create(String this.newAlbumName, {this.privacy = '0', this.password}) : albumId = null;

  /// The album, for [AlbumTarget.existing].
  final String? albumId;

  /// The name of the new album, for [AlbumTarget.create].
  final String? newAlbumName;

  /// Who may see the new album.
  final String privacy;

  /// The password of the new album when [privacy] is `4`.
  final String? password;
}

/// Posts blogs and uploads pictures to albums for one account, the one current when it was built.
///
/// Every request goes on the account the repository was built for: it is never sent once another account is current
/// ([isCurrent]) or once [invalidate]d, and a form served to another account (or a guest) is never posted. A post is
/// sent once (single attempt, no redirect followed): an answer that does not tell the outcome is
/// [SpaceWriteOutcome.unconfirmed], never sent again by itself.
final class SpaceWriteRepository with LoggerMixin {
  /// Constructor.
  SpaceWriteRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
        sendFile: (url, fields, file) => client.postMultipartFiles(url, data: fields, files: {'Filedata': file}).run(),
      );

  /// Injectable transports; a post is never retried.
  SpaceWriteRepository.withTransport({
    required int? Function() currentUid,
    required Future<SyncEither<Response<dynamic>>> Function(String) getPage,
    required Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) sendForm,
    required Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>, MultipartFilePart) sendFile,
  }) : _get = getPage,
       _post = sendForm,
       _sendFile = sendFile,
       _currentUid = currentUid,
       _ownerUid = currentUid();

  final Future<SyncEither<Response<dynamic>>> Function(String) _get;
  final Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) _post;
  final Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>, MultipartFilePart) _sendFile;
  final int? Function() _currentUid;
  final int? _ownerUid;
  bool _invalidated = false;

  /// Nothing more is sent, even when the account comes back.
  void invalidate() => _invalidated = true;

  /// Whether requests may still go out for the account this repository belongs to.
  bool get isCurrent => !_invalidated && _ownerUid != null && _ownerUid > 0 && _ownerUid == _currentUid();

  /// Whether [uid] is the account this repository belongs to, still current.
  bool belongsTo(int? uid) => isCurrent && uid == _ownerUid;

  /// The account this repository belongs to, null without one.
  int? get ownerUid => _ownerUid != null && _ownerUid > 0 ? _ownerUid : null;

  /// The new blog form.
  static const blogFormUrl = '$baseUrl/home.php?mod=spacecp&ac=blog';

  /// Where a new blog is posted.
  static const blogSubmitUrl = '$baseUrl/home.php?mod=spacecp&ac=blog&blogid=';

  /// The album upload page.
  static const uploadFormUrl = '$baseUrl/home.php?mod=spacecp&ac=upload';

  /// Where uploaded pictures are filed.
  static const uploadSubmitUrl = '$baseUrl/home.php?mod=spacecp&ac=upload';

  Future<SpaceFormLoad<T>> _loadForm<T>(
    String url,
    ({T? form, String? message, bool needLogin}) Function(uh.Document) parse,
    int Function(T form) servedTo,
  ) async {
    if (!isCurrent) return SpaceFormLoad<T>(SpaceFormLoadKind.identityChanged);
    final result = await _get(withTsdmAppJson(url));
    if (!isCurrent) return SpaceFormLoad<T>(SpaceFormLoadKind.identityChanged);
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value):
        error('failed to load $url: $value');
        return SpaceFormLoad<T>(SpaceFormLoadKind.failed);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(response.data)) {
      return SpaceFormLoad<T>(SpaceFormLoadKind.failed);
    }
    final page = parse(tsdmAppPageDocument(response.data));
    final form = page.form;
    if (form != null) {
      return servedTo(form) == _ownerUid
          ? SpaceFormLoad<T>(SpaceFormLoadKind.ready, form: form)
          : SpaceFormLoad<T>(SpaceFormLoadKind.identityChanged);
    }
    if (page.needLogin) return SpaceFormLoad<T>(SpaceFormLoadKind.loginRequired);
    if (page.message case final String message when message.isNotEmpty) {
      return SpaceFormLoad<T>(SpaceFormLoadKind.denied, message: message);
    }
    return SpaceFormLoad<T>(SpaceFormLoadKind.failed);
  }

  /// Load the new blog form.
  Future<SpaceFormLoad<BlogPostForm>> loadBlogForm() => _loadForm(blogFormUrl, parseBlogPostForm, (e) => e.uid);

  /// Load the album upload page; [albumId] preselects that album as the website's "上传" link of an album does.
  Future<SpaceFormLoad<AlbumUploadForm>> loadUploadForm({int? albumId}) => _loadForm(
    albumId == null ? uploadFormUrl : '$uploadFormUrl&albumid=$albumId',
    parseAlbumUploadForm,
    (e) => e.uid,
  );

  /// The fields posting [draft] with [form] sends: the content as plain text ([spaceBlogPlainText], `plaintext=1`),
  /// a new category as `new:NAME` (what the website's "+新建分类" sends).
  static Map<String, String> blogBody(BlogPostForm form, BlogDraft draft) {
    final newCategory = draft.newCategory?.trim();
    return {
      'formhash': form.formHash,
      'blogsubmit': 'true',
      'subject': draft.subject.trim(),
      'message': spaceBlogPlainText(draft.message),
      'plaintext': '1',
      'classid': newCategory != null && newCategory.isNotEmpty ? 'new:$newCategory' : (draft.category ?? '0'),
      'friend': draft.privacy,
      if (draft.privacy == '4') 'password': draft.password ?? '',
      'tags': '',
      if (draft.systemCategory != null) 'catid': draft.systemCategory!,
    };
  }

  /// Post the blog [draft] with [form], once.
  ///
  /// The forum's app API (plugin 2.6.0) answers the result as JSON ([tsdmAppWriteResultOf]): the forum goes on to the
  /// new blog (`do_success`, a redirect to `do=blog&id=N`), or shows its refusal (`operating_too_fast`,
  /// `no_authority_to_add_log`…) or the captcha it asks for. Without the plugin the redirect (not followed) or the
  /// 提示信息 page is read.
  Future<SpaceWriteResult> postBlog(BlogPostForm form, BlogDraft draft) async {
    if (!isCurrent || form.uid != _ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    final result = await _post(blogSubmitUrl, blogBody(form, draft));
    return _classify(result, spaceBlogIdOfUrl, success: const {'do_success'});
  }

  /// Upload the picture at [path] with the upload page [form], once: the `picid` the forum gave it.
  ///
  /// Refused before anything is sent when the forum takes no such file or not one this large ([fileSize] tells the
  /// size of a file in bytes, the file system's by default), or when the account changed.
  Future<Either<SpaceUploadRefusal, int>> uploadPhoto(
    AlbumUploadForm form,
    String path, {
    int Function(String path)? fileSize,
  }) async {
    // The uploader takes the account from the posted `uid` and `hash`, not from the session: both must be the owner's.
    if (!isCurrent || form.uid != _ownerUid || form.uploadUid != '$_ownerUid') {
      return left(SpaceUploadRefusal.identityChanged);
    }
    final filename = path.split(RegExp(r'[/\\]')).last;
    if (!form.accepts(filename)) return left(SpaceUploadRefusal.type);
    final maxKb = form.maxKb;
    final size = fileSize != null ? fileSize(path) : await _fileSize(path);
    // A file that cannot be read is not sent.
    if (size == null) return left(SpaceUploadRefusal.failed);
    if (maxKb != null && maxKb > 0 && size > maxKb * 1024) return left(SpaceUploadRefusal.size);
    final result = await _sendFile(
      form.uploadUrl,
      {'uid': form.uploadUid, 'hash': form.uploadHash},
      MultipartFilePart(path: path, filename: filename, contentType: imageContentTypeOf(filename)),
    );
    switch (result) {
      case Left(:final value):
        error('picture upload failed: $value');
        return left(SpaceUploadRefusal.failed);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(SpaceUploadRefusal.failed);
      case Right(:final value):
        final picId = parseAlbumUploadAnswer(value.data);
        return picId == null ? left(SpaceUploadRefusal.rejected) : right(picId);
    }
  }

  static Future<int?> _fileSize(String path) async {
    try {
      return await File(path).length();
    } on Object {
      return null;
    }
  }

  /// The fields filing [picIds] to [target] with [form] sends.
  static Map<String, String> albumBody(AlbumUploadForm form, List<int> picIds, AlbumTarget target) => {
    'formhash': form.formHash,
    'albumsubmit': 'true',
    for (final id in picIds) 'title[$id]': '',
    if (target.newAlbumName case final String name) ...{
      'albumop': 'creatalbum',
      'albumname': name.trim(),
      'depict': '',
      'friend': target.privacy,
      if (target.privacy == '4') 'password': target.password ?? '',
    } else ...{
      'albumop': 'selectalbum',
      'albumid': target.albumId ?? '0',
    },
  };

  /// File the uploaded pictures [picIds] to [target], once.
  ///
  /// Answered `upload_images_completed` with the album to go on to (`do=album&id=N`) when filed.
  Future<SpaceWriteResult> fileUploads(AlbumUploadForm form, List<int> picIds, AlbumTarget target) async {
    if (!isCurrent || form.uid != _ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    if (picIds.isEmpty) return const SpaceWriteResult(SpaceWriteOutcome.rejected);
    final result = await _post(uploadSubmitUrl, albumBody(form, picIds, target));
    return _classify(result, spaceAlbumIdOfUrl, success: const {'upload_images_completed', 'do_success'});
  }

  /// The outcome of the answer [result] of a post: the id read from the url the forum goes on to by [idOf].
  SpaceWriteResult _classify(
    SyncEither<Response<dynamic>> result,
    int? Function(String? url) idOf, {
    required Set<String> success,
  }) {
    final Response<dynamic> response;
    switch (result) {
      case Left(value: IdentityChangedException()):
        return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
      case Left(:final value)
          when value is HttpHandshakeFailedException && const [301, 302, 303].contains(value.statusCode):
        return _redirected(idOf(value.headers?.value('location')));
      case Left(:final value):
        // The request may still have reached the forum.
        error('post failed, result unknown: $value');
        return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
      case Right(:final value):
        response = value;
    }
    if (const [301, 302, 303].contains(response.statusCode)) {
      return _redirected(idOf(response.headers.value('location')));
    }
    final api = response.statusCode == HttpStatus.ok ? tsdmAppWriteResultOf(response.data) : null;
    if (api != null) {
      if (api.asksVerification) {
        return SpaceWriteResult(SpaceWriteOutcome.rejected, message: t.postEditPage.verificationRequired);
      }
      if (api.login) {
        return SpaceWriteResult(SpaceWriteOutcome.loginRequired, message: api.reason);
      }
      final id = idOf(api.url);
      if (success.contains(api.messageKey) || (api.kind == TsdmAppWriteKind.redirect && api.ok && id != null)) {
        return SpaceWriteResult(SpaceWriteOutcome.done, id: id, message: api.message.isEmpty ? null : api.message);
      }
      if (api.isError || (api.kind == TsdmAppWriteKind.message && !api.ok)) {
        return SpaceWriteResult(SpaceWriteOutcome.rejected, message: api.reason);
      }
      return SpaceWriteResult(SpaceWriteOutcome.unconfirmed, message: api.reason.isEmpty ? null : api.reason);
    }
    if (response.statusCode != HttpStatus.ok || response.data is! String) {
      return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
    }
    final message = parseHtmlDocument(response.data as String).querySelector('div#messagetext');
    if (message == null) return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
    final text = (message.querySelector('p') ?? message).text?.trim() ?? '';
    if (message.classes.contains('alert_error')) {
      return SpaceWriteResult(SpaceWriteOutcome.rejected, message: text);
    }
    final id = idOf(message.querySelector('p.alert_btnleft a[href]')?.attributes['href']);
    return id != null
        ? SpaceWriteResult(SpaceWriteOutcome.done, id: id, message: text.isEmpty ? null : text)
        : SpaceWriteResult(SpaceWriteOutcome.unconfirmed, message: text.isEmpty ? null : text);
  }

  SpaceWriteResult _redirected(int? id) => id != null
      ? SpaceWriteResult(SpaceWriteOutcome.done, id: id)
      : const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
}
