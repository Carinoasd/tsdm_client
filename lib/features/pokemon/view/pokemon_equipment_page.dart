import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/pokemon_repository.dart';
import 'package:tsdm_client/features/pokemon/utils/action_feedback.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_dialogs.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_image.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Equipment page of one pokemon: four slots, owned equipment and the equipment shop.
class PokemonEquipmentPage extends StatefulWidget {
  /// Constructor.
  const PokemonEquipmentPage({required this.pokemon, super.key});

  /// The pokemon whose equipment is managed.
  final Pokemon pokemon;

  @override
  State<PokemonEquipmentPage> createState() => _PokemonEquipmentPageState();
}

class _PokemonEquipmentPageState extends State<PokemonEquipmentPage> {
  final PokemonRepository _repository = PokemonRepository();
  EquipmentResponse? _data;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Load the equipment; when [silent] the page keeps showing the current data instead of flashing a spinner.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    final result = await _repository.getEquipment(widget.pokemon.id).run();
    if (!mounted) return;
    result.fold(
      (_) => setState(() {
        if (silent && _data != null) return;
        _loading = false;
        _failed = true;
      }),
      (data) => setState(() {
        _data = data;
        _loading = false;
        _failed = false;
      }),
    );
  }

  /// Run a void action, report its message and reload on success.
  Future<void> _run(AsyncVoidEither Function() action, String successMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action().run();
      if (!mounted) return;
      result.fold((e) => _showSnack(pokemonErrorText(context, e)), (_) => _showSnack(successMessage));
      if (result.isRight()) await _load(silent: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unequip(EquipmentSlot slot) async {
    final tr = context.t.pokemon;
    final confirmed = await showPokemonConfirmDialog(
      context: context,
      icon: Icons.remove_circle_outline,
      title: tr.unequip,
      message: '${tr.unequip}「${slot.item?.name ?? ''}」',
      confirmLabel: tr.unequip,
    );
    if (!confirmed || !mounted) return;
    await _run(() => _repository.unequipItem(widget.pokemon.id, slot.slotIndex), tr.actionSuccess);
  }

  Future<void> _equip(OwnedEquipment item) async {
    final tr = context.t.pokemon;
    if (item.availableCount <= 0) {
      _showSnack(tr.noEquipment);
      return;
    }
    await _run(() => _repository.equipItem(widget.pokemon.id, item.myitemId), tr.actionSuccess);
  }

  /// Pick owned equipment to equip into a specific (empty) [slot].
  Future<void> _pickForSlot(EquipmentSlot slot) async {
    final tr = context.t.pokemon;
    final data = _data;
    if (data == null) return;
    final candidates = data.ownedItems.where((e) => e.availableCount > 0).toList();
    if (candidates.isEmpty) {
      _showSnack(tr.noEquipment);
      return;
    }
    final picked = await showModalBottomSheet<OwnedEquipment>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(tr.equipSlot(index: slot.slotIndex + 1))),
            const Divider(height: 1),
            for (final item in candidates)
              ListTile(
                leading: _itemLeading(item.image),
                title: Text(item.name),
                subtitle: Text(_bonus(context, item)),
                onTap: () => Navigator.of(context).pop(item),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _run(
      () => _repository.equipItem(widget.pokemon.id, picked.myitemId, slotIndex: slot.slotIndex),
      tr.actionSuccess,
    );
  }

  Future<void> _buy(ShopEquipment item) async {
    final tr = context.t.pokemon;
    final confirmed = await showPokemonConfirmDialog(
      context: context,
      icon: Icons.shopping_cart_outlined,
      title: tr.buy,
      message: tr.buyPetConfirm(name: item.name, price: item.price),
      confirmLabel: tr.buy,
    );
    if (!confirmed || !mounted) return;
    await _run(() => _repository.buy(item.typeId, 1), tr.actionSuccess);
  }

  void _showSnack(String? message) {
    showSnackBar(context: context, message: message ?? context.t.pokemon.actionFailed);
  }

  /// Human readable bonus text of an equipment.
  String _bonus(BuildContext context, EquipmentBonus e) {
    final t = context.t.pokemon;
    return [
      if (e.equipmentHp != 0) '${t.hp}+${e.equipmentHp}',
      if (e.equipmentAtk != 0) '${t.attack}+${e.equipmentAtk}',
      if (e.equipmentDef != 0) '${t.defense}+${e.equipmentDef}',
      if (e.equipmentSpatk != 0) '${t.spAttack}+${e.equipmentSpatk}',
      if (e.equipmentSpdef != 0) '${t.spDefense}+${e.equipmentSpdef}',
      if (e.equipmentSd != 0) '${t.speed}+${e.equipmentSd}',
    ].join('  ');
  }

  Widget _itemLeading(String image) => SizedBox(
    width: 40,
    height: 40,
    child: image.isEmpty
        ? const Icon(Icons.shield_outlined)
        : CachedImage(pokemonItemImageUrl(image), width: 40, height: 40, fit: BoxFit.contain),
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pokemon;
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: Text('${tr.equipment} · ${widget.pokemon.displayName}')),
      // A landscape cutout (the front camera) sits on the left or right edge, so inset every side, not just the bottom
      // the way a navigation bar alone would need. The app bar insets itself already.
      body: SafeArea(
        child: _loading
            ? const CenteredCircularIndicator()
            : _failed || data == null
            ? Center(child: TextButton(onPressed: _load, child: Text(context.t.general.retry)))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('${tr.money}: ${data.userMoney}', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  Text(tr.equipmentSlots, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final slot in data.equipmentSlots)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: _itemLeading(slot.item?.image ?? ''),
                      title: Text(slot.item?.name ?? tr.equipSlot(index: slot.slotIndex + 1)),
                      subtitle: slot.item == null ? null : Text(_bonus(context, slot.item!)),
                      trailing: Icon(slot.item == null ? Icons.add_circle_outline : Icons.remove_circle_outline),
                      onTap: _busy
                          ? null
                          : slot.item == null
                          ? () => unawaited(_pickForSlot(slot))
                          : () => unawaited(_unequip(slot)),
                    ),
                  const SizedBox(height: 16),
                  Text(tr.ownedEquipment, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (data.ownedItems.isEmpty)
                    Text(tr.noEquipment)
                  else
                    for (final item in data.ownedItems)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: _itemLeading(item.image),
                        title: Text(item.name),
                        subtitle: Text(
                          '${_bonus(context, item)}  ×${item.availableCount}/${item.quantity}'
                          '${item.isEquipped ? ' · ${tr.equipped}' : ''}',
                        ),
                        trailing: const Icon(Icons.add_circle_outline),
                        onTap: _busy || item.availableCount <= 0 ? null : () => unawaited(_equip(item)),
                      ),
                  const SizedBox(height: 16),
                  Text(tr.equipmentShop, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (data.shopItems.isEmpty)
                    Text(tr.noEquipment)
                  else
                    for (final item in data.shopItems)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: _itemLeading(item.image),
                        title: Text(item.name),
                        subtitle: Text('${_bonus(context, item)}  ${tr.price}: ${item.price}'),
                        trailing: FilledButton.tonal(
                          onPressed: _busy || !item.canBuy ? null : () => unawaited(_buy(item)),
                          child: Text(tr.buy),
                        ),
                      ),
                ],
              ),
      ),
    );
  }
}
