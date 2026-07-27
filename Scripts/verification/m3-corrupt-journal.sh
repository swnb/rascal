#!/usr/bin/env bash
set -euo pipefail

readonly SQLITE_BIN=/usr/bin/sqlite3
readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m3-corrupt/$RUN_ID}"
SCRATCH="${TMPDIR:-/tmp}/rascal-m3-corrupt-scratch-$RUN_ID"
mkdir -p "$OUT" "$SCRATCH" "$OUT/cases"

cleanup() {
    local status=$?
    trap - EXIT
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
sw_vers > "$OUT/os.txt"
swift --version > "$OUT/swift.txt"
"$SQLITE_BIN" --version > "$OUT/sqlite-cli-version.txt"

cd "$ROOT"
CFFIXED_USER_HOME="${TMPDIR:-/tmp}/rascal-m3-corrupt-home-$RUN_ID" \
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-corrupt-clang-$RUN_ID" \
SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-corrupt-swift-$RUN_ID" \
swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter SQLiteOperationJournalTests \
    > "$OUT/swift-test.stdout" 2> "$OUT/swift-test.stderr"
grep -F "with 0 failures" "$OUT/swift-test.stdout" >/dev/null
if grep -Fi "skipped" "$OUT/swift-test.stdout" >/dev/null; then
    echo "M3 journal mandatory tests reported a skip" >&2
    exit 1
fi

PROBE="$SCRATCH/arm64-apple-macosx/debug/FileOpsCrashProbe"
[[ -x "$PROBE" ]] || {
    echo "FileOpsCrashProbe is missing from test scratch" >&2
    exit 1
}

fresh_journal() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    "$PROBE" --try-open-journal "$path" >/dev/null
}

expect_rejected_without_main_mutation() {
    local label="$1" path="$2" fixture="${3:-}"
    local protected=("$path")
    [[ -z "$fixture" ]] || protected+=("$fixture")
    shasum -a 256 "${protected[@]}" > "$OUT/cases/$label.before.sha256"
    set +e
    "$PROBE" --try-open-journal "$path" \
        > "$OUT/cases/$label.stdout" 2> "$OUT/cases/$label.stderr"
    local status=$?
    set -e
    [[ "$status" != 0 ]] || {
        echo "$label corrupt journal unexpectedly opened" >&2
        exit 1
    }
    [[ -f "$path" ]] || {
        echo "$label corrupt journal was deleted" >&2
        exit 1
    }
    if [[ -n "$fixture" && ! -f "$fixture" ]]; then
        echo "$label user fixture was deleted" >&2
        exit 1
    fi
    "$PROBE" --try-service-safe-mode "$path" \
        > "$OUT/cases/$label.service.stdout" \
        2> "$OUT/cases/$label.service.stderr"
    grep -F "service-safe-mode PASS" \
        "$OUT/cases/$label.service.stdout" >/dev/null
    shasum -a 256 "${protected[@]}" > "$OUT/cases/$label.after.sha256"
    cmp "$OUT/cases/$label.before.sha256" "$OUT/cases/$label.after.sha256"
    printf '%s\tPASS\texit=%s\n' "$label" "$status" >> "$OUT/scenario-manifest.tsv"
}

seed_recovery_set() {
    local path="$1" label="$2"
    mkdir -p "$(dirname "$path")"
    "$PROBE" --journal-wal-worker "$path" \
        > "$OUT/cases/$label.seed.stdout" \
        2> "$OUT/cases/$label.seed.stderr" &
    local worker_pid=$!
    printf '%s\n' "$worker_pid" > "$OUT/cases/$label.seed.pid"
    local ready=0
    for _ in $(seq 1 400); do
        if grep -F "journal-wal-ready" \
            "$OUT/cases/$label.seed.stdout" >/dev/null 2>&1; then
            ready=1
            break
        fi
        kill -0 "$worker_pid" 2>/dev/null || break
        sleep 0.05
    done
    [[ "$ready" == 1 ]] || {
        kill -9 "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
        echo "$label WAL worker did not become ready" >&2
        exit 1
    }
    kill -9 "$worker_pid"
    set +e
    wait "$worker_pid"
    local status=$?
    set -e
    printf '%s\n' "$status" > "$OUT/cases/$label.seed.exit"
    [[ "$status" == 137 ]]
    [[ -s "$path" && -s "$path-wal" && -s "$path-shm" ]]
}

