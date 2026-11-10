import 'package:flutter/foundation.dart';

/// Where a download of an attachment is.
enum AttachmentDownloadStatus {
  /// Waiting for a free slot.
  queued,

  /// Being fetched.
  running,

  /// Saved.
  completed,

  /// Stopped by an error or the forum's refusal ([AttachmentDownload.message]).
  failed,

  /// Stopped by the user.
  cancelled
  ;

  /// Still going: queued or running.
  bool get active => this == queued || this == running;
}

/// A download of an attachment of the forum (`forum.php?mod=attachment&aid=…`) by account [uid], as the downloads page
/// lists it and the store keeps it (one JSON object, [toJson]).
///
/// [received] and [total] change while it runs and are kept only as they were at the last change of [status].
@immutable
final class AttachmentDownload {
  /// Constructor.
  const AttachmentDownload({
    required this.id,
    required this.uid,
    required this.url,
    required this.filename,
    required this.createdAt,
    this.status = AttachmentDownloadStatus.queued,
    this.size,
    this.tid,
    this.threadTitle,
    this.received = 0,
    this.total,
    this.path,
    this.finishedAt,
    this.message,
    this.purchaseUrl,
    this.notice,
    this.resolvedUrl,
    this.resolvedAt,
  });

  /// From what [toJson] wrote; null when [json] misses what a download needs.
  static AttachmentDownload? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final id = json['id'];
    final uid = json['uid'];
    final url = json['url'];
    final filename = json['filename'];
    final createdAt = json['createdAt'];
    if (id is! String || uid is! int || url is! String || filename is! String || createdAt is! int) {
      return null;
    }
    final status = AttachmentDownloadStatus.values.asNameMap()[json['status']] ?? AttachmentDownloadStatus.failed;
    String? text(String key) => switch (json[key]) {
      final String v when v.isNotEmpty => v,
      _ => null,
    };
    int? number(String key) => switch (json[key]) {
      final int v => v,
      _ => null,
    };
    DateTime? time(String key) => switch (json[key]) {
      final int v => DateTime.fromMillisecondsSinceEpoch(v),
      _ => null,
    };
    return AttachmentDownload(
      id: id,
      uid: uid,
      url: url,
      filename: filename,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      status: status,
      size: number('size'),
      tid: text('tid'),
      threadTitle: text('threadTitle'),
      received: number('received') ?? 0,
      total: number('total'),
      path: text('path'),
      finishedAt: time('finishedAt'),
      message: text('message'),
      purchaseUrl: text('purchaseUrl'),
      notice: text('notice'),
      resolvedUrl: text('resolvedUrl'),
      resolvedAt: time('resolvedAt'),
    );
  }

  /// Unique id.
  final String id;

  /// The account that downloads it.
  final int uid;

  /// The download address the post links to, absolute.
  final String url;

  /// File name: the one the post shows, or the forum's when the post showed none; the saved file may be named apart
  /// when one of this name was there already ([path]).
  final String filename;

  /// When it was asked for.
  final DateTime createdAt;

  /// Where it is.
  final AttachmentDownloadStatus status;

  /// Size in bytes as the post printed it, null when it did not.
  final int? size;

  /// The thread it is in.
  final String? tid;

  /// Title of [tid].
  final String? threadTitle;

  /// Bytes fetched.
  final int received;

  /// Size the forum answered, null when it did not tell.
  final int? total;

  /// The saved file, once [AttachmentDownloadStatus.completed].
  final String? path;

  /// When it was saved or stopped.
  final DateTime? finishedAt;

  /// The forum's words when it refused (no permission, credits asked for…), or the error.
  final String? message;

  /// The purchase of the attachment (`mod=misc&action=attachpay`) the forum asked to go through first.
  final String? purchaseUrl;

  /// What the forum said while handing the file out (`您的 天使币 -1 ，现在将开始下载…`).
  final String? notice;

  /// The download address the forum gave after taking the credits of a download (`…&ck=…`), reused by a retry while
  /// it is valid ([resolvedAt]) so the credits are not taken twice.
  final String? resolvedUrl;

  /// When [resolvedUrl] was given.
  final DateTime? resolvedAt;

  /// The part fetched, null when the size is unknown.
  double? get progress {
    final all = total ?? size;
    if (all == null || all <= 0) {
      return null;
    }
    return (received / all).clamp(0, 1).toDouble();
  }

  /// The size to show: the one the forum answered, the one the post printed, or null.
  int? get shownSize => (total != null && total! > 0) ? total : size;

  /// A copy with the given fields replaced; [clearPath], [clearMessage]… set those to null.
  AttachmentDownload copyWith({
    AttachmentDownloadStatus? status,
    String? filename,
    int? received,
    int? total,
    String? path,
    DateTime? finishedAt,
    String? message,
    String? purchaseUrl,
    String? notice,
    String? resolvedUrl,
    DateTime? resolvedAt,
    bool clearTotal = false,
    bool clearPath = false,
    bool clearFinishedAt = false,
    bool clearMessage = false,
  }) => AttachmentDownload(
    id: id,
    uid: uid,
    url: url,
    filename: filename ?? this.filename,
    createdAt: createdAt,
    status: status ?? this.status,
    size: size,
    tid: tid,
    threadTitle: threadTitle,
    received: received ?? this.received,
    total: clearTotal ? null : (total ?? this.total),
    path: clearPath ? null : (path ?? this.path),
    finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
    message: clearMessage ? null : (message ?? this.message),
    purchaseUrl: clearMessage ? null : (purchaseUrl ?? this.purchaseUrl),
    notice: notice ?? this.notice,
    resolvedUrl: resolvedUrl ?? this.resolvedUrl,
    resolvedAt: resolvedAt ?? this.resolvedAt,
  );

  /// As kept by the store.
  Map<String, dynamic> toJson() => {
    'id': id,
    'uid': uid,
    'url': url,
    'filename': filename,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'status': status.name,
    'size': ?size,
    'tid': ?tid,
    'threadTitle': ?threadTitle,
    'received': received,
    'total': ?total,
    'path': ?path,
    'finishedAt': ?finishedAt?.millisecondsSinceEpoch,
    'message': ?message,
    'purchaseUrl': ?purchaseUrl,
    'notice': ?notice,
    'resolvedUrl': ?resolvedUrl,
    'resolvedAt': ?resolvedAt?.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) => other is AttachmentDownload && mapEquals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().entries.map((e) => Object.hash(e.key, e.value)));
}
