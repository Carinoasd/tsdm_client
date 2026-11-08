/// What a shortcut does, the key of its description in the list page.
enum KeyboardCommand {
  /// Search page.
  search,

  /// Settings page.
  settings,

  /// Close the dialog on top, or go back.
  back,

  /// Reload the page.
  refresh,

  /// Next floor of a thread.
  nextFloor,

  /// Previous floor of a thread.
  previousFloor,

  /// Next page of a thread or a list.
  nextPage,

  /// Previous page of a thread or a list.
  previousPage,

  /// Reply to the thread.
  reply,

  /// Top of the thread.
  top,

  /// Bottom of the thread.
  bottom,

  /// Copy the link of the thread.
  copyLink,

  /// Next item of a list.
  nextItem,

  /// Previous item of a list.
  previousItem,

  /// Open the item selected.
  openItem,

  /// Send the reply or the post.
  send,

  /// Bold text.
  bold,

  /// Italic text.
  italic,

  /// Underlined text.
  underline,

  /// Close the tab shown.
  closeTab,

  /// Next tab.
  nextTab,

  /// Previous tab.
  previousTab,

  /// The tab of a number.
  selectTab,
}

/// Where a shortcut is in use.
enum KeyboardShortcutGroup {
  /// Every page.
  global,

  /// Thread page.
  thread,

  /// Thread lists.
  list,

  /// The editors.
  editor,

  /// The tabs of the thread beside a list (wide windows).
  tabs,
}

/// The primary modifier of the platform, shown as Ctrl or Cmd.
const String primaryModifierToken = 'mod';

/// One row of the shortcut list.
class KeyboardShortcutEntry {
  /// Constructor.
  const KeyboardShortcutEntry(this.group, this.command, this.alternatives);

  /// Where it works.
  final KeyboardShortcutGroup group;

  /// What it does.
  final KeyboardCommand command;

  /// The key combinations doing it, each a list of key names ([primaryModifierToken] stands for Ctrl or Cmd).
  final List<List<String>> alternatives;
}

/// Every shortcut of the app, in the order of the list page.
const List<KeyboardShortcutEntry> keyboardShortcutCatalog = [
  KeyboardShortcutEntry(KeyboardShortcutGroup.global, KeyboardCommand.search, [
    [primaryModifierToken, 'F'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.global, KeyboardCommand.settings, [
    [primaryModifierToken, ','],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.global, KeyboardCommand.back, [
    ['Esc'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.global, KeyboardCommand.refresh, [
    ['F5'],
    [primaryModifierToken, 'R'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.nextFloor, [
    ['J'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.previousFloor, [
    ['K'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.nextPage, [
    ['N'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.previousPage, [
    ['P'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.reply, [
    ['R'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.top, [
    ['Home'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.bottom, [
    ['End'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.thread, KeyboardCommand.copyLink, [
    [primaryModifierToken, 'Shift', 'C'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.list, KeyboardCommand.nextItem, [
    ['J'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.list, KeyboardCommand.previousItem, [
    ['K'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.list, KeyboardCommand.openItem, [
    ['Enter'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.list, KeyboardCommand.nextPage, [
    ['N'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.list, KeyboardCommand.previousPage, [
    ['P'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.editor, KeyboardCommand.send, [
    [primaryModifierToken, 'Enter'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.editor, KeyboardCommand.bold, [
    [primaryModifierToken, 'B'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.editor, KeyboardCommand.italic, [
    [primaryModifierToken, 'I'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.editor, KeyboardCommand.underline, [
    [primaryModifierToken, 'U'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.tabs, KeyboardCommand.closeTab, [
    [primaryModifierToken, 'W'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.tabs, KeyboardCommand.nextTab, [
    ['Ctrl', 'Tab'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.tabs, KeyboardCommand.previousTab, [
    ['Ctrl', 'Shift', 'Tab'],
  ]),
  KeyboardShortcutEntry(KeyboardShortcutGroup.tabs, KeyboardCommand.selectTab, [
    [primaryModifierToken, '1–9'],
  ]),
];