expect_rejected_without_set_mutation() {
    local label="$1" path="$2" fixture="$3"
    shasum -a 256 "$path" "$path-wal" "$path-shm" "$fixture" \
        > "$OUT/cases/$label.before.sha256"
    set +e
    "$PROBE" --try-open-journal "$path" \
        > "$OUT/cases/$label.stdout" 2> "$OUT/cases/$label.stderr"
    local status=$?
    set -e
    [[ "$status" != 0 ]] || {
        echo "$label corrupt recovery set unexpectedly opened" >&2
        exit 1
    }
    [[ -f "$path" && -f "$path-wal" && -f "$path-shm" && -f "$fixture" ]] || {
        echo "$label corrupt recovery set or user fixture was deleted" >&2
        exit 1
    }
    "$PROBE" --try-service-safe-mode "$path" \
        > "$OUT/cases/$label.service.stdout" \
        2> "$OUT/cases/$label.service.stderr"
    grep -F "service-safe-mode PASS" \
        "$OUT/cases/$label.service.stdout" >/dev/null
    shasum -a 256 "$path" "$path-wal" "$path-shm" "$fixture" \
        > "$OUT/cases/$label.after.sha256"
    cmp "$OUT/cases/$label.before.sha256" "$OUT/cases/$label.after.sha256"
    printf '%s\tPASS\texit=%s\n' "$label" "$status" \
        >> "$OUT/scenario-manifest.tsv"
}

: > "$OUT/scenario-manifest.tsv"

future="$OUT/cases/future/operations.sqlite"
fresh_journal "$future"
"$SQLITE_BIN" "$future" "PRAGMA user_version=2"
expect_rejected_without_main_mutation "M3-CORRUPT-FUTURE-001" "$future"

index="$OUT/cases/missing-index/operations.sqlite"
fresh_journal "$index"
"$SQLITE_BIN" "$index" "DROP INDEX operation_effects_order"
expect_rejected_without_main_mutation "M3-CORRUPT-DDL-001" "$index"

unknown="$OUT/cases/unknown-v0/operations.sqlite"
mkdir -p "$(dirname "$unknown")"
"$SQLITE_BIN" "$unknown" "CREATE TABLE alien(value TEXT)"
expect_rejected_without_main_mutation "M3-CORRUPT-V0-001" "$unknown"

damaged="$OUT/cases/main-bit/operations.sqlite"
damaged_fixture="$OUT/cases/main-bit/user-object.bin"
fresh_journal "$damaged"
mkfile 4k "$damaged_fixture"
dd if=/dev/zero of="$damaged" bs=1 count=64 conv=notrunc \
    > "$OUT/cases/main-bit.dd.stdout" 2> "$OUT/cases/main-bit.dd.stderr"
expect_rejected_without_main_mutation \
    "M3-CORRUPT-MAIN-BIT-001" "$damaged" "$damaged_fixture"

main_truncate="$OUT/cases/main-truncate/operations.sqlite"
main_truncate_fixture="$OUT/cases/main-truncate/user-object.bin"
fresh_journal "$main_truncate"
mkfile 4k "$main_truncate_fixture"
dd if=/dev/zero of="$main_truncate" bs=64 count=1 \
    > "$OUT/cases/main-truncate.dd.stdout" \
    2> "$OUT/cases/main-truncate.dd.stderr"
expect_rejected_without_main_mutation \
    "M3-CORRUPT-MAIN-TRUNCATE-001" \
    "$main_truncate" "$main_truncate_fixture"

wal="$OUT/cases/wal-bit/operations.sqlite"
wal_fixture="$OUT/cases/wal-bit/user-object.bin"
mkdir -p "$(dirname "$wal")"
mkfile 4k "$wal_fixture"
seed_recovery_set "$wal" "M3-CORRUPT-WAL-BIT-001"
dd if=/dev/zero of="$wal-wal" bs=1 count=64 conv=notrunc \
    > "$OUT/cases/wal-bit.dd.stdout" 2> "$OUT/cases/wal-bit.dd.stderr"
expect_rejected_without_set_mutation \
    "M3-CORRUPT-WAL-BIT-001" "$wal" "$wal_fixture"

