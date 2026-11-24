import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/features/red_packet/utils/daily_red_packet_record.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Claims today's daily red packet with [formHash], e.g. [RedPacketRepository.claimDaily].
typedef DailyRedPacketClaim = AsyncEither<DailyRedPacketResult> Function(String formHash);

/// App bar button claiming today's daily red packet.
///
/// Shown while the homepage carries the daily red packet config. Once claimed (or when the server says it was already
/// claimed today) the icon button hides itself and the [labeled] one shows the claimed state; neither submits again.
class DailyRedPacketButton extends StatefulWidget {
  /// Constructor.
  const DailyRedPacketButton({
    required this.config,
    required this.formHash,
    this.repository = const RedPacketRepository(),
    this.claim,
    this.labeled = false,
    this.look = AppDayActionLook.button,
    this.onClaimed,
    super.key,
  });

  /// Show a tonal button with a label instead of an icon button, e.g. on the homepage greeting card.
  final bool labeled;

  /// How the [labeled] button is drawn.
  final AppDayActionLook look;

  /// Called with the `dateflag` of the packet once the server answered "claimed" or "already claimed".
  final void Function(String dateFlag)? onClaimed;

  /// Today's packet.
  final DailyRedPacketConfig config;

  /// Form hash of the current session.
  final String formHash;

  /// Repository talking to the plugin.
  final RedPacketRepository repository;

  /// Claim request, [RedPacketRepository.claimDaily] of [repository] when null (tests pass a fake).
  final DailyRedPacketClaim? claim;

  @override
  State<DailyRedPacketButton> createState() => _DailyRedPacketButtonState();
}

class _DailyRedPacketButtonState extends State<DailyRedPacketButton> with LoggerMixin {
  bool _claiming = false;
  bool _claimed = false;

  AsyncEither<DailyRedPacketResult> _claimWithRepository(String formHash) =>
      widget.repository.claimDaily(formHash: formHash);

  Future<void> _claim() async {
    // One request at a time, none after the server confirmed the claim: a second tap in the same frame (before the
    // button is rebuilt disabled) does nothing.
    if (_claiming || _claimed) {
      return;
    }
    final tr = context.t.redPacket.daily;
    setState(() => _claiming = true);
    final request = widget.claim ?? _claimWithRepository;
    final result = await request(widget.formHash).run();
    if (!mounted) {
      return;
    }
    final String message;
    var claimed = false;
    switch (result) {
      case Left(:final value):
        handle(value);
        message = tr.failed(err: value.message ?? '$value');
      case Right(:final value) when value.ok:
        message = tr.claimed(amount: value.amount ?? '?', unit: value.unit ?? widget.config.unit);
        claimed = true;
      case Right(:final value) when value.already:
        message = value.error ?? tr.alreadyClaimed;
        claimed = true;
      case Right(:final value):
        message = tr.failed(err: value.error ?? '');
    }
    setState(() {
      _claiming = false;
      _claimed = claimed;
    });
    if (claimed) {
      widget.onClaimed?.call(widget.config.dateFlag);
    }
    showSnackBar(context: context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = context.t.redPacket.daily.tooltip;
    if (_claimed) {
      return widget.labeled ? DailyRedPacketClaimedButton(look: widget.look) : sizedBoxEmpty;
    }
    if (widget.labeled) {
      return appDayAction(
        context,
        look: widget.look,
        icon: _claiming ? sizedCircularProgressIndicator : const Icon(Icons.redeem_outlined),
        label: tooltip,
        onPressed: _claiming ? null : _claim,
      );
    }
    if (_claiming) {
      return IconButton(icon: sizedCircularProgressIndicator, tooltip: tooltip, onPressed: null);
    }
    return IconButton(icon: const Icon(Icons.redeem_outlined), tooltip: tooltip, onPressed: _claim);
  }
}

/// Today's daily red packet is claimed: a disabled button saying so, with [hint] as tooltip when given.
///
/// Looks done, not unavailable ([appHeroActionStyle]): a full color label and a filled check.
class DailyRedPacketClaimedButton extends StatelessWidget {
  /// Constructor.
  const DailyRedPacketClaimedButton({this.hint, this.look = AppDayActionLook.button, super.key});

  /// Where the claimed state comes from, when it is not the answer of this run.
  final String? hint;

  /// How the button is drawn.
  final AppDayActionLook look;

