part of 'dao.dart';

/// DAO for table [CustomImage].
@DriftAccessor(tables: [CustomImage])
final class CustomImageDao extends DatabaseAccessor<AppDatabase> with _$CustomImageDaoMixin {
  /// Constructor.
  CustomImageDao(super.attachedDatabase);

  /// Save [url] with an optional [name]; an existing url keeps its row and only updates the name.
  Future<int> add({required String url, String name = '', DateTime? addedAt}) async {
    final existing = await (select(customImage)..where((e) => e.url.equals(url))).getSingleOrNull();
    if (existing != null) {
      await (update(customImage)..where((e) => e.id.equals(existing.id))).write(
        CustomImageCompanion(name: Value(name)),
      );
      return existing.id;
    }
    final last = await (select(customImage)
          ..orderBy([(e) => OrderingTerm.desc(e.sortOrder)])
          ..limit(1))
        .getSingleOrNull();
    return into(customImage).insert(
      CustomImageCompanion(
        name: Value(name),
        url: Value(url),
        sortOrder: Value((last?.sortOrder ?? -1) + 1),
        addedAt: Value(addedAt ?? DateTime.now()),
      ),
    );
  }

  SimpleSelectStatement<$CustomImageTable, CustomImageEntity> _ordered() =>
      select(customImage)..orderBy([(e) => OrderingTerm.asc(e.sortOrder), (e) => OrderingTerm.asc(e.addedAt)]);

  /// All saved images in display order.
  Future<List<CustomImageEntity>> selectAll() async => _ordered().get();

  /// Watch all saved images in display order.
  Stream<List<CustomImageEntity>> watchAll() => _ordered().watch();

  /// Delete the image with [id].
  Future<int> deleteById(int id) async => (delete(customImage)..where((e) => e.id.equals(id))).go();

  /// Delete every saved image.
  Future<int> deleteAll() async => delete(customImage).go();
}
