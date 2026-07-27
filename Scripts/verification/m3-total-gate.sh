#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m3-total/$RUN_ID}"
SCRATCH="${TMPDIR:-/tmp}/rascal-m3-total-scratch-$RUN_ID"
LANES="$OUT/lanes"
mkdir -p "$OUT" "$SCRATCH" "$LANES"
FINALIZED=0

capture_source() {
    local suffix="$1"
    git -C "$ROOT" rev-parse HEAD > "$OUT/head${suffix}.txt"
    git -C "$ROOT" status --porcelain=v2 --untracked-files=all \
        > "$OUT/git-status-v2${suffix}.txt"
    git -C "$ROOT" diff --binary > "$OUT/unstaged${suffix}.diff"
    git -C "$ROOT" diff --cached --binary > "$OUT/staged${suffix}.diff"
    : > "$OUT/untracked-content${suffix}.sha256"
    while IFS= read -r -d '' path; do
        shasum -a 256 "$ROOT/$path" >> "$OUT/untracked-content${suffix}.sha256"
    done < <(git -C "$ROOT" ls-files --others --exclude-standard -z | sort -z)
}

finish() {
    local status=$?
    trap - EXIT
    set +e
    capture_source "-end"
    if ! cmp "$OUT/head.txt" "$OUT/head-end.txt" ||
       ! cmp "$OUT/git-status-v2.txt" "$OUT/git-status-v2-end.txt" ||
       ! cmp "$OUT/unstaged.diff" "$OUT/unstaged-end.diff" ||
       ! cmp "$OUT/staged.diff" "$OUT/staged-end.diff" ||
       ! cmp "$OUT/untracked-content.sha256" "$OUT/untracked-content-end.sha256"; then
        echo "M3 source state changed during total gate" >&2
        status=1
    fi
    local manifest_tmp="$OUT/evidence.sha256.tmp"
    find "$OUT" -type f \
        ! -name evidence.sha256 \
        ! -name evidence.sha256.tmp \
        ! -name lane.exit \
        -print0 | sort -z | xargs -0 shasum -a 256 > "$manifest_tmp"
    if ! shasum -a 256 -c "$manifest_tmp" >/dev/null ||
       ! mv "$manifest_tmp" "$OUT/evidence.sha256"; then
        status=1
    fi
    if [[ "$status" == 0 && "$FINALIZED" == 1 ]]; then
        printf '0\n' > "$OUT/lane.exit"
    else
        [[ "$status" != 0 ]] || status=1
        printf '%s\n' "$status" > "$OUT/lane.exit"
    fi
    exit "$status"
}
trap finish EXIT

capture_source ""
sw_vers > "$OUT/os.txt"
xcodebuild -version > "$OUT/xcode.txt"
swift --version > "$OUT/swift.txt"
/usr/bin/sqlite3 --version > "$OUT/sqlite.txt"

git -C "$ROOT" diff --name-only "$HEAD_OID" > "$OUT/changed-paths.txt"
git -C "$ROOT" ls-files --others --exclude-standard >> "$OUT/changed-paths.txt"
sort -u -o "$OUT/changed-paths.txt" "$OUT/changed-paths.txt"
"$PYTHON_BIN" - "$OUT/changed-paths.txt" <<'PY'
import pathlib
import sys

allowed_files = {
    "Package.swift",
    "Sources/RascalFileOperations/Core/FileOperationService.swift",
    "Sources/RascalFileOperations/Core/PublicTypes.swift",
    "Sources/RascalFileOperations/Copy/NativeCopyExecutor.swift",
    "Sources/RascalFileOperations/Interfaces/OperationDependencies.swift",
    "Sources/RascalFileOperations/Interfaces/DurableOperationJournal.swift",
    "Sources/RascalFileOperations/Interfaces/DurableEffectExecution.swift",
    "Sources/RascalFileOperations/Interfaces/UnavailableOperationJournal.swift",
    "Sources/RascalFileOperations/TestSupport/TestSupport.swift",
    "Tests/RascalFileOperationsIntegrationTests/ServiceIntegrationTests.swift",
    "Tests/RascalFileOperationsIntegrationTests/EventStreamIntegrationTests.swift",
    "Tests/RascalFileOperationsTests/RecoverySafetyTests.swift",
}
allowed_prefixes = (
    "Sources/RascalFileOperations/Journal/",
    "Sources/RascalFileOperations/Move/",
    "Sources/RascalFileOperations/Replace/",
    "Sources/RascalFileOperations/Recovery/",
    "Sources/FileOpsCrashProbe/",
    "Tests/RascalFileOperationsTests/Journal/",
    "Tests/RascalFileOperationsTests/Move/",
    "Tests/RascalFileOperationsTests/Replace/",
    "Tests/RascalFileOperationsTests/Recovery/",
    "Tests/RascalFileOperationsIntegrationTests/Crash/",
    "Tests/RascalFileOperationsIntegrationTests/Move/",
    "Tests/RascalFileOperationsIntegrationTests/Replace/",
    "Scripts/verification/m3-",
    "openspec/changes/add-transactional-file-operation-core/",
)
paths = [line for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line]
unexpected = [
    path for path in paths
    if path not in allowed_files and not path.startswith(allowed_prefixes)
]
if unexpected:
    raise SystemExit(f"M3 changed paths outside allowlist: {unexpected}")
