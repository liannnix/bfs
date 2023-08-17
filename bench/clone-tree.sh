#!/usr/bin/env bash

# Copyright © Tavian Barnes <tavianator@tavianator.com>
# SPDX-License-Identifier: 0BSD

# Creates a directory tree that matches a git repo, but with empty files.  E.g.
#
#     $ ./bench/clone-tree.sh "https://.../linux.git" v6.4 bench/corpus/linux
#
# will create or update a shallow clone at bench/corpus/linux.git, then create a
# directory tree at bench/corpus/linux with the same directory tree as the tag
# v6.4, except all files will be empty.

set -eu

URL="$1"
REF="$2"
DIR="$3"

BIN=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/../bin")
BFS="$BIN/bfs"
XTOUCH="$BIN/tests/xtouch"

if [ -e "$DIR.git" ]; then
    (
        printf 'Updating %s to %s ...\n' "$DIR.git" "$REF" >&2
        cd "$DIR.git"
        git fetch --filter=blob:none --depth=1 origin tag "$REF" --no-tags
    )
else
    printf 'Cloning %s at %s ...\n' "$URL" "$REF" >&2
    git clone --bare --filter=blob:none --depth=1 --branch="$REF" "$URL" "$DIR.git"
fi

# Clean out the old tree, but only if all the files are empty
if [ -e "$DIR" ]; then
    printf 'Cleaning old directory tree at %s ...\n' "$DIR" >&2
    "$BFS" -f "$DIR" -type f \( -empty -delete -or -printf 'Not deleting non-empty file\n' -ls -exit 1 \)
    "$BFS" -f "$DIR" -type d -delete
fi

printf 'Checking out %s tree at %s ...\n' "$REF" "$DIR" >&2
mkdir "$DIR"
(cd "$DIR.git" && git ls-tree -r "$REF" --format="%(path)" -z) | (cd "$DIR" && xargs -0 "$XTOUCH" -p)
