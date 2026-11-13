part of 'dao.dart';

/// DAO for table [CustomImage].
@DriftAccessor(tables: [CustomImage])
final class CustomImageDao extends DatabaseAccessor<AppDatabase> with _$CustomImageDaoMixin {
  /// Constructor.
  CustomImageDao(super.attachedDatabase);

  /// Save [url] with an optional [name] (none: empty for a new image, the name it has for one saved before). An
  /// existing url keeps its row (and its place): saved again, it takes the [name] given and the time of this save in
  /// [CustomImage.addedAt] (the cross-device sync takes the later of two by it, and a save after a deletion on another
  /// device keeps the image).
  Future<int> add({required String url, String? name, DateTime? addedAt}) async {
    final existing = await selectByUrl(url);
    if (existing != null) {
      await (update(customImage)..where((e) => e.id.equals(existing.id))).write(
        CustomImageCompanion(name: Value(name ?? existing.name), addedAt: Value(addedAt ?? DateTime.now())),
      );
      return existing.id;
    }
    final last =
        await (select(customImage)
              ..orderBy([(e) => OrderingTerm.desc(e.sortOrder)])
              ..limit(1))
            .getSingleOrNull();
    return into(customImage).insert(
      CustomImageCompanion(
        name: Value(name ?? ''),
        url: Value(url),
        sortOrder: Value((last?.sortOrder ?? -1) + 1),
        addedAt: Value(addedAt ?? DateTime.now()),
      ),
    );
  }

  /// Save [url] as another device has it (the cross-device sync): its [name] and the time of its last change
  /// [updated] on an existing row (which keeps its place), a new row after the others otherwise.
  Future<void> saveSynced({required String url, required String name, required DateTime updated}) async {
    final existing = await selectByUrl(url);
    if (existing != null) {
      await (update(customImage)..where((e) => e.id.equals(existing.id))).write(
        CustomImageCompanion(name: Value(name), addedAt: Value(updated)),
      );
      return;
    }
    await add(url: url, name: name, addedAt: updated);
  }

  SimpleSelectStatement<$CustomImageTable, CustomImageEntity> _ordered() =>
      select(customImage)..orderBy([(e) => OrderingTerm.asc(e.sortOrder), (e) => OrderingTerm.asc(e.addedAt)]);

  /// All saved images in display order.
  Future<List<CustomImageEntity>> selectAll() async => _ordered().get();

  /// Watch all saved images in display order.
  Stream<List<CustomImageEntity>> watchAll() => _ordered().watch();

  /// The saved image of [url], null when there is none.
  Future<CustomImageEntity?> selectByUrl(String url) async =>
      (select(customImage)..where((e) => e.url.equals(url))).getSingleOrNull();

  /// The saved image with [id], null when there is none.
  Future<CustomImageEntity?> selectById(int id) async =>
      (select(customImage)..where((e) => e.id.equals(id))).getSingleOrNull();

  /// Delete the image with [id].
  Future<int> deleteById(int id) async => (delete(customImage)..where((e) => e.id.equals(id))).go();

  /// Delete the image of [url].
  Future<int> deleteByUrl(String url) async => (delete(customImage)..where((e) => e.url.equals(url))).go();

  /// Delete every saved image.
  Future<int> deleteAll() async => delete(customImage).go();
}
