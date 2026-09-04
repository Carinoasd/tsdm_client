import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:universal_html/html.dart' as uh;

part 'pokemon.mapper.dart';

/// Pokemon status in the current post floor..
@MappableClass()
final class PostFloorPokemon with PostFloorPokemonMappable {
  /// Constructor
  const PostFloorPokemon(this.primaryPokemon, this.otherPokemon);

  /// The pokemon at the first place.
  final PokemonInfo primaryPokemon;

  /// All other pokemon shown.
  final List<PokemonInfo>? otherPokemon;

  /// Build instance from `div.tsdm_pokemon` node.
  static PostFloorPokemon? fromDiv(uh.Element element) {
    // showWindow('pokemon','plugin.php?id=pokemon:pokemon&index=ajax_pm&petid=${ID}&action=show&cshu=2')
    final firstDetailInfo = element
        .querySelector('a:nth-child(1)')
        ?.attributes['onclick']
        ?.split("'")
        .elementAtOrNull(3);
    final firstImage = element.querySelector('a:nth-child(1) > img')?.imageUrl();
    final firstName = element.querySelector('p:nth-child(2)')?.innerText;
    final PokemonInfo? firstPokemon;
    if (firstDetailInfo != null && firstImage != null && firstName != null) {
      firstPokemon = PokemonInfo(name: firstName, image: firstImage, detailInfo: firstDetailInfo);
    } else {
      firstPokemon = null;
    }

    final others = element
        .querySelectorAll('p:nth-child(3) > a')
        .map((e) {
          final detailIngo = e.attributes['onclick']?.split("'").elementAtOrNull(3);
          final image = e.querySelector('img')?.imageUrl();
          final name = e.querySelector('img')?.attributes['title'];
          if (detailIngo != null && image != null && name != null) {
            return PokemonInfo(name: name, image: image, detailInfo: detailIngo);
          }
          return null;
        })
        .whereType<PokemonInfo>()
        .toList();

    if (firstPokemon == null) {
      return null;
    }

    return PostFloorPokemon(firstPokemon, others);
  }

  /// Build instance from the Discuz X5 style `div.tns` node in the user info column of post floor.
  ///
  /// ```html
  /// <div class="tns xg2">
  ///   <div style="...">
  ///     <a href="plugin.php?id=pokemon:game" target="_blank">
  ///       <img src="${PRIMARY_IMAGE}" ...>
  ///     </a>
  ///     <div style="...">${PRIMARY_NAME}</div>
  ///   </div>
  ///   <div style="...">
  ///     <a href="plugin.php?id=pokemon:pokemon&index=ajax_pm&petid=${ID}&action=show&cshu=2" ...>
  ///       <img src="${IMAGE}" title="${NAME}">
  ///     </a>
  ///     ...
  ///   </div>
  /// </div>
  /// ```
  ///
  /// The detail info dialog of pokemon plugin is gone on server side, [PokemonInfo.detailInfo] only carries the
  /// original url in `href` and is not expected to work.
  static PostFloorPokemon? fromTnsDiv(uh.Element element) {
    final primaryLink = element.querySelector('a[href*="pokemon:game"]');
    final primaryImage = primaryLink?.querySelector('img')?.imageUrl();
    final primaryName = primaryLink?.parent?.querySelector('div')?.innerText.trim();
    if (primaryImage == null || primaryName == null) {
      return null;
    }
    final firstPokemon = PokemonInfo(
      name: primaryName,
      image: primaryImage,
      detailInfo: primaryLink?.attributes['href'] ?? '',
    );

    final others = element
        .querySelectorAll('a[href*="pokemon:pokemon"]')
        .map((e) {
          final image = e.querySelector('img')?.imageUrl();
          final name = e.querySelector('img')?.attributes['title']?.trim();
          if (image != null && name != null) {
            return PokemonInfo(name: name, image: image, detailInfo: e.attributes['href'] ?? '');
          }
          return null;
        })
        .whereType<PokemonInfo>()
        .toList();

    return PostFloorPokemon(firstPokemon, others.isEmpty ? null : others);
  }
}

/// Info about a single pokemon
@MappableClass()
final class PokemonInfo with PokemonInfoMappable {
  /// Constructor.
  const PokemonInfo({required this.name, required this.image, required this.detailInfo});

  /// Pokemon name.
  final String name;

  /// Url of pokemon appearance image.
  final String image;

  /// Url of detail info dialog.
  final String detailInfo;
}
