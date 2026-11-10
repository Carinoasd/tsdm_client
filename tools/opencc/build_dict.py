#!/usr/bin/env python3
"""Builds assets/text/opencc/{s2t,t2s}.txt from the OpenCC dictionaries (Apache-2.0, BYVoid/OpenCC).

Usage: build_dict.py <dir with STCharacters.txt STPhrases.txt TSCharacters.txt TSPhrases.txt> <output dir>

Every line of the output is `source<TAB>target`, shortest sources first. Only the first candidate of each entry is
kept. Nothing else is left out: the app segments text by the longest match as OpenCC does, and a phrase that the
characters would convert to the same text still decides where its neighbours are cut, so dropping such phrases does
not keep the result equal to OpenCC's. The only entries left out are the characters that convert to themselves.
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
    table = dict(chars)
    table.update(phrases)
    # An identity character carries nothing; an identity phrase (皇后) stops the characters from converting.
    return {k: v for k, v in table.items() if k != v or len(k) > 1}


# OpenCC writes 审核 as 審覈 (the old character 覈, nowadays only 核 is used), so the s2t output never uses 覈.
S2T_REPLACEMENTS = {'覈': '核'}


src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
for name, c, p in (('s2t', 'STCharacters', 'STPhrases'), ('t2s', 'TSCharacters', 'TSPhrases')):
    table = build(read(src / f'{c}.txt'), read(src / f'{p}.txt'))
    if name == 's2t':
        for old, new in S2T_REPLACEMENTS.items():
            table = {k: v.replace(old, new) for k, v in table.items()}
    lines = sorted(table.items(), key=lambda kv: (len(kv[0]), kv[0]))
    (dst / f'{name}.txt').write_text(''.join(f'{k}\t{v}\n' for k, v in lines), encoding='utf-8')
    print(name, len(lines), 'entries')