wal_truncate="$OUT/cases/wal-truncate/operations.sqlite"
wal_truncate_fixture="$OUT/cases/wal-truncate/user-object.bin"
mkdir -p "$(dirname "$wal_truncate")"
mkfile 4k "$wal_truncate_fixture"
seed_recovery_set "$wal_truncate" "M3-CORRUPT-WAL-TRUNCATE-001"
dd if=/dev/zero of="$wal_truncate-wal" bs=64 count=1 \
    > "$OUT/cases/wal-truncate.dd.stdout" \
    2> "$OUT/cases/wal-truncate.dd.stderr"
expect_rejected_without_set_mutation \
    "M3-CORRUPT-WAL-TRUNCATE-001" \
    "$wal_truncate" "$wal_truncate_fixture"

shm="$OUT/cases/shm/operations.sqlite"
shm_fixture="$OUT/cases/shm/user-object.bin"
mkdir -p "$(dirname "$shm")"
mkfile 4k "$shm_fixture"
seed_recovery_set "$shm" "M3-CORRUPT-SHM-001"
dd if=/dev/zero of="$shm-shm" bs=1 count=64 conv=notrunc \
    > "$OUT/cases/shm.dd.stdout" 2> "$OUT/cases/shm.dd.stderr"
expect_rejected_without_set_mutation \
    "M3-CORRUPT-SHM-ANOMALY-001" "$shm" "$shm_fixture"

process_journal="$OUT/cases/process/operations.sqlite"
mkdir -p "$(dirname "$process_journal")"
"$PROBE" --journal-process-self-check "$process_journal" \
    > "$OUT/cases/process.stdout" 2> "$OUT/cases/process.stderr"
grep -F "journal-process-self-check PASS" "$OUT/cases/process.stdout" >/dev/null
printf 'M3-JRN-LOCK-TAKEOVER-FD-001\tPASS\texit=0\n' >> "$OUT/scenario-manifest.tsv"

takeover_root="$OUT/cases/takeover"
takeover_journal="$takeover_root/operations.sqlite"
takeover_source="$takeover_root/new.bin"
takeover_destination="$takeover_root/final.bin"
takeover_fixture="$takeover_root/stale-action.json"
takeover_counter="$takeover_root/syscall-attempts.tsv"
mkdir -p "$takeover_root"
mkfile 4k "$takeover_source"
mkfile 8k "$takeover_destination"
: > "$takeover_counter"
export RASCAL_M3_SYSCALL_COUNTER_PATH="$takeover_counter"
"$PROBE" --real-prepare-hold \
    "$takeover_journal" "$takeover_source" "$takeover_destination" \
    > "$takeover_fixture" 2> "$takeover_root/owner.stderr" &
takeover_pid=$!
printf '%s\n' "$takeover_pid" > "$takeover_root/owner.pid"
for _ in $(seq 1 600); do
    [[ -s "$takeover_fixture" ]] && break
    kill -0 "$takeover_pid" 2>/dev/null || break
    sleep 0.05
done
[[ -s "$takeover_fixture" ]]
shasum -a 256 "$takeover_source" "$takeover_destination" \
    > "$takeover_root/user-before.sha256"
takeover_count_before="$(wc -l < "$takeover_counter" | tr -d ' ')"
kill -9 "$takeover_pid"
set +e
wait "$takeover_pid"
takeover_status=$?
set -e
printf '%s\n' "$takeover_status" > "$takeover_root/owner.exit"
[[ "$takeover_status" == 137 ]]
"$PROBE" --assert-stale-action "$takeover_journal" "$takeover_fixture" \
    > "$takeover_root/successor.stdout" \
    2> "$takeover_root/successor.stderr"
grep -F "stale-action-rejected PASS" \
    "$takeover_root/successor.stdout" >/dev/null
takeover_count_after="$(wc -l < "$takeover_counter" | tr -d ' ')"
[[ "$takeover_count_before" == "$takeover_count_after" ]]
shasum -a 256 "$takeover_source" "$takeover_destination" \
    > "$takeover_root/user-after.sha256"
cmp "$takeover_root/user-before.sha256" "$takeover_root/user-after.sha256"
unset RASCAL_M3_SYSCALL_COUNTER_PATH
printf 'M3-JRN-SIGKILL-STALE-ACTION-001\tPASS\texit=0\n' \
    >> "$OUT/scenario-manifest.tsv"

