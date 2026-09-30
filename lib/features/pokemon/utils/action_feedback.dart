import 'package:flutter/material.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/cubit/pokemon_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Run a pokemon action and show the app's standard floating snack bar with its result.
///
/// The action refreshes whatever it changed itself (the cubit reloads the affected slices in place), so this helper
/// only reports the outcome.
Future<void> runPokemonAction(BuildContext context, Future<PokemonActionResult> Function() action) async {
  final result = await action();
  if (!context.mounted) return;
  final tr = context.t.pokemon;
  final message = result.success
      ? (result.message ?? tr.actionSuccess)
      : pokemonMessageHint(context, result.message ?? context.t.general.networkError);
  showSnackBar(context: context, message: message);
}

/// Whether a pokemon api failure says the battling pet must be healed first.
///
/// The plugin refuses to start a fight while the first pet is fainted or in an abnormal state, and points at the
/// pokemon center. The client can heal it itself (the heal is free), so this is the signal to do that and try again.
bool petNeedsHealingMessage(String? message) =>
    message != null && (message.contains('请先前往宠物中心治疗') || message.contains('已晕倒'));

/// Whether a pokemon api failure says the battling pet must be healed first.
bool petNeedsHealingError(Object? error) => error is PokemonApiException && petNeedsHealingMessage(error.message);

/// Whether a pokemon api failure says the battle is over.
///
/// `heal_and_flee` answers `不在战斗中` when the fight is already gone, and a turn answers the English
/// `No active battle found` — the plugin has no battle to work on either way, so the client should stop fighting.
bool battleAlreadyOverMessage(String? message) =>
    message != null && (message.contains('不在战斗中') || message.contains('No active battle'));

/// Whether [error] is the "battle was already over" failure.
bool battleAlreadyOverError(Object? error) =>
    error is PokemonApiException && battleAlreadyOverMessage(error.message);

/// User-facing text for a pokemon api failure.
///
/// The server's own message is shown verbatim for a business error; anything else (timeouts, handshake failures,
/// decode errors) becomes a generic network hint, so no raw exception text like `<unknown error>` reaches the user.
String pokemonErrorText(BuildContext context, Object error) => error is PokemonApiException
    // The login guard's own code is more reliable than its text (the plugin does not send codes for its other errors).
    ? (error.code == 401 ? context.t.pokemon.loginRequired : pokemonMessageHint(context, error.message ?? context.t.pokemon.actionFailed))
    : context.t.general.networkError;

/// Localize the plugin's error texts, and rewrite the ones the player needs an explanation for.
///
/// The plugin answers several skill errors and the box-capacity error in English, or without saying what to do, so map
/// them to plain localized text. Every other message passes through unchanged.
///
/// These are text matches on purpose: the plugin sends no stable code for these failures (see the issue asking it to),
/// and the call sites that only have a message — a snack bar text, a `PokemonActionResult.message` — have nothing else to
/// go by. Callers holding the exception itself should look at `error.code` first, like [pokemonErrorText] does.
String pokemonMessageHint(BuildContext context, String message) {
  final tr = context.t.pokemon;
  // The plugin's API refuses a request without the session formhash; the client reads it again and retries, so this
  // only shows when that did not help either.
  if (message.contains('formhash')) return tr.formHashFailed;
  // A session that ran out is answered by the login guard (401 or, on newer builds, a bodyless 403), and reads better
  // as the login prompt than as its raw text.
  if (message.contains('需要登录') || message.contains('请先登录')) return tr.loginRequired;
  // The plugin answers an action its build does not implement with a plain English "Invalid action", so say what is
  // really wrong instead of showing that.
  if (message.contains('Invalid action')) return tr.actionUnsupported;
  // The server answers this when it no longer has the battle (it ended on its own, or another client took it over),
  // which is not a network problem: say what happened instead of showing the raw English.
  if (message.contains('No active battle')) return tr.battleEnded;
  if (message.contains('Skill slots are full')) return tr.skillSlotsFull;
  if (message.contains('PP not full')) return tr.skillPpNotFull;
  if (message.contains('during battle')) return tr.skillInBattle;
  if (message.contains('Level requirement not met')) return tr.skillLevelTooLow;
  if (message.contains('cannot be learned by this pokemon')) return tr.skillNotLearnable;
  if (message.contains('already learned')) return tr.skillAlreadyLearned;
  // The box capacity counts every owned pokemon (bag and storage), so moving pokemon into the storage never frees room.
  if (message.contains('容量') || message.contains('数量已满') || message.contains('箱子')) return tr.boxFullHint;
  return message;
}
