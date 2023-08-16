#!/hint/bash

LINUX_TAG=v6.4

# Clone the Linux source tree
clone-linux() {
    if ! [ -e bench/corpus/linux.git ]; then
        echo "Cloning Linux..."
        as-user git clone --bare --progress "https://github.com/torvalds/linux.git" bench/corpus/linux.git
    fi

    (
        echo "Fetching Linux $LINUX_TAG..."
        cd bench/corpus/linux.git
        as-user git fetch origin tag "$LINUX_TAG" --no-tags
    )

    if [ -e bench/corpus/linux ]; then
        (
            echo "Checking out Linux $LINUX_TAG.."
            cd bench/corpus/linux
            as-user git checkout v6.4
        )
    else
        (
            echo "Creating Linux worktree..."
            cd bench/corpus/linux.git
            as-user git worktree add -d ../linux v6.4
        )
    fi
}

# Set up the benchmarks
setup() {
    ROOT=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
    if ! [ "$PWD" -ef "$ROOT" ]; then
        printf 'Please run this script from %s\n' "$ROOT" >&2
        exit $EX_USAGE
    fi

    export LINUX=0

    export FD=0
    export FIND=0

    nproc=$(nproc)
    commits=()

    for arg; do
        case "$arg" in
            --fd)
                FD=1
                ;;
            --find)
                FIND=1
                ;;
            --linux)
                LINUX=1
                ;;
            -*)
                printf 'Unknown option %q\n' "$arg" >&2
                exit $EX_USAGE
                ;;
            *)
                commits+=("$arg")
                ;;
        esac
    done

    if ((UID == 0)); then
        max-freq
    fi

    as-user mkdir -p bench/corpus

    if ((LINUX)); then
        clone-linux
    fi

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

    echo "Building bfs..."
    as-user make -s -j"$nproc"

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
bench-complete() {
    subgroup "$1"

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
bench-complete-group() {
    group "Complete traversal"

    if ((LINUX)); then
        bench-complete "Linux $LINUX_TAG source tree" bench/corpus/linux
    fi
}

# Benchmark quiting as soon as a file is seen
bench-early-quit() {
    subgroup "$1"

    dir="$2"
    max_depth=$(./bin/bfs -S ids -j1 "$dir" -depth -type f -printf '%d\n' -quit)

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
bench-early-quit-group() {
    group "Early termination"

    if ((LINUX)); then
        bench-early-quit "Linux $LINUX_TAG source tree" bench/corpus/linux
    fi
}

# Run all the benchmarks
bench() {
    exes=()
    for exe in "$SETUP_DIR"/bin/bfs-*; do
        if [ -e "$exe" ]; then
            exes+=("${exe##*/}")
        fi
    done

    bench-complete-group
    bench-early-quit-group
}