[[ "$(wc -l < "$OUT/scenario-manifest.tsv" | tr -d ' ')" == 10 ]]
"$PYTHON_BIN" - "$OUT/swift-test.stdout" "$OUT/bindings.tsv" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
observed = re.findall(
    r"SQLiteOperationJournalTests (test[A-Za-z0-9_]+)\]' passed",
    text,
)
expected = {
    "testOpenConfiguresSchemaOwnerEpochAndRejectsSecondWriter",
    "testAdmissionReplayAndSequenceReservationSurviveRestart",
    "testEffectIntentAndResultAreImmutableAndReadBack",
    "testManifestIsImmutableAndOrderedForLeafToRootPurge",
    "testRecoveryActionOfferIsFencedByOwnerEpoch",
    "testSequenceReservationPreservesOldOwnerActionUntilAtomicReissue",
    "testRecoverySelectionRevokesSiblingAndRepeatedCheckpointIsStable",
    "testReceiptAllowsOnlyPendingToCompleteMonotonicProjection",
    "testReceiptEventAllowsOnlyRetainedSourceConvergence",
    "testReceiptAcceptsExactRetryAfterDurableNotPerformedAttempt",
    "testRetentionUsesExactAgeAndCountBoundaries",
    "testClearPreservesNonterminalAndFutureSchemaFailsClosed",
    "testCorruptEnvelopeAndMissingRequiredIndexFailClosed",
    "testCheckpointRejectsSequenceRollbackAndReceiptInjection",
}
if set(observed) != expected or len(observed) != len(expected):
    raise SystemExit(f"journal test inventory mismatch: {observed}")

bindings = {
    "M3-JRN-PRAGMA-001": [
        "testOpenConfiguresSchemaOwnerEpochAndRejectsSecondWriter",
        "testCorruptEnvelopeAndMissingRequiredIndexFailClosed",
    ],
    "M3-JRN-SCHEMA-001": [
        "testOpenConfiguresSchemaOwnerEpochAndRejectsSecondWriter",
        "testManifestIsImmutableAndOrderedForLeafToRootPurge",
        "testClearPreservesNonterminalAndFutureSchemaFailsClosed",
    ],
    "M3-JRN-LOCK-001": [
        "testOpenConfiguresSchemaOwnerEpochAndRejectsSecondWriter",
        "journal-process-self-check",
    ],
    "M3-JRN-TAKEOVER-001": [
        "testRecoveryActionOfferIsFencedByOwnerEpoch",
        "testSequenceReservationPreservesOldOwnerActionUntilAtomicReissue",
        "SIGKILL-stale-action-zero-effect",
    ],
    "M3-JRN-RETENTION-001": [
        "testRetentionUsesExactAgeAndCountBoundaries",
        "testClearPreservesNonterminalAndFutureSchemaFailsClosed",
    ],
    "M3-JRN-EVENT-001": [
        "testAdmissionReplayAndSequenceReservationSurviveRestart",
        "testEffectIntentAndResultAreImmutableAndReadBack",
        "testReceiptAllowsOnlyPendingToCompleteMonotonicProjection",
        "testCheckpointRejectsSequenceRollbackAndReceiptInjection",
    ],
    "M3-CORRUPT-MAIN-001": [
        "main-bit-set-immutable",
        "main-truncate-set-immutable",
        "service-safe-mode",
    ],
    "M3-CORRUPT-WAL-001": [
        "wal-bit-set-immutable",
        "wal-truncate-set-immutable",
        "service-safe-mode",
    ],
    "M3-CORRUPT-SHM-001": [
        "shm-anomaly-set-immutable",
        "service-safe-mode",
    ],
}
pathlib.Path(sys.argv[2]).write_text(
    "\n".join(
        f"{scenario}\tPASS\t{'+'.join(evidence)}"
        for scenario, evidence in bindings.items()
    ) + "\n"
)
PY
cmp "$OUT/head.txt" <(git -C "$ROOT" rev-parse HEAD)
echo "M3-JRN-PRAGMA-001 M3-JRN-SCHEMA-001 M3-JRN-LOCK-001 M3-JRN-TAKEOVER-001 M3-JRN-RETENTION-001 M3-JRN-EVENT-001 M3-CORRUPT-MAIN-001 M3-CORRUPT-WAL-001 M3-CORRUPT-SHM-001 PASS scenarios=10 skip=0 evidence=$OUT"
