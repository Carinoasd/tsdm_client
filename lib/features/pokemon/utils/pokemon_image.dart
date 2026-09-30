import 'dart:async';

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';

/// CDN base for large pokemon sprites (my pokemon `pm/`, wild back `pmb/`).
const pokemonCdnBase = 'https://img.tsdm39.com/Pokemon';

/// Local images directory served by the forum (small sprites `spm/`, items `item/`).
///
/// The X5 plugin ships them under `plugin/images`, deployed as `source/plugin/pokemon/images`;
/// the X3-era `pokemon_system/images` directory only still answers for a few subfolders.
const pokemonLocalImagesBase = '$baseUrl/source/plugin/pokemon/images';

/// Large sprite of the pokemon species [typeId].
String pokemonImageUrl(int typeId) => '$pokemonCdnBase/pm/$typeId.gif';

/// Back-view sprite used for a wild pokemon in battle.
String pokemonBattleBackImageUrl(int typeId) => '$pokemonCdnBase/pmb/$typeId.gif';

/// Small sprite of the pokemon species [typeId].
String pokemonSmallImageUrl(int typeId) => '$pokemonLocalImagesBase/spm/$typeId.gif';

/// Sprite of the item whose icon filename is [image] (without the `.gif` suffix).
String pokemonItemImageUrl(String image) => '$pokemonLocalImagesBase/item/$image.gif';

/// Warm the given sprite [urls] into the image byte cache, so the battle shows them without a fresh download.
void prefetchPokemonImages(Iterable<String> urls) {
  final cache = getIt.get<ImageCacheProvider>();
  for (final url in urls) {
    unawaited(cache.getOrMakeCache(ImageCacheGeneralRequest(url)));
  }
}