PY
printf 'M3-STATIC-ALLOWLIST-001\tPASS\n' > "$OUT/scenario-manifest.tsv"

cd "$ROOT"
openspec validate add-transactional-file-operation-core --strict \
    > "$OUT/openspec.stdout" 2> "$OUT/openspec.stderr"
printf 'M3-OPENSPEC-001\tPASS\n' >> "$OUT/scenario-manifest.tsv"

CFFIXED_USER_HOME="${TMPDIR:-/tmp}/rascal-m3-total-home-$RUN_ID" \
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-total-clang-$RUN_ID" \
SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-total-swift-$RUN_ID" \
swift test --disable-sandbox --scratch-path "$SCRATCH/full" \
    > "$OUT/swift-test.stdout" 2> "$OUT/swift-test.stderr"
grep -F "with 0 failures" "$OUT/swift-test.stdout" >/dev/null
printf 'M3-UNIT-FAULT-001\tPASS\n' >> "$OUT/scenario-manifest.tsv"

CFFIXED_USER_HOME="${TMPDIR:-/tmp}/rascal-m3-release-home-$RUN_ID" \
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-release-clang-$RUN_ID" \
SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-release-swift-$RUN_ID" \
swift build --disable-sandbox -c release --scratch-path "$SCRATCH/release" \
    > "$OUT/release-build.stdout" 2> "$OUT/release-build.stderr"
printf 'M3-BUILD-COMPAT-001\tPASS\n' >> "$OUT/scenario-manifest.tsv"

run_child() {
    local lane="$1" script="$2"
    local child="$LANES/$lane"
    mkdir -p "$child"
    bash "$ROOT/Scripts/verification/$script" "$child" \
        > "$OUT/$lane.stdout" 2> "$OUT/$lane.stderr"
    [[ "$(tr -d '[:space:]' < "$child/lane.exit")" == 0 ]]
    shasum -a 256 -c "$child/evidence.sha256" >/dev/null
    shasum -a 256 "$child/evidence.sha256" >> "$OUT/child-evidence.sha256"
}

: > "$OUT/child-evidence.sha256"
run_child journal-corruption m3-corrupt-journal.sh
run_child move-clean-replace m3-apfs-cross-volume-move.sh
run_child crash-matrix m3-crash-matrix.sh
run_child ui-disabled m3-ui-disabled.sh

"$PYTHON_BIN" - \
    "$OUT/scenario-manifest.tsv" \
    "$LANES/journal-corruption/bindings.tsv" \
    "$LANES/move-clean-replace/bindings.tsv" \
    "$LANES/crash-matrix/scenario-manifest.tsv" \
    "$LANES/ui-disabled/bindings.tsv" \
    "$OUT/summary.txt" \
    "$OUT/swift-test.stdout" \
    "$LANES/move-clean-replace/move-tests.stdout" \
    "$LANES/move-clean-replace/replace-tests.stdout" <<'PY'
import re
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
rows = [line.split("\t") for line in manifest.read_text().splitlines() if line]
base_expected = {
    "M3-STATIC-ALLOWLIST-001",
    "M3-OPENSPEC-001",
    "M3-UNIT-FAULT-001",
    "M3-BUILD-COMPAT-001",
}
if {row[0] for row in rows} != base_expected:
    raise SystemExit(f"M3 base binding mismatch: {rows}")

journal_expected = {
    "M3-JRN-PRAGMA-001",
    "M3-JRN-SCHEMA-001",
    "M3-JRN-LOCK-001",
    "M3-JRN-TAKEOVER-001",
    "M3-JRN-RETENTION-001",
    "M3-JRN-EVENT-001",
    "M3-CORRUPT-MAIN-001",
    "M3-CORRUPT-WAL-001",
    "M3-CORRUPT-SHM-001",
}
journal_rows = [
    line.split("\t")
    for line in pathlib.Path(sys.argv[2]).read_text().splitlines()
    if line
]
if (
    {row[0] for row in journal_rows} != journal_expected
    or len(journal_rows) != len(journal_expected)
    or any(len(row) != 3 or row[1] != "PASS" for row in journal_rows)
):
    raise SystemExit(f"M3 journal child binding mismatch: {journal_rows}")
rows.extend([[row[0], "PASS"] for row in journal_rows])

move_expected = {
    "M3-MOVE-POLICY-001",
    "M3-MOVE-ORDER-001",
    "M3-MOVE-BARRIER-001",
    "M3-CLEAN-IDENTITY-001",
    "M3-REPLACE-BACKUP-001",
    "M3-RECOVERY-ACTION-001",
}
move_rows = [
    line.split("\t")
    for line in pathlib.Path(sys.argv[3]).read_text().splitlines()
    if line
]
if (
    {row[0] for row in move_rows} != move_expected
    or len(move_rows) != len(move_expected)
    or any(len(row) != 3 or row[1] != "PASS" for row in move_rows)
):
    raise SystemExit(f"M3 move child binding mismatch: {move_rows}")
