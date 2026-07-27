#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Scripts/verification/m2-evidence-common.sh"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m3-ui-disabled/$RUN_ID}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rascal-m3-ui.XXXXXX")"
PROBE_ROOT="$TEMP_ROOT/source"
SCRATCH="$TEMP_ROOT/build"
mkdir -p "$OUT" "$PROBE_ROOT" "$SCRATCH"

cleanup() {
    local status=$?
    trap - EXIT
    rm -rf "$TEMP_ROOT"
    git -C "$ROOT" rev-parse HEAD > "$OUT/head-end.txt"
    git -C "$ROOT" status --porcelain=v2 --untracked-files=all > "$OUT/git-status-v2-end.txt"
    printf '%s\n' "$status" > "$OUT/lane.exit"
    find "$OUT" -type f -not -name evidence.sha256 -print0 \
        | sort -z | xargs -0 shasum -a 256 > "$OUT/evidence.sha256"
    exit "$status"
}
trap cleanup EXIT

git -C "$ROOT" rev-parse HEAD > "$OUT/head.txt"
git -C "$ROOT" status --porcelain=v2 --untracked-files=all > "$OUT/git-status-v2.txt"
git -C "$ROOT" diff --binary > "$OUT/unstaged.diff"
git -C "$ROOT" diff --cached --binary > "$OUT/staged.diff"
git -C "$ROOT" diff --name-only "$HEAD_OID" > "$OUT/changed-paths.txt"

if grep -E '^Sources/FinderTwo/' "$OUT/changed-paths.txt" >/dev/null; then
    echo "M3 modified FinderTwo UI sources" >&2
    exit 1
fi
if grep -E 'submitMove|submitReplace|OperationKind\\.move|OperationKind\\.replace' \
    "$ROOT/Sources/FinderTwo/Integration/FileOperationBridge.swift" >/dev/null; then
    echo "formal UI bridge exposes M3 move/replace submission" >&2
    exit 1
fi

cat > "$OUT/positive-bindings.tsv" <<EOF
ENTRY-PASTE	$(grep -c 'func pasteMoveHere' "$ROOT/Sources/FinderTwo/UI/PaneController.swift")
ENTRY-LIST-DRAG	$(grep -c 'route: \.listDrag' "$ROOT/Sources/FinderTwo/UI/FileListController.swift")
ENTRY-ICON-DRAG	$(grep -c 'route: \.iconDrag' "$ROOT/Sources/FinderTwo/UI/PaneController.swift")
ENTRY-PANE-MOVE	$(grep -c 'route: \.paneToPane' "$ROOT/Sources/FinderTwo/Window/PanesContainerController.swift")
ENTRY-DROP-STACK	$(grep -c '@objc private func moveAllHere' "$ROOT/Sources/FinderTwo/UI/DropStackController.swift")
ENTRY-REPLACE-CONFLICT	$(grep -c 'case \.replace:' "$ROOT/Sources/FinderTwo/FS/FileOps.swift")
EOF
awk -F'\t' '$2 != 1 { bad=1 } END { exit bad }' "$OUT/positive-bindings.tsv"

cp "$ROOT/Package.swift" "$PROBE_ROOT/Package.swift"
cp -R "$ROOT/Sources" "$PROBE_ROOT/Sources"
cp -R "$ROOT/Tests" "$PROBE_ROOT/Tests"
cp "$ROOT/Scripts/verification/m3-ui-disabled-probe.swift" \
    "$PROBE_ROOT/Sources/FinderTwo/Tests/M3UIDisabledProbe.swift"

/usr/bin/python3 "$ROOT/Scripts/verification/m3-ui-disabled-install-seams.py" \
    "$PROBE_ROOT"

