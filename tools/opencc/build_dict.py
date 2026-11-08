#!/usr/bin/env python3
"""Builds assets/text/opencc/{s2t,t2s}.txt from the OpenCC dictionaries (Apache-2.0, BYVoid/OpenCC).

Usage: build_dict.py <dir with STCharacters.txt STPhrases.txt TSCharacters.txt TSPhrases.txt> <output dir>

Every line of the output is `source<TAB>target`. Only the first candidate of each entry is kept, and a phrase the character table converts to the same text is
dropped when no overlapping phrase is cut differently without it (see `build`).
"""
import sys
from pathlib import Path


def read(path):
    table = {}
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, values = line.partition('\t')
        table[key] = values.split(' ')[0]
    return table


def convert(table, text, longest):
    """Longest-match conversion, the way the app does it."""
    out, i = [], 0
    while i < len(text):
        for n in range(min(longest, len(text) - i), 0, -1):
            hit = table.get(text[i:i + n])
            if hit is not None:
                out.append(hit)
                i += n
                break
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def build(chars, phrases):
    """The characters and the phrases the longest match needs.

    A phrase the characters convert to the same text is redundant, unless it changes how a neighbouring phrase is
    cut: the longest match takes it where a shorter or an overlapping one would match otherwise. Every phrase that
    is a candidate to be dropped is tried alone and against the phrases it overlaps (one starting inside it, one
    ending inside its start) and kept when the text built from the two converts differently without it.
    """
    full = {k: v for k, v in chars.items() if k != v}
    full.update(phrases)
    # An identity character carries nothing; an identity phrase (皇后) stops the characters from converting.
    full = {k: v for k, v in full.items() if k != v or len(k) > 1}
    longest = max(len(k) for k in full)

    candidates = [
        k for k, v in phrases.items() if len(k) > 1 and k != v and ''.join(chars.get(c, c) for c in k) == v
    ]
    by_prefix, by_suffix = {}, {}
    for key in full:
        if len(key) > 1:
            for t in range(1, len(key)):
                by_prefix.setdefault(key[:t], []).append(key)
                by_suffix.setdefault(key[-t:], []).append(key)

    table = dict(full)
    for key in sorted(candidates, key=len, reverse=True):
        value = table.pop(key)
        # The phrase itself too: a shorter phrase inside it would cut it differently.
        contexts = [key]
        for t in range(1, len(key)):
            for other in by_prefix.get(key[t:], ()):
                if other != key:
                    contexts.append(key + other[len(key) - t:])
            for other in by_suffix.get(key[:t], ()):
                if other != key:
                    contexts.append(other + key[t:])
        if any(convert(table, text, longest) != convert(full, text, longest) for text in contexts):
            table[key] = value
    return table


src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
for name, c, p in (('s2t', 'STCharacters', 'STPhrases'), ('t2s', 'TSCharacters', 'TSPhrases')):
    table = build(read(src / f'{c}.txt'), read(src / f'{p}.txt'))
    lines = sorted(table.items(), key=lambda kv: (len(kv[0]), kv[0]))
    (dst / f'{name}.txt').write_text(''.join(f'{k}\t{v}\n' for k, v in lines), encoding='utf-8')
    print(name, len(lines), 'entries')
