#!/hint/bash

# Copyright © Tavian Barnes <tavianator@tavianator.com>
# SPDX-License-Identifier: 0BSD

CHROMIUM_URL="https://github.com/chromium/chromium.git"
CHROMIUM_TAG=118.0.5954.1

LINUX_URL="https://github.com/torvalds/linux.git"
LINUX_TAG=v6.4

LLVM_URL="https://github.com/llvm/llvm-project.git"
LLVM_TAG=llvmorg-16.0.6

RUST_URL="https://github.com/rust-lang/rust.git"
RUST_TAG=1.71.0

# Get the url of a corpus
corpus-url() {
    local var="${1^^}_URL"
    printf '%s' "${!var}"
}

# Get the tag of a corpus
corpus-tag() {
    local var="${1^^}_TAG"
    printf '%s' "${!var}"
}

# Get the directory of a corpus
corpus-dir() {
    local var="${1^^}_URL"
    local base="${!var##*/}"
    printf 'bench/corpus/%s' "${base%.git}"
}

# Set up the benchmarks
setup() {
    ROOT=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
    if ! [ "$PWD" -ef "$ROOT" ]; then
        printf 'Please run this script from %s\n' "$ROOT" >&2
        exit $EX_USAGE
    fi

    export FD=0
    export FIND=0

    export COMPLETE=""
    export EARLY_QUIT=""
    export PRINT=""
    export STRATEGIES=""

    nproc=$(nproc)
    commits=()

    for arg; do
        case "$arg" in
            # Utilities to benchmark against
            --fd)
                FD=1
                ;;
            --find)
                FIND=1
                ;;
            # Benchmark groups
            --complete)
                COMPLETE="rust linux llvm chromium"
                ;;
            --complete=*)
                COMPLETE="${arg#*=}"
                ;;
            --early-quit)
                EARLY_QUIT=chromium
                ;;
            --early-quit=*)
                EARLY_QUIT="${arg#*=}"
                ;;
            --print)
                PRINT=linux
                ;;
            --print=*)
                PRINT="${arg#*=}"
                ;;
            --strategies)
                STRATEGIES=linux
                ;;
            --strategies=*)
                STRATEGIES="${arg#*=}"
                ;;
            --default)
                COMPLETE="rust linux llvm chromium"
                EARLY_QUIT=chromium
                PRINT=linux
                STRATEGIES=linux
                ;;
            -*)
                printf 'Unknown option %q\n' "$arg" >&2
                exit $EX_USAGE
                ;;
            # bfs commits/tags to benchmark
            *)
                commits+=("$arg")
                ;;
        esac
    done

    if ((UID == 0)); then
        max-freq
    fi

    echo "Building bfs..."
    as-user make -s -j"$nproc" all

    as-user mkdir -p bench/corpus

    read -a corpuses <<<"$COMPLETE $EARLY_QUIT $PRINT $STRATEGIES"
    corpuses=($(printf '%s\n' "${corpuses[@]}" | sort -u))
    for corpus in "${corpuses[@]}"; do
        as-user ./bench/clone-tree.sh "$(corpus-url $corpus)" "$(corpus-tag $corpus)" "$(corpus-dir $corpus)"
    done

    if ((${#commits[@]} > 0)); then
        echo "Creating bfs worktree..."

        worktree="bench/worktree"
        as-user git worktree add -d "$worktree"
        at-exit as-user git worktree remove "$worktree"

        bin="$(realpath -- "$SETUP_DIR")/bin"
        as-user mkdir "$bin"

        for commit in "${commits[@]}"; do
            (
                echo "Building bfs $commit..."
                cd "$worktree"
                as-user git checkout -d "$commit" --
                as-user make -s -j"$nproc" release
                as-user cp ./bin/bfs "$bin/bfs-$commit"
                as-user make -s clean
            )
        done

        # $SETUP_DIR contains `:` so it won't work in $PATH
        # Work around this with a symlink
        tmp=$(as-user mktemp)
        as-user ln -sf "$bin" "$tmp"
        at-exit rm "$tmp"
        export PATH="$tmp:$PATH"
    fi

    if ((UID == 0)); then
        turbo-off
    fi
}

# Runs hyperfine and saves the output
do-hyperfine() {
    local tmp_md="$BENCH_DIR/.bench.md"
    local md="$BENCH_DIR/bench.md"
    local tmp_json="$BENCH_DIR/.bench.json"
    local json="$BENCH_DIR/bench.json"

    printf '\n' | tee -a "$md"
    hyperfine -w2 -M20 --export-markdown="$tmp_md" --export-json="$tmp_json" "$@" &>/dev/tty
    cat "$tmp_md" >>"$md"
    cat "$tmp_json" >>"$json"
    rm "$tmp_md" "$tmp_json"
}

# Print the header for a benchmark group
group() {
    printf '\n\n## %s\n' "$1" | tee -a "$BENCH_DIR/bench.md"
}

# Print the header for a benchmark subgroup
subgroup() {
    printf '\n### %s\n' "$1" | tee -a "$BENCH_DIR/bench.md"
}

# Print the header for a benchmark sub-subgroup
subsubgroup() {
    printf '\n#### %s\n' "$1" | tee -a "$BENCH_DIR/bench.md"
}

# Benchmark the complete traversal of a directory tree
# (without printing anything)
bench-complete-corpus() {
    total=$(./bin/bfs "$2" -printf '.' | wc -c)

    subgroup "$1 ($total files)"

    cmds=()
    for exe in "${exes[@]}"; do
        cmds+=("$exe $2 -false")
    done

    if ((FIND)); then
        cmds+=("find $2 -false")
    fi

    if ((FD)); then
        cmds+=("fd -u '^$' $2")
    fi

    do-hyperfine "${cmds[@]}"
}

# All complete traversal benchmarks
bench-complete() {
    group "Complete traversal"

    for corpus; do
        bench-complete-corpus "$corpus $(corpus-tag $corpus)" "$(corpus-dir $corpus)"
    done
}

# Benchmark quiting as soon as a file is seen
bench-early-quit-corpus() {
    dir="$2"
    max_depth=$(./bin/bfs -S ids -j1 "$dir" -depth -type f -printf '%d\n' -quit)

    subgroup "$1 (depth $max_depth)"

    for ((i = 5; i <= max_depth; i += 5)); do
        subsubgroup "Depth $i"

        # Sample random files at depth $i with unique names in the whole tree
        export FILES="$BENCH_DIR/files"
        ./bin/bfs "$dir" -mindepth $i -maxdepth $i -type f \
            | shuf \
            | xargs bash -c 'for arg; do ./bin/bfs "$1" -name "${arg##*/}" -not -path "$arg" -exit 1 && printf "%s\n" "${arg##*/}"; done' bash "$dir" 2>/dev/null \
            | head -n20 >"$FILES"

        cmds=()
        for exe in "${exes[@]}"; do
            cmds+=("$exe $dir -name \$(shuf -n1 \$FILES) -print -quit")
        done

        if ((FIND)); then
            cmds+=("find $dir -name \$(shuf -n1 \$FILES) -print -quit")
        fi

        if ((FD)); then
            cmds+=("fd -usg1 \$(shuf -n1 \$FILES) $dir")
        fi

        do-hyperfine "${cmds[@]}"
    done
}

# All early-quitting benchmarks
bench-early-quit() {
    group "Early termination"

    for corpus; do
        bench-early-quit-corpus "$corpus $(corpus-tag $corpus)" "$(corpus-dir $corpus)"
    done
}

# Benchmark printing paths without colors
bench-print-nocolor() {
    subsubgroup "$1"

    cmds=()
    for exe in "${exes[@]}"; do
        cmds+=("$exe $2")
    done

    if ((FIND)); then
        cmds+=("find $2")
    fi

    if ((FD)); then
        cmds+=("fd -u --search-path $2")
    fi

    do-hyperfine "${cmds[@]}"
}

# Benchmark printing paths with colors
bench-print-color() {
    subsubgroup "$1"

    cmds=()
    for exe in "${exes[@]}"; do
        cmds+=("$exe $2 -color")
    done

    if ((FD)); then
        cmds+=("fd -u --search-path $2 --color=always")
    fi

    do-hyperfine "${cmds[@]}"
}

# All printing benchmarks
bench-print() {
    group "Printing paths"

    subgroup "Without colors"
    for corpus; do
        bench-print-nocolor "$corpus $(corpus-tag $corpus)" "$(corpus-dir $corpus)"
    done

    subgroup "With colors"
    for corpus; do
        bench-print-color "$corpus $(corpus-tag $corpus)" "$(corpus-dir $corpus)"
    done
}

# Benchmark a search strategy
bench-strategy() {
    subsubgroup "$1"

    cmds=()
    for exe in "${exes[@]}"; do
        cmds+=("$exe -S $3 $2")
    done

    do-hyperfine "${cmds[@]}"
}

# All search strategy benchmarks
bench-strategies() {
    group "Search strategies"

    for strat in dfs ids eds; do
        subgroup "$strat"
        for corpus; do
            bench-strategy "$corpus $(corpus-tag $corpus)" "$(corpus-dir $corpus)" "$strat"
        done
    done
}

# Run all the benchmarks
bench() {
    exes=()
    for exe in "$SETUP_DIR"/bin/bfs-*; do
        if [ -e "$exe" ]; then
            exes+=("${exe##*/}")
        fi
    done

    if [[ $COMPLETE ]]; then
        bench-complete $COMPLETE
    fi
    if [[ $EARLY_QUIT ]]; then
        bench-early-quit $EARLY_QUIT
    fi
    if [[ $PRINT ]]; then
        bench-print $PRINT
    fi
    if [[ $STRATEGIES ]]; then
        bench-strategies $STRATEGIES
    fi
}