run_probe() {
    local configuration="$1" build_label="$2" home="$3"
    shift 3
    local build_log="$OUT/$configuration-build.stdout"
    local build_error="$OUT/$configuration-build.stderr"
    local probe_log="$OUT/$configuration-probe.stdout"
    local probe_error="$OUT/$configuration-probe.stderr"
    mkdir -p "$home"
    (
        cd "$PROBE_ROOT"
        CFFIXED_USER_HOME="$home" \
        CLANG_MODULE_CACHE_PATH="$SCRATCH/$configuration-clang" \
        SWIFT_MODULECACHE_PATH="$SCRATCH/$configuration-swift" \
        swift build --disable-sandbox -c "$configuration" \
            --product FinderTwo \
            --scratch-path "$SCRATCH/$configuration"
    ) > "$build_log" 2> "$build_error"
    local binary
    binary="$(
        cd "$PROBE_ROOT"
        swift build --disable-sandbox -c "$configuration" \
            --product FinderTwo \
            --scratch-path "$SCRATCH/$configuration" \
            --show-bin-path
    )/FinderTwo"
    m2_run_timed "$OUT" "$configuration-probe" 180 \
        /usr/bin/env \
        "CFFIXED_USER_HOME=$home" \
        FT_HEADLESS_TESTING=1 \
        FT_M3_UI_DISABLED_PROBE=1 \
        "$@" \
        "$binary"
    grep -Fxq \
        "M3_UI_DISABLED_PROBE PASS entries=6 native=0 legacy=0 journal_rows=0 fixture=unchanged denials=6" \
        "$probe_log"
    if grep -Eiq '(^|[^[:alpha:]])skip(ped)?([^[:alpha:]]|$)' \
        "$probe_log" "$probe_error"; then
        echo "M3 UI-disabled $configuration probe reported a skip" >&2
        exit 1
    fi
    /usr/bin/python3 - "$probe_error" "$OUT/dynamic-matrix.tsv" \
        "$build_label" <<'PY'
import pathlib
import sys

log_path, output_path, build = sys.argv[1:]
prefix = "M3_UI_DISABLED_PROBE progress "
observed = [
    line.removeprefix(prefix)
    for line in pathlib.Path(log_path).read_text().splitlines()
    if line.startswith(prefix)
]
mapping = {
    "paste": "ENTRY-PASTE",
    "list-drag": "ENTRY-LIST-DRAG",
    "icon-drag": "ENTRY-ICON-DRAG",
    "pane-move": "ENTRY-PANE-MOVE",
    "drop-stack": "ENTRY-DROP-STACK",
    "replace-conflict": "ENTRY-REPLACE-CONFLICT",
}
entries = [mapping[value] for value in observed if value in mapping]
if len(entries) != len(mapping) or set(entries) != set(mapping.values()):
    raise SystemExit(f"{build} entry progress mismatch: {observed}")
with pathlib.Path(output_path).open("a") as handle:
    for entry in entries:
        handle.write(
            f"{build}\t{entry}\tnative=0\tlegacy=0\t"
            "journal_rows=0\tfixture=unchanged\n"
        )
PY
}

: > "$OUT/dynamic-matrix.tsv"
run_probe debug debug-default "$TEMP_ROOT/debug-home"
run_probe release release-env1 "$TEMP_ROOT/release-home" \
    RASCAL_ENABLE_M2_NATIVE_COPY=1 \
    RASCAL_ENABLE_LEGACY_WRITES=1 \
    FT_M1_LEGACY_COPY_COMPATIBILITY=1 \
    FT_RUN_TESTS=1

/usr/bin/python3 - \
    "$OUT/positive-bindings.tsv" \
    "$OUT/dynamic-matrix.tsv" \
    "$OUT/bindings.tsv" <<'PY'
import pathlib
import sys

positive = [
    line.split("\t")
    for line in pathlib.Path(sys.argv[1]).read_text().splitlines()
    if line
]
expected_entries = {
    "ENTRY-PASTE",
    "ENTRY-LIST-DRAG",
    "ENTRY-ICON-DRAG",
    "ENTRY-PANE-MOVE",
    "ENTRY-DROP-STACK",
    "ENTRY-REPLACE-CONFLICT",
}
if (
    {row[0] for row in positive} != expected_entries
    or len(positive) != 6
    or any(row[1] != "1" for row in positive)
):
    raise SystemExit(f"positive UI inventory mismatch: {positive}")
dynamic = [
    line.split("\t")
    for line in pathlib.Path(sys.argv[2]).read_text().splitlines()
    if line
]
expected_builds = {"debug-default", "release-env1"}
expected_pairs = {
    (build, entry)
    for build in expected_builds
    for entry in expected_entries
}
observed_pairs = {(row[0], row[1]) for row in dynamic}
if len(dynamic) != 12 or observed_pairs != expected_pairs or any(
    row[2:] != [
        "native=0",
        "legacy=0",
        "journal_rows=0",
        "fixture=unchanged",
    ]
    for row in dynamic
):
    raise SystemExit(f"dynamic UI matrix mismatch: {dynamic}")
pathlib.Path(sys.argv[3]).write_text(
    "\n".join(
        f"{build}\t{entry}\tPASS"
        for build, entry in sorted(observed_pairs)
    ) + "\n"
)
PY
cmp "$OUT/head.txt" <(git -C "$ROOT" rev-parse HEAD)
echo "M3-UI-DISABLED-001 PASS builds=2 bindings=12 journal_rows=0 skip=0 evidence=$OUT"
