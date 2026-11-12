#!/usr/bin/env python3
"""Split the Flutter test files into CI shards.

Usage:
  ci_test_shard.py list <total> <index>   print the test files of one shard
  ci_test_shard.py check <total>          verify every file is in exactly one shard

Files are spread by size (largest first, each to the currently lightest shard),
which keeps the shards close in wall time without a timing database. The split
only depends on the file list, so every shard computes the same partition.
Each file still runs in its own isolate, as with a plain `flutter test`.
"""

import os
import sys

TEST_DIR = "test"
# Fixed cost of one test file (compiling and starting the suite), in bytes of source.
PER_FILE_COST = 8000


def test_files():
    files = []
    for root, _dirs, names in os.walk(TEST_DIR):
        for name in names:
            if name.endswith("_test.dart"):
                path = os.path.join(root, name).replace(os.sep, "/")
                files.append((os.path.getsize(path), path))
    # Size descending, path as a stable tie breaker.
    files.sort(key=lambda item: (-item[0], item[1]))
    return files


def partition(total):
    shards = [[] for _ in range(total)]
    weights = [0] * total
    for size, path in test_files():
        lightest = min(range(total), key=lambda i: (weights[i], i))
        shards[lightest].append(path)
        weights[lightest] += size + PER_FILE_COST
    return [sorted(shard) for shard in shards]


def main(argv):
    if len(argv) == 4 and argv[1] == "list":
        total, index = int(argv[2]), int(argv[3])
        if not 0 <= index < total:
            sys.exit(f"shard index {index} out of range for {total} shards")
        print("\n".join(partition(total)[index]))
        return
    if len(argv) == 3 and argv[1] == "check":
        total = int(argv[2])
        shards = partition(total)
        assigned = [path for shard in shards for path in shard]
        expected = [path for _size, path in test_files()]
        if sorted(assigned) != sorted(expected) or len(set(assigned)) != len(assigned):
            sys.exit("shard partition does not cover every test file exactly once")
        for index, shard in enumerate(shards):
            if not shard:
                sys.exit(f"shard {index} is empty")
            print(f"shard {index}: {len(shard)} files")
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
