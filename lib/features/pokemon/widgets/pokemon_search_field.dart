import 'package:flutter/material.dart';

/// The standard pokemon search field used by the inventory, the shop, the pokemon center and the storage.
///
/// It owns its controller and clear button, and reports the trimmed query through [onChanged], so callers only keep the
/// current query string instead of another controller.
class PokemonSearchField extends StatefulWidget {
  /// Constructor.
  const PokemonSearchField({required this.hintText, required this.onChanged, super.key});

  /// Placeholder shown while the field is empty.
  final String hintText;

  /// Called with the trimmed query whenever it changes, including when the field is cleared.
  final ValueChanged<String> onChanged;

  @override
  State<PokemonSearchField> createState() => _PokemonSearchFieldState();
}

class _PokemonSearchFieldState extends State<PokemonSearchField> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Report the new value and keep the clear button in sync.
  void _update(String value) {
    setState(() => _hasText = value.isNotEmpty);
    widget.onChanged(value.trim());
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: _update,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        hintText: widget.hintText,
        suffixIcon: _hasText
            ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _controller.clear();
                  _update('');
                },
              )
            : null,
      ),
    );
  }
}
