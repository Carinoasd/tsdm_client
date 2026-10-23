import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:tsdm_client/shared/models/models.dart' hide Cookie;
import 'package:tsdm_client/shared/providers/storage_provider/models/convertable/convertable.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/schema/schema.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/schema/schema_versions.dart';
import 'package:tsdm_client/utils/logger.dart';

// part 'database.g.dart';
part 'database.g.dart';

/// 数据库定义
@DriftDatabase(
  tables: [
    AvatarHistory,
    BroadcastMessage,
    Cookie,
    CustomImage,
    FastRateTemplate,
    FastReplyTemplate,
    Image,
    Notice,
    OfflineThread,
    PersonalMessage,
    RepliedThread,
    Settings,
    ThreadVisitHistory,
    UserAvatar,
  ],
)
final class AppDatabase extends _$AppDatabase with LoggerMixin {
  /// Constructor.
  AppDatabase(super.e);

  @override
  int get schemaVersion => 17;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    // The eviction index of the offline thread pages: a development build at the unreleased shape of schema 15 has the
    // table without it. Looked up on every open (a read, no lock taken when it is there) and created when missing, so
    // no build depends on the step.
    beforeOpen: (details) async {
      final index = offlineThreadRecent;
      final present = await customSelect(
        "SELECT name FROM sqlite_master WHERE name IN ('offline_thread', ?)",
        variables: [Variable.withString(index.entityName)],
      ).map((row) => row.read<String>('name')).get();
      if (!present.contains('offline_thread') || present.contains(index.entityName)) {
        return;
      }
      final create = index.createStatementsByDialect[SqlDialect.sqlite]!;
      await customStatement(create.replaceFirst('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS '));
      info('created the missing index ${index.entityName}');
    },
    onUpgrade: stepByStep(
      from1To2: (m, schema) async {
        info('migrating database schema from 1 to 2...');
        await m.create(schema.threadVisitHistory);
        info('migrating database schema from 1 to 2... ok!');
      },
      from2To3: (m, schema) async {
        info('migrating database schema from 2 to 3...');
        await m.addColumn(schema.settings, schema.settings.offsetValue);
        await m.addColumn(schema.settings, schema.settings.sizeValue);
        await m.addColumn(schema.cookie, schema.cookie.lastCheckin);
        info('migrating database schema from 2 to 3... ok!');
      },
      from3To4: (m, schema) async {
        info('migrating database schema from 3 to 4...');
        await m.createAll();
        await m.addColumn(schema.cookie, schema.cookie.lastFetchNotice);
        await m.dropColumn(schema.cookie, 'email');
        await m.addColumn(schema.imageCache, schema.imageCache.usage);
        info('migrating database schema from 3 to 4... ok!');
      },
      from4To5: (m, schema) async {
        info('migrating database schema from 4 to 5...');
        // Migrate notice table
        await customUpdate(
          'DELETE FROM notice '
          'WHERE (uid, nid) NOT IN ( '
          '    SELECT uid, max(nid) '
          '    FROM notice '
          '    GROUP BY uid '
          ');',
          updates: {schema.notice},
          updateKind: UpdateKind.delete,
        );
        // We are using table migration for old versions.
        // If in a far future the `TableMigration` API is removed, we may also
        // drop support for versions < 1.2.0
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(schema.notice));
        info('migrating database schema from 4 to 5... ok!');
      },
      from5To6: (m, schema) async {
        info('migrating database schema from 5 to 6...');
        // Migrate broadcast message table.
        //
        // This raw sql statement only reserves the latest message in each
        // pair of (uid, peer_uid), which means deleting all duplicate
        // `{uid, peer_uid}` pair while keeping the latest message.
        // So it's safe to change the primary key from `{uid, timestamp}` to
        // `{uid, peer_uid}`.
        await customUpdate(
          'DELETE FROM personal_message '
          'WHERE (uid, peer_uid, timestamp) NOT IN ( '
          '    SELECT uid, peer_uid, max(timestamp) '
          '    FROM personal_message '
          '    GROUP BY uid, peer_uid '
          ');',
          updates: {schema.personalMessage},
          updateKind: UpdateKind.delete,
        );
        // We are using table migration for old versions.
        // If in a far future the `TableMigration` API is removed, we may also
        // drop support for versions < 1.2.0
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(schema.personalMessage));
        // Migrate personal message table.
        await m.addColumn(schema.broadcastMessage, schema.broadcastMessage.alreadyRead);
        await m.addColumn(schema.notice, schema.notice.alreadyRead);
        info('migrating database schema from 5 to 6... ok!');
      },
      from6To7: (m, schema) async {
        info('migrating database schema from 6 to 7...');
        await m.addColumn(schema.userAvatar, schema.userAvatar.imageUrl);
        info('migrating database schema from 6 to 7... ok!');
      },
      from7To8: (m, schema) async {
        info('migrating database schema from 7 to 8...');
        await m.create(schema.avatarHistory);
        await m.create(schema.fastRateTemplate);
        await m.create(schema.fastReplyTemplate);
        info('migrating database schema from 7 to 8... ok!');
      },
      from8To9: (m, schema) async {
        info('migrating database schema from 8 to 9...');
        await m.addColumn(schema.settings, schema.settings.stringListValue);
        await m.addColumn(schema.settings, schema.settings.intListValue);
        info('migrating database schema from 8 to 9... ok!');
      },
      from9To10: (m, schema) async {
        info('migrating database schema from 9 to 10...');
        // Add user identification columns.
        await m.addColumn(schema.cookie, schema.cookie.password);
        await m.addColumn(schema.cookie, schema.cookie.questionId);
        await m.addColumn(schema.cookie, schema.cookie.answer);

        // Recreate template tables.
        // In fact we shall remove uid column and change the primary key in this migration, but these tables were not
        // used before, drop and recreate is safe.
        await m.drop(schema.fastRateTemplate);
        await m.create(schema.fastRateTemplate);
        await m.drop(schema.fastReplyTemplate);
        await m.create(schema.fastReplyTemplate);
        info('migrating database schema from 9 to 10... ok!');
      },
      from10To11: (m, schema) async {
        info('migrating database schema from 10 to 11...');
        await m.addColumn(schema.fastRateTemplate, schema.fastRateTemplate.special2);
        info('migrating database schema from 10 to 11... ok!');
      },
      from11To12: (m, schema) async {
        info('migrating database schema from 11 to 12...');
        // Local "already replied" marks (#21) and the per-account session expiry hint (#25).
        await m.create(schema.repliedThread);
        await m.addColumn(schema.cookie, schema.cookie.sessionExpiredAt);
        info('migrating database schema from 11 to 12... ok!');
      },
      from12To13: (m, schema) async {
        info('migrating database schema from 12 to 13...');
        // The user's own image stickers (#5).
        await m.create(schema.customImage);
        info('migrating database schema from 12 to 13... ok!');
      },
      from13To14: (m, schema) async {
        info('migrating database schema from 13 to 14...');
        // Notice type and author from the notice's ignore link, for blocking and server ignore rules.
        //
        // Each column is added only when missing: after an update the background service isolate may open the file
        // together with the app and run this step too (the new version is written only once the step is done).
        final existing = (await schema.database.customSelect('PRAGMA table_info(notice)').get())
            .map((row) => row.read<String>('name'))
            .toSet();
        for (final column in [schema.notice.ignoreType, schema.notice.authorId]) {
          if (existing.contains(column.name)) {
            continue;
          }
          try {
            await m.addColumn(schema.notice, column);
          } on Object catch (e) {
            // Added by the other connection between the check and here.
            if (!'$e'.contains('duplicate column name')) {
              rethrow;
            }
            info('notice.${column.name} added by another connection');
          }
        }
        info('migrating database schema from 13 to 14... ok!');
      },
      from14To15: (m, schema) async {
        info('migrating database schema from 14 to 15...');
        // Thread pages saved for reading without network, and the index of their eviction. The step runs again safely
        // when the background service isolate opened the file together with the app (see from13To14): drift writes
        // `CREATE TABLE IF NOT EXISTS`, the index is created only when missing.
        await m.create(schema.offlineThread);
        final index = schema.offlineThreadRecent;
        final existing = await schema.database
            .customSelect(
              "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
              variables: [
                Variable.withString(index.entityName),
              ],
            )
            .get();
        if (existing.isEmpty) {
          try {
            await m.create(index);
          } on Object catch (e) {
            // Created by the other connection between the check and here.
            if (!'$e'.contains('already exists')) {
              rethrow;
            }
            info('${index.entityName} created by another connection');
          }
        }
        info('migrating database schema from 14 to 15... ok!');
      },
      from15To16: (m, schema) async {
        info('migrating database schema from 15 to 16...');
        // Author name, `from_id` and `from_idtype` of the notices, for the notice cards and the system notifications.
        // Each column is added only when missing, see from13To14.
        final existing = (await schema.database.customSelect('PRAGMA table_info(notice)').get())
            .map((row) => row.read<String>('name'))
            .toSet();
        for (final column in [schema.notice.author, schema.notice.fromId, schema.notice.fromIdType]) {
          if (existing.contains(column.name)) {
            continue;
          }
          try {
            await m.addColumn(schema.notice, column);
          } on Object catch (e) {
            // Added by the other connection between the check and here.
            if (!'$e'.contains('duplicate column name')) {
              rethrow;
            }
            info('notice.${column.name} added by another connection');
          }
        }
        info('migrating database schema from 15 to 16... ok!');
      },
      from16To17: (m, schema) async {
        info('migrating database schema from 16 to 17...');
        // Where the reading of each visited thread stopped, kept with its visit. Each column is added only when
        // missing, see from13To14.
        final existing = (await schema.database.customSelect('PRAGMA table_info(thread_visit_history)').get())
            .map((row) => row.read<String>('name'))
            .toSet();
        final table = schema.threadVisitHistory;
        for (final column in [table.lastPage, table.lastPid, table.lastFloor, table.seenReplies]) {
          if (existing.contains(column.name)) {
            continue;
          }
          try {
            await m.addColumn(table, column);
          } on Object catch (e) {
            // Added by the other connection between the check and here.
            if (!'$e'.contains('duplicate column name')) {
              rethrow;
            }
            info('thread_visit_history.${column.name} added by another connection');
          }
        }
        info('migrating database schema from 16 to 17... ok!');
      },
    ),
  );
}
