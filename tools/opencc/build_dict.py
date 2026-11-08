#!/usr/bin/env python3
"""Builds assets/text/opencc/{s2t,t2s}.txt from the OpenCC dictionaries (Apache-2.0, BYVoid/OpenCC).

Usage: build_dict.py <dir with STCharacters.txt STPhrases.txt TSCharacters.txt TSPhrases.txt> <output dir>

Every line of the output is `source<TAB>target`. Only the first candidate of each entry is kept, and a phrase that
the character table already converts to the same text is dropped (the converter falls back to characters anyway).
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


def build(chars, phrases):
    out = dict(chars)
    for key, value in phrases.items():
        if ''.join(chars.get(c, c) for c in key) != value:
            out[key] = value
    # An identity entry of a single character carries no information; one of a phrase stops a shorter entry (the
    # character 后 is 後, the phrase 皇后 is not).
    return {k: v for k, v in out.items() if k != v or len(k) > 1}


src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
for name, c, p in (('s2t', 'STCharacters', 'STPhrases'), ('t2s', 'TSCharacters', 'TSPhrases')):
    table = build(read(src / f'{c}.txt'), read(src / f'{p}.txt'))
    lines = sorted(table.items(), key=lambda kv: (len(kv[0]), kv[0]))
    (dst / f'{name}.txt').write_text(''.join(f'{k}\t{v}\n' for k, v in lines), encoding='utf-8')
    print(name, len(lines), 'entries')
