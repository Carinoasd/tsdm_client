import 'package:flutter/foundation.dart';

/// A module of the space the forum may switch off for the whole site.
enum SpaceModule {
  /// The walls (`wallstatus`).
  wall,

  /// The greetings, part of the friends module (`friendstatus`).
  poke,
}

/// The modules of the space the forum said, during this run, are switched off ("抱歉，留言板功能尚未开启"): their entries
/// are no longer offered.
///
/// The profile the app reads (the app API's structured answer) does not carry the links the web page prints for the
/// modules on, so an entry is offered until a page of its module answers that it is off.
final ValueNotifier<Set<SpaceModule>> spaceModulesOff = ValueNotifier(const {});

/// Note that the forum switched [module] off.
void markSpaceModuleOff(SpaceModule module) {
  if (!spaceModulesOff.value.contains(module)) {
    spaceModulesOff.value = {...spaceModulesOff.value, module};
  }
}
