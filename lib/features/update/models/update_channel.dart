/// Where the app asks for the latest version and takes an update's bytes from.
///
/// Stored by index (`SettingsKeys.updateChannel`): append only.
enum UpdateChannel {
  /// Both: GitHub's answer when it can be read and the mirror's otherwise; bytes from the mirror first.
  auto,

  /// The Cloudreve mirror only: no waiting for GitHub where it cannot be reached.
  mirror,

  /// GitHub only.
  github
  ;

  /// The channel stored as [index]; [auto] for a value this version does not know.
  static UpdateChannel of(int index) => index >= 0 && index < values.length ? values[index] : auto;
}
