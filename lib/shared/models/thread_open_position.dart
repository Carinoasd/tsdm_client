/// Where a thread read before opens from a list (`SettingsKeys.threadOpenPosition`, stored as [index]).
enum ThreadOpenPosition {
  /// At its start, as a thread never read.
  fromStart,

  /// At its start, offering to go on where the reading stopped (the default).
  ask,

  /// Where the reading stopped.
  resume
  ;

  /// The value stored as [index], [ask] for anything else.
  static ThreadOpenPosition fromIndex(int index) =>
      index >= 0 && index < values.length ? values[index] : ThreadOpenPosition.ask;
}