rows.extend([[row[0], "PASS"] for row in move_rows])

codes = {
    "COMMIT",
    "BACKUP",
    "REPLCOMMIT",
    "QUAR",
    "QPURGENODE",
    "QPURGEROOT",
    "ROLLBACK",
    "RESTORE",
    "BACKUPPURGE",
    "STAGEDISCARD",
}
windows = {"W1", "W2", "W3"}
crash_expected = {
    f"M3-CRASH-{code}-{window}-001"
    for code in codes
    for window in windows
}
crash_rows = [
    line.split("\t")
    for line in pathlib.Path(sys.argv[4]).read_text().splitlines()
    if line
]
if (
    {row[0] for row in crash_rows} != crash_expected
    or len(crash_rows) != 30
    or any(len(row) != 5 or row[4] != "PASS" for row in crash_rows)
):
    raise SystemExit(f"M3 crash child binding mismatch: {crash_rows}")
rows.extend([[row[0], "PASS"] for row in crash_rows])
rows.append(["M3-CRASH-001", "PASS"])

builds = {"debug-default", "release-env1"}
entries = {
    "ENTRY-PASTE",
    "ENTRY-LIST-DRAG",
    "ENTRY-ICON-DRAG",
    "ENTRY-PANE-MOVE",
    "ENTRY-DROP-STACK",
    "ENTRY-REPLACE-CONFLICT",
}
ui_rows = [
    line.split("\t")
    for line in pathlib.Path(sys.argv[5]).read_text().splitlines()
    if line
]
ui_expected = {(build, entry, "PASS") for build in builds for entry in entries}
if {tuple(row) for row in ui_rows} != ui_expected or len(ui_rows) != 12:
    raise SystemExit(f"M3 UI child binding mismatch: {ui_rows}")
rows.append(["M3-UI-DISABLED-001", "PASS"])

expected = (
    base_expected
    | journal_expected
    | move_expected
    | crash_expected
    | {"M3-CRASH-001", "M3-UI-DISABLED-001"}
)
ids = [row[0] for row in rows]
if set(ids) != expected or len(ids) != len(expected):
    raise SystemExit(f"M3 total binding mismatch: {ids}")
if any(len(row) != 2 or row[1] != "PASS" for row in rows):
    raise SystemExit(f"M3 non-PASS binding: {rows}")

full_text = pathlib.Path(sys.argv[7]).read_text()
full_summaries = [
    (int(total), int(skipped or 0))
    for total, skipped in re.findall(
        r"Executed (\d+) tests, with (?:(\d+) tests skipped and )?0 failures",
        full_text,
    )
]
if not full_summaries:
    raise SystemExit("full Swift test summary is missing")
full_tests, full_skips = max(full_summaries)
skipped_names = set(re.findall(
    r"(test[A-Za-z0-9_]+)\]' skipped",
    full_text,
))
expected_skips = {
    "testCrossVolumeMovePersistsCommitQuarantineAndLeafToRootPurge",
    "testCrossVolumeBarrierCancelRetainsSourceWithoutQuarantineIntent",
    "testCrossVolumeRetainFailsClosedWhenSourceParentWasReplaced",
    "testExternalMoveToQuarantineBeforeFirstIntentIsNeverAdopted",
    "testCrossVolumeCleanupIdentityRacesStopConservatively",
    "testCrossVolumeMoveReplaceFinalizesOnlyAfterSourceCleanup",
}
if skipped_names != expected_skips or full_skips != len(expected_skips):
    raise SystemExit(
        f"unexpected full-suite skips: summary={full_skips} names={skipped_names}"
    )
apfs_passed = set()
for path in sys.argv[8:10]:
    apfs_passed.update(re.findall(
        r"(test[A-Za-z0-9_]+)\]' passed",
        pathlib.Path(path).read_text(),
    ))
if not expected_skips.issubset(apfs_passed):
    raise SystemExit(
        f"full-suite skips lack exact mandatory APFS passes: "
        f"{expected_skips - apfs_passed}"
    )
manifest.write_text("\n".join("\t".join(row) for row in rows) + "\n")
pathlib.Path(sys.argv[6]).write_text(
    f"mandatory_scenarios={len(expected)}\n"
    f"mandatory_pass={len(expected)}\n"
    "mandatory_skip_count=0\n"
    f"full_suite_tests={full_tests}\n"
    f"full_suite_skip_count={full_skips}\n"
    "full_suite_skips_replayed_in_apfs=6\n"
    "crash_subscenarios=30\n"
    "ui_dynamic_bindings=12\n"
)
PY

FINALIZED=1
echo "M3-TOTAL-001 PASS mandatory=51 crash=30 ui_bindings=12 skip=0 evidence=$OUT"