  @override
  Widget build(BuildContext context) {
    final button = appDayAction(
      context,
      look: look,
      icon: const Icon(Icons.check_circle),
      label: context.t.redPacket.daily.claimedToday,
      onPressed: null,
    );
    final hint = this.hint;
    return hint == null ? button : Tooltip(message: hint, child: button);
  }
}

/// The daily red packet entry of the homepage greeting, always visible with an honest state.
///
/// * No account: says a login is needed and opens the login page.
/// * A packet ([config]) and a [formHash] on the homepage: [DailyRedPacketButton], the real claim flow; it shows the
///   claimed state once the server answered "claimed" or "already claimed" for that packet, and that answer is
///   recorded for the account ([dailyRedPacketClaimKey]).
/// * No packet, and this app recorded a claim of this account for today: "claimed" (feedback 111), the tooltip says
///   the state is the app's record. The site's day is approximated by the local one ([dailyRedPacketClaimedToday]).
/// * No packet and no record: "none now" and a tap checks the packet again ([onCheck], only the packet of the greeting
///   card is updated, never a reload of the whole homepage); the tooltip says it may be claimed already (on the
///   website, unknown here) or not open yet.
///
/// The labels are short enough for one line in the half-width button of phones; the full explanation is the tooltip.
class DailyRedPacketEntry extends StatefulWidget {
  /// Constructor.
  const DailyRedPacketEntry({
    required this.uid,
    required this.config,
    required this.formHash,
    required this.onCheck,
    this.checking = false,
    this.claim,
    this.look = AppDayActionLook.button,
    super.key,
  });

  /// How the entry is drawn: a tile among the actions of the phone greeting, a button elsewhere.
  final AppDayActionLook look;

  /// Logged in account, null without one.
  final int? uid;

  /// Today's packet from the homepage, null when the page had none.
  final DailyRedPacketConfig? config;

  /// Form hash of the homepage.
  final String? formHash;

  /// Check whether the forum offers a packet now, updating only this entry.
  final VoidCallback? onCheck;

  /// A check started by [onCheck] is running: the entry waits for it instead of starting another one.
  final bool checking;

  /// Claim request for [DailyRedPacketButton.claim].
  final DailyRedPacketClaim? claim;

  @override
  State<DailyRedPacketEntry> createState() => _DailyRedPacketEntryState();
}

class _DailyRedPacketEntryState extends State<DailyRedPacketEntry> {
  /// `dateflag` of the packet this app last claimed for [DailyRedPacketEntry.uid], null when none is recorded.
  String? _claimedDateFlag;

  /// The account the record was read for.
  int? _recordUid;

  StorageProvider? get _storage => getIt.isRegistered<StorageProvider>() ? getIt.get<StorageProvider>() : null;

  Future<void> _readRecord() async {
    final uid = widget.uid;
    final storage = _storage;
    _recordUid = uid;
    if (uid == null || storage == null) {
      setState(() => _claimedDateFlag = null);
      return;
    }
    final flag = await storage.getString(dailyRedPacketClaimKey(uid));
    // The account may have changed while reading.
    if (mounted && _recordUid == uid) {
      setState(() => _claimedDateFlag = flag);
    }
  }

  void _onClaimed(String dateFlag) {
    final uid = widget.uid;
    if (uid == null) {
      return;
    }
    setState(() => _claimedDateFlag = dateFlag);
    unawaited(_storage?.saveString(dailyRedPacketClaimKey(uid), dateFlag));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_readRecord());
  }

  @override
  void didUpdateWidget(DailyRedPacketEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      unawaited(_readRecord());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.redPacket.daily;
    final uid = widget.uid;
    final config = widget.config;
    final formHash = widget.formHash;
    if (uid == null) {
      return appDayAction(
        context,
        look: widget.look,
        icon: const Icon(Icons.login_outlined),
        label: tr.needLogin,
        onPressed: () async => context.pushNamed(ScreenPaths.login),
      );
    }
    if (config != null && formHash != null && formHash.isNotEmpty) {
      return DailyRedPacketButton(
        // A new account or a new day starts a new button: nothing of the previous claim state carries over.
        key: ValueKey('dailyRedPacket-$uid-${config.dateFlag}'),
        config: config,
        formHash: formHash,
        claim: widget.claim,
        labeled: true,
        look: widget.look,
        onClaimed: _onClaimed,
      );
    }
    if (_recordUid == uid && dailyRedPacketClaimedToday(_claimedDateFlag)) {
      return DailyRedPacketClaimedButton(
        key: const ValueKey('dailyRedPacket-recorded'),
        hint: tr.claimedRecordedHint,
        look: widget.look,
      );
    }
    return Tooltip(
      message: tr.unavailableHint,
      child: appDayAction(
        context,
        look: widget.look,
        icon: widget.checking ? sizedCircularProgressIndicator : const Icon(Icons.redeem_outlined),
        label: tr.unavailable,
        onPressed: widget.checking ? null : widget.onCheck,
      ),
    );
  }
}
