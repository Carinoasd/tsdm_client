/// When the pictures of the posts load by themselves: the data saver of the thread page.
///
/// Stored by its index (`SettingsKeys.postImageAutoLoad`). A picture that does not load by itself shows a placeholder
/// to tap; one already cached shows whatever this says, it costs no data.
enum PostImageAutoLoad {
  /// Always, as before.
  always,

  /// Only on a network that is not metered (Wi-Fi, ethernet): not on mobile data or a hotspot.
  wifiOnly,

  /// Never: each picture loads when tapped.
  never
  ;

  /// The value stored as [index]; [always] for anything else (a backup from a newer version).
  static PostImageAutoLoad fromIndex(int index) =>
      index >= 0 && index < values.length ? values[index] : PostImageAutoLoad.always;
}
