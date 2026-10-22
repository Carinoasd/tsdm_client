# Render regression tools

The post content of the app is compared with the forum's web page, floor by floor: what text is shown, its line
breaks and paragraphs, its style, tables and blocks. `test/regression/test_234_render_regression_test.dart` does it
in CI on a small synthetic corpus; the tools here make that corpus and the web page's answer for it, and run the same
comparison on a full corpus of real threads, locally.

The full corpus is real posts of the forum. It never goes into the repository (nor do the lists naming its floors):
keep it in a directory of its own outside the repository.

## What is in the repository

`test/data/render_regression/`:

* `floors/c*.html`: floors made from real ones by `make_corpus.py`, picked for what they hold (see `manifest.json`),
  their text, names, numbers, links and images made up, their style sheets cut to what is compared (the docstring
  of `make_corpus.py` says what is kept and how it is checked);
* `floors/h*.html`: the floors written by hand in `tools/render_regression/hand` for what the real ones did not
  have, their text made up the same way (any Chinese text has words of the forum's posts in it);
* `web.json`: what the web page shows of each floor, read by `web_snapshot.mjs`;
* `baseline.json`: the differences each floor still has, by kind (the test fails on more, says so on fewer).

`test/regression/render_regression/`: the comparison (`compare.dart`, which also says what is not compared, on
purpose), the reading of the app's widget tree (`dump.dart`), how a floor is shown (`harness.dart`).

## Running the test

```sh
flutter test test/regression/test_234_render_regression_test.dart
```

Options (`--dart-define`):

* `RENDER_REGRESSION_UPDATE=true`: write `baseline.json` from this run instead of checking it.

The test fails on a floor with more differences of a kind than its baseline, and only prints the floors with fewer
(`fewer differences than the baseline`): when a change shows floors better, run the test with
`RENDER_REGRESSION_UPDATE=true` and commit the new `baseline.json` with the change, after checking in its diff that
only counts went down (or a kind went away). A baseline left higher than it needs to be lets the floor slip back
that far unnoticed.
* `RENDER_REGRESSION_DUMP=<dir>`: write what the app shows of each floor (light and dark), its counts and an example
  of each kind to `<dir>/<id>.json`.

## The full corpus

A directory holding:

* `threads/<tid>.html`: a thread's page as the forum serves it to a guest;
* `threads/<tid>.json`: the app API's answer for the same page;
* `assets/index.json` and the files it names: the forum's style sheets and scripts the pages load, by their path on
  the forum (`{"data/cache/style_42_common.css": "data_cache_style_42_common.css", …}`);
* optionally an image list `{"<url>": {"w": …, "h": …}}` with the size of the images of the posts (1000 × 700 for
  the others), and a `fonts.conf` for the fonts the forum's css names (the comparison does not depend on them).

The tools need Node.js with Playwright (`npm i playwright` in this directory, or `PLAYWRIGHT_MODULE=<path to
playwright/index.mjs>`) and Python 3 (no packages). Nothing is fetched: the browser is answered from the corpus.

### Comparing the full corpus

```sh
node tools/render_regression/web_snapshot.mjs --corpus <corpus> --full --out <out> [--images <images.json>] \
  [--fonts <fonts.conf>] [tid ...]
flutter test tools/render_regression/full_corpus_test.dart \
  --dart-define=RENDER_CORPUS=<corpus> --dart-define=RENDER_OUT=<out> [--dart-define=RENDER_IMAGES=<images.json>]
```

`<out>/web/<tid>.json` is the web page's answer for each thread; `<out>/compare/<tid>.json` the differences of each
floor (counts, an example of each kind, what was tolerated); `<out>/summary.json` the counts of the whole corpus, the
number of floors with each kind and the floors with the most. On a hundred threads (about 900 floors) the web pages
take about three minutes, the app about two and a half.

The audit tool the comparison was first made with (outside the repository, with its own `compare.py` and
`summarize.py`) reads the same corpus; `compare.dart` gives the same counts as its `compare.py` for content, line
breaks, style and spaces, and reads the folds a post makes itself and the jammer text as said in `compare.dart`.

### Making the synthetic corpus again

1. Pick the floors: a `selection.json` outside the repository,
   `[{"tid": "…", "pid": "…", "feats": ["table", "D:br:missing", …]}, …]`. The audit picked them greedily so that
   every feature of a floor (tags, blocks, tables, styles, long paragraphs) and every kind of difference still left
   is held by a few floors, small floors first, at most two more from a thread.
2. Make the floors (`floors/*.html` and `manifest.json` are written again):

   ```sh
   python3 tools/render_regression/make_corpus.py --threads <corpus>/threads --select <selection.json> \
     [--images <images.json>] --hand tools/render_regression/hand --out test/data/render_regression
   ```

   It stops on a floor it cannot make clean: four Chinese characters in a row of any post of the corpus, the name
   of a member, a number of five digits or more of the floor, an ascii name only one or two threads use. Colors
   (`#e93333`) and the words of html and css (`controls`, `source`) stay.
3. Read the web page's answer: `node tools/render_regression/web_snapshot.mjs --corpus <corpus>` (the floors are
   each put in a thread page of the corpus, `--skeleton <tid>` to choose it).
4. Write the baseline: run the test with `RENDER_REGRESSION_UPDATE=true`.
5. Before committing, check the diff holds nothing of the forum's members or of this machine: no names of the
   corpus' authors, no addresses, no local paths.

A floor written by hand goes to `tools/render_regression/hand/h<NN>-<what>.html` (the forum's markup: `<div
class="t_fsz"><table><tr><td class="t_f" id="postmessage_<a made up pid>">…</td></tr></table></div>`), then steps 2
to 4. `.gitattributes` keeps the corpus' line endings as they are made (`-text`).
