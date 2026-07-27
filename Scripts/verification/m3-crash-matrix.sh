#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m3-crash/$RUN_ID}"
SCRATCH="${TMPDIR:-/tmp}/rascal-m3-crash-scratch-$RUN_ID"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rascal-m3-crash.XXXXXX")"
mkdir -p "$OUT" "$SCRATCH"

SOURCE_MOUNT=""
DESTINATION_MOUNT=""
FINALIZED=0

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if [[ -n "$DESTINATION_MOUNT" ]]; then
        hdiutil detach "$DESTINATION_MOUNT" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "$SOURCE_MOUNT" ]]; then
        hdiutil detach "$SOURCE_MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_ROOT" "$SCRATCH"
    git -C "$ROOT" rev-parse HEAD > "$OUT/head-end.txt"
    git -C "$ROOT" status --porcelain=v2 --untracked-files=all \
        > "$OUT/git-status-v2-end.txt"
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
trap cleanup EXIT

git -C "$ROOT" rev-parse HEAD > "$OUT/head.txt"
git -C "$ROOT" status --porcelain=v2 --untracked-files=all \
    > "$OUT/git-status-v2.txt"
git -C "$ROOT" diff --binary > "$OUT/unstaged.diff"
git -C "$ROOT" diff --cached --binary > "$OUT/staged.diff"
sw_vers > "$OUT/os.txt"
swift --version > "$OUT/swift.txt"

cd "$ROOT"
CFFIXED_USER_HOME="${TMPDIR:-/tmp}/rascal-m3-crash-home-$RUN_ID" \
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-crash-clang-$RUN_ID" \
SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-crash-swift-$RUN_ID" \
swift build --disable-sandbox --scratch-path "$SCRATCH" \
    --product FileOpsCrashProbe > "$OUT/build.stdout" 2> "$OUT/build.stderr"
PROBE="$SCRATCH/arm64-apple-macosx/debug/FileOpsCrashProbe"
[[ -x "$PROBE" ]] || {
    echo "FileOpsCrashProbe binary is missing" >&2
    exit 1
}
shasum -a 256 "$PROBE" > "$OUT/probe.sha256"

mount_image() {
    local image="$1" plist="$2"
    hdiutil attach -nobrowse -owners on -plist "$image" > "$plist"
    "$PYTHON_BIN" - "$plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)
mounts = [
    entry.get("mount-point")
    for entry in payload.get("system-entities", [])
    if entry.get("mount-point")
]
if len(mounts) != 1:
    raise SystemExit(f"expected exactly one mount point, got {mounts}")
print(mounts[0])
PY
}

hdiutil create -size 256m -fs APFS -volname RASCAL_M3_CRASH_SOURCE \
    "$TEMP_ROOT/source.dmg" > "$OUT/source-create.txt"
hdiutil create -size 256m -fs APFS -volname RASCAL_M3_CRASH_DESTINATION \
    "$TEMP_ROOT/destination.dmg" > "$OUT/destination-create.txt"
SOURCE_MOUNT="$(mount_image "$TEMP_ROOT/source.dmg" "$OUT/source-attach.plist")"
DESTINATION_MOUNT="$(
    mount_image "$TEMP_ROOT/destination.dmg" "$OUT/destination-attach.plist"
)"
diskutil info -plist "$SOURCE_MOUNT" > "$OUT/source-info.plist"
diskutil info -plist "$DESTINATION_MOUNT" > "$OUT/destination-info.plist"
"$PYTHON_BIN" - "$OUT/source-info.plist" "$OUT/destination-info.plist" \
    "$OUT/volume-identities.tsv" <<'PY'
import pathlib
import plistlib
import sys

rows = []
for label, path in zip(("source", "destination"), sys.argv[1:3]):
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    filesystem = info.get("FilesystemType") or info.get("Type (Bundle)")
    uuid = info.get("VolumeUUID")
    mount = info.get("MountPoint", "")
    if filesystem != "apfs" or not uuid:
        raise SystemExit(f"{label} is not attributable APFS: {filesystem} {uuid}")
    rows.append((label, uuid, filesystem, mount))
if rows[0][1] == rows[1][1]:
    raise SystemExit("source and destination crash volumes share one UUID")
pathlib.Path(sys.argv[3]).write_text(
    "label\tuuid\tfilesystem\tmount\n" +
    "\n".join("\t".join(row) for row in rows) + "\n"
)
PY

cat > "$OUT/effect-codes.tsv" <<'EOF'
COMMIT	stageCommit	normal-move	commit
BACKUP	backupDestination	normal-replace	commit
REPLCOMMIT	commitReplacement	normal-replace	commit
QUAR	quarantineSource	normal-cross-move	commit
QPURGENODE	purgeQuarantineNode	normal-cross-move	commit
QPURGEROOT	purgeQuarantineRoot	normal-cross-move	commit
ROLLBACK	rollbackCommittedDestination	restore-action	restore
RESTORE	restoreBackup	restore-action	restore
BACKUPPURGE	purgeBackup	finalize-action	commit
STAGEDISCARD	discardStaging	discard-action	discard
EOF

cat > "$OUT/windows.tsv" <<'EOF'
W1	intentDurableBeforeEffect
W2	effectReturnedBeforeResult
W3	resultDurableBeforeNextEffect
EOF

wait_for_ack() {
    local pid="$1" ack="$2"
    for _ in $(seq 1 600); do
        [[ -s "$ack" ]] && return 0
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.05
    done
    return 1
}

kill_acknowledged_worker() {
    local pid="$1" exit_file="$2"
    kill -9 "$pid"
    set +e
    wait "$pid"
    local status=$?
    set -e
    printf '%s\n' "$status" > "$exit_file"
    [[ "$status" == 137 ]]
}

operation_from_ack() {
    "$PYTHON_BIN" - "$1" <<'PY'
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(payload["operationID"]["rawValue"])
PY
}

validate_ack() {
    "$PYTHON_BIN" - "$@" <<'PY'
import json
import pathlib
import sys
import uuid

ack_path, scenario, nonce, kind, window = sys.argv[1:]
lines = pathlib.Path(ack_path).read_text().splitlines()
if len(lines) != 1:
    raise SystemExit(f"expected exactly one ACK, got {len(lines)}")
ack = json.loads(lines[0])
expected = {
    "scenarioID": scenario,
    "runNonce": nonce.upper(),
    "kind": kind,
    "window": window,
}
for key, value in expected.items():
    if ack.get(key) != value:
        raise SystemExit(f"ACK mismatch {key}: {ack.get(key)!r} != {value!r}")
uuid.UUID(ack["effectID"])
uuid.UUID(ack["ownerEpoch"])
uuid.UUID(ack["operationID"]["rawValue"])
uuid.UUID(ack["itemID"]["rawValue"])
if ack.get("effectOrdinal", 0) < 1 or ack.get("journalSequence", 0) < 1:
    raise SystemExit("ACK ordinal/sequence is not positive")
PY
}

capture_manifest() {
    local path="$1" output="$2"
    "$PYTHON_BIN" - "$path" "$output" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])

def xattrs(path):
    values = {}
    if not hasattr(os, "listxattr") or not hasattr(os, "getxattr"):
        return values
    try:
        names = sorted(os.listxattr(path, follow_symlinks=False))
    except OSError:
        return values
    for name in names:
        try:
            data = os.getxattr(path, name, follow_symlinks=False)
        except OSError:
            continue
        values[name] = hashlib.sha256(data).hexdigest()
    return values

def entry(path, relative):
    info = os.lstat(path)
    mode = stat.S_IFMT(info.st_mode)
    if stat.S_ISDIR(mode):
        kind = "directory"
    elif stat.S_ISREG(mode):
        kind = "regular"
    elif stat.S_ISLNK(mode):
        kind = "symlink"
    else:
        kind = "other"
    row = {
        "path": relative,
        "kind": kind,
        "mode": stat.S_IMODE(info.st_mode),
        "size": info.st_size if kind == "regular" else 0,
        "mtime_ns": info.st_mtime_ns,
        "device": info.st_dev,
        "inode": info.st_ino,
        "link_count": info.st_nlink,
        "xattrs": xattrs(path),
    }
    if kind == "regular":
        digest = hashlib.sha256()
        with open(path, "rb", buffering=0) as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        row["sha256"] = digest.hexdigest()
    elif kind == "symlink":
        row["target"] = os.readlink(path)
    return row

if not os.path.lexists(root):
    payload = {"exists": False, "entries": []}
else:
    rows = [entry(root, ".")]
    if root.is_dir() and not root.is_symlink():
        for current, directories, files in os.walk(root, followlinks=False):
            directories.sort()
            files.sort()
            for name in directories + files:
                path = pathlib.Path(current) / name
                relative = path.relative_to(root).as_posix()
                rows.append(entry(path, relative))
    payload = {"exists": True, "entries": sorted(rows, key=lambda row: row["path"])}
output.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

capture_case_manifest() {
    local path="$1" output="$2"
    "$PYTHON_BIN" - "$path" "$output" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
rows = []
if root.exists():
    for current, directories, files in os.walk(root, followlinks=False):
        directories[:] = sorted(directories)
        for name in sorted(directories + files):
            path = pathlib.Path(current) / name
            relative = path.relative_to(root).as_posix()
            if relative.startswith("operations.sqlite"):
                continue
            info = os.lstat(path)
            if stat.S_ISDIR(info.st_mode):
                kind, digest, size = "directory", None, 0
            elif stat.S_ISREG(info.st_mode):
                kind, size = "regular", info.st_size
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
            elif stat.S_ISLNK(info.st_mode):
                kind, size = "symlink", 0
                digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
            else:
                kind, size, digest = "other", info.st_size, None
            rows.append({
                "path": relative,
                "kind": kind,
                "mode": stat.S_IMODE(info.st_mode),
                "size": size,
                "digest": digest,
                "mtime_ns": info.st_mtime_ns,
                "device": info.st_dev,
                "inode": info.st_ino,
                "link_count": info.st_nlink,
            })
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(rows, sort_keys=True, separators=(",", ":")) + "\n"
)
PY
}

capture_recovery_manifest() {
    local label="$1" source_case="$2" destination_case="$3"
    local path_output="$4" manifest_output="$5"
    local selected
    selected="$(
        "$PYTHON_BIN" - "$label" "$source_case" "$destination_case" <<'PY'
import pathlib
import sys

label, source_root, destination_root = sys.argv[1:]
matches = []
for root in (pathlib.Path(source_root), pathlib.Path(destination_root)):
    if not root.exists():
        continue
    matches.extend(
        path for path in root.glob(f".rascal-{label}-*")
        if path.exists() or path.is_symlink()
    )
if len(matches) > 1:
    raise SystemExit(f"multiple registered {label} objects: {matches}")
print(str(matches[0]) if matches else "")
PY
    )"
    printf '%s\n' "$selected" > "$path_output"
    if [[ -n "$selected" ]]; then
        capture_manifest "$selected" "$manifest_output"
    else
        capture_manifest \
            "$manifest_output.absent-sentinel" "$manifest_output"
    fi
}

prepare_cross_tree() {
    local source="$1"
    mkdir -p "$source/nested"
    mkfile 16k "$source/nested/payload.bin"
}

prepare_replace() {
    local source="$1" destination="$2"
    mkfile 16k "$source"
    mkfile 32k "$destination"
}

run_setup_discard() {
    local scenario_root="$1" journal="$2" source="$3" destination="$4"
    local setup_ack="$scenario_root/setup-ack.jsonl"
    local setup_nonce
    setup_nonce="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    "$PROBE" --real-worker "$journal" "$source" "$destination" move \
        stageCommit intentDurableBeforeEffect \
        "M3-SETUP-STAGEDISCARD-W1-001" "$setup_nonce" \
        > "$setup_ack" 2> "$scenario_root/setup-worker.stderr" &
    local setup_pid=$!
    printf '%s\n' "$setup_pid" > "$scenario_root/setup-worker.pid"
    if ! wait_for_ack "$setup_pid" "$setup_ack"; then
        kill -9 "$setup_pid" 2>/dev/null || true
        wait "$setup_pid" 2>/dev/null || true
        echo "discard setup did not emit stageCommit W1 ACK" >&2
        exit 1
    fi
    kill_acknowledged_worker "$setup_pid" "$scenario_root/setup-worker.exit"
    operation_from_ack "$setup_ack"
}

run_convergence() {
    local journal="$1" operation="$2" strategy="$3"
    local stdout="$4" stderr="$5" attempts_file="$6"
    local status=1
    for attempt in $(seq 1 40); do
        set +e
        "$PROBE" --real-converge "$journal" "$operation" "$strategy" \
            > "$stdout" 2> "$stderr"
        status=$?
        set -e
        printf '%s\t%s\n' "$attempt" "$status" >> "$attempts_file"
        [[ "$status" == 0 ]] && return 0
        if ! grep -F "alreadyOwned" "$stderr" >/dev/null; then
            return "$status"
        fi
        sleep 0.05
    done
    return "$status"
}

: > "$OUT/scenario-manifest.tsv"
while IFS=$'\t' read -r code kind fixture strategy; do
    if [[ -n "${M3_CRASH_ONLY_CODE:-}" &&
          "$code" != "$M3_CRASH_ONLY_CODE" ]]; then
        continue
    fi
    while IFS=$'\t' read -r window_code window; do
        scenario="M3-CRASH-${code}-${window_code}-001"
        scenario_root="$OUT/scenarios/$scenario"
        source_case="$SOURCE_MOUNT/cases/$scenario"
        destination_case="$DESTINATION_MOUNT/cases/$scenario"
        journal="$destination_case/operations.sqlite"
        mkdir -p "$scenario_root" "$source_case" "$destination_case"
        nonce="$(uuidgen | tr '[:upper:]' '[:lower:]')"
        printf '%s\n' "$nonce" > "$scenario_root/nonce.txt"
        syscall_counter="$scenario_root/syscall-attempts.tsv"
        : > "$syscall_counter"
        export RASCAL_M3_SYSCALL_COUNTER_PATH="$syscall_counter"

        operation=""
        action=""
        source=""
        destination=""
        case "$fixture" in
            normal-move)
                source="$destination_case/source.bin"
                destination="$destination_case/destination.bin"
                mkfile 16k "$source"
                ;;
            normal-replace)
                source="$destination_case/new.bin"
                destination="$destination_case/final.bin"
                prepare_replace "$source" "$destination"
                ;;
            normal-cross-move)
                source="$source_case/source-tree"
                destination="$destination_case/moved-tree"
                prepare_cross_tree "$source"
                ;;
            restore-action|finalize-action)
                source="$destination_case/new.bin"
                destination="$destination_case/final.bin"
                prepare_replace "$source" "$destination"
                capture_manifest \
                    "$source" "$scenario_root/source-before.manifest.json"
                capture_manifest \
                    "$destination" "$scenario_root/destination-before.manifest.json"
                "$PROBE" --real-prepare "$journal" "$source" "$destination" replace \
                    > "$scenario_root/prepare.stdout" \
                    2> "$scenario_root/prepare.stderr"
                operation="$(tr -d '[:space:]' < "$scenario_root/prepare.stdout")"
                if [[ "$fixture" == restore-action ]]; then
                    action="restoreBackup"
                else
                    action="finalizeKnownCommit"
                fi
                ;;
            discard-action)
                source="$source_case/source-tree"
                destination="$destination_case/moved-tree"
                prepare_cross_tree "$source"
                operation="$(
                    run_setup_discard \
                        "$scenario_root" "$journal" "$source" "$destination"
                )"
                action="discardKnownStaging"
                ;;
            *)
                echo "unknown real crash fixture: $fixture" >&2
                exit 1
                ;;
        esac
        printf '%s\n' "$source" > "$scenario_root/source-path.txt"
        printf '%s\n' "$destination" > "$scenario_root/destination-path.txt"
        if [[ ! -f "$scenario_root/source-before.manifest.json" ]]; then
            capture_manifest "$source" "$scenario_root/source-before.manifest.json"
        fi
        if [[ ! -f "$scenario_root/destination-before.manifest.json" ]]; then
            capture_manifest \
                "$destination" "$scenario_root/destination-before.manifest.json"
        fi

        if [[ -n "$action" ]]; then
            printf '%q ' "$PROBE" --real-action "$journal" "$operation" "$action" \
                "$kind" "$window" "$scenario" "$nonce" \
                > "$scenario_root/command.txt"
            printf '\n' >> "$scenario_root/command.txt"
            "$PROBE" --real-action "$journal" "$operation" "$action" \
                "$kind" "$window" "$scenario" "$nonce" \
                > "$scenario_root/ack.jsonl" \
                2> "$scenario_root/worker.stderr" &
        else
            local_kind=move
            [[ "$fixture" == normal-replace ]] && local_kind=replace
            printf '%q ' "$PROBE" --real-worker "$journal" "$source" "$destination" \
                "$local_kind" "$kind" "$window" "$scenario" "$nonce" \
                > "$scenario_root/command.txt"
            printf '\n' >> "$scenario_root/command.txt"
            "$PROBE" --real-worker "$journal" "$source" "$destination" \
                "$local_kind" "$kind" "$window" "$scenario" "$nonce" \
                > "$scenario_root/ack.jsonl" \
                2> "$scenario_root/worker.stderr" &
        fi
        worker_pid=$!
        printf '%s\n' "$worker_pid" > "$scenario_root/worker.pid"

        if ! wait_for_ack "$worker_pid" "$scenario_root/ack.jsonl"; then
            kill -9 "$worker_pid" 2>/dev/null || true
            wait "$worker_pid" 2>/dev/null || true
            echo "$scenario did not emit its real target ACK" >&2
            exit 1
        fi
        validate_ack "$scenario_root/ack.jsonl" \
            "$scenario" "$nonce" "$kind" "$window"
        if [[ -z "$operation" ]]; then
            operation="$(operation_from_ack "$scenario_root/ack.jsonl")"
        fi
        printf '%s\n' "$operation" > "$scenario_root/operation.txt"

        # Freeze the exact filesystem state while the acknowledged worker is
        # still alive and paused at W1/W2/W3. These snapshots are distinct
        # from post-recovery evidence and make crash-window predicates
        # independently attributable.
        capture_manifest "$source" \
            "$scenario_root/source-at-ack.manifest.json"
        capture_manifest "$destination" \
            "$scenario_root/destination-at-ack.manifest.json"
        capture_case_manifest "$source_case" \
            "$scenario_root/source-case-at-ack.manifest.json"
        capture_case_manifest "$destination_case" \
            "$scenario_root/destination-case-at-ack.manifest.json"
        for recovery_label in stage backup quarantine replacement rollback; do
            capture_recovery_manifest \
                "$recovery_label" "$source_case" "$destination_case" \
                "$scenario_root/$recovery_label-at-ack.path.txt" \
                "$scenario_root/$recovery_label-at-ack.manifest.json"
        done
        cp "$syscall_counter" "$scenario_root/syscall-attempts-at-ack.tsv"

        # After the whole-root purge preflight has passed, inject a manifest
        # outsider when the quarantine still exists. Recovery must preserve it.
        if [[ "$code" == QPURGENODE || "$code" == QPURGEROOT ]]; then
            quarantine="$(
                find "$source_case" -maxdepth 1 \
                    -name '.rascal-quarantine-*' -type d -print -quit
            )"
            if [[ -n "$quarantine" ]]; then
                sentinel="$quarantine/unexpected-survivor.bin"
                mkfile 1k "$sentinel"
                printf '%s\n' "$sentinel" > "$scenario_root/sentinel-path.txt"
            fi
        fi

        kill_acknowledged_worker "$worker_pid" "$scenario_root/worker.exit"

        run_convergence "$journal" "$operation" "$strategy" \
            "$scenario_root/recovery-1.json" \
            "$scenario_root/recovery-1.stderr" \
            "$scenario_root/recovery-1-attempts.tsv"
        capture_manifest "$source" "$scenario_root/source-after-recovery-1.manifest.json"
        capture_manifest "$destination" \
            "$scenario_root/destination-after-recovery-1.manifest.json"
        capture_case_manifest "$source_case" \
            "$scenario_root/source-case-after-recovery-1.manifest.json"
        capture_case_manifest "$destination_case" \
            "$scenario_root/destination-case-after-recovery-1.manifest.json"
        wc -l < "$syscall_counter" \
            | tr -d ' ' > "$scenario_root/syscall-count-after-recovery-1.txt"
        run_convergence "$journal" "$operation" "$strategy" \
            "$scenario_root/recovery-2.json" \
            "$scenario_root/recovery-2.stderr" \
            "$scenario_root/recovery-2-attempts.tsv"
        capture_manifest "$source" "$scenario_root/source-after-recovery-2.manifest.json"
        capture_manifest "$destination" \
            "$scenario_root/destination-after-recovery-2.manifest.json"
        capture_case_manifest "$source_case" \
            "$scenario_root/source-case-after-recovery-2.manifest.json"
        capture_case_manifest "$destination_case" \
            "$scenario_root/destination-case-after-recovery-2.manifest.json"
        wc -l < "$syscall_counter" \
            | tr -d ' ' > "$scenario_root/syscall-count-after-recovery-2.txt"

        "$PYTHON_BIN" - "$scenario_root/recovery-1.json" \
            "$scenario_root/recovery-2.json" "$scenario_root/ack.jsonl" \
            "$code" "$window_code" "$strategy" "$source" "$destination" \
            "$scenario_root" <<'PY'
import json
import pathlib
import sys

(
    first_path,
    second_path,
    ack_path,
    code,
    window,
    strategy,
    source_path,
    destination_path,
    scenario_root,
) = sys.argv[1:]
first = json.loads(pathlib.Path(first_path).read_text())
second = json.loads(pathlib.Path(second_path).read_text())
ack = json.loads(pathlib.Path(ack_path).read_text())
root = pathlib.Path(scenario_root)
source = pathlib.Path(source_path)
destination = pathlib.Path(destination_path)

if first["ownerEpoch"].lower() == ack["ownerEpoch"].lower():
    raise SystemExit("recovery reused the SIGKILLed owner epoch")
effect_key = lambda effect: (
    effect["effectID"],
    effect["itemID"],
    effect["kind"],
    effect["ordinal"],
    effect["ownerEpoch"],
    effect["intentSequence"],
    effect.get("resultSequence"),
    effect.get("status"),
    effect.get("nodeID"),
    effect.get("relativePath"),
    effect.get("manifestDigest"),
)
if [effect_key(x) for x in first["effects"]] != [
    effect_key(x) for x in second["effects"]
]:
    raise SystemExit("repeated recovery changed the durable effect inventory")
if len({effect["effectID"] for effect in first["effects"]}) != len(first["effects"]):
    raise SystemExit("duplicate durable effect ID")
if first["operationID"].lower() != ack["operationID"]["rawValue"].lower():
    raise SystemExit("ACK operation does not match the recovered operation")
matching_effects = [
    effect for effect in first["effects"]
    if effect["effectID"].lower() == ack["effectID"].lower()
]
if len(matching_effects) != 1:
    raise SystemExit("ACK effect ID is not uniquely present in the recovered journal")
target_effect = matching_effects[0]
expected_sequence = (
    target_effect.get("resultSequence")
    if window == "W3"
    else target_effect["intentSequence"]
)
expected_ack_fields = {
    "itemID": target_effect["itemID"],
    "kind": target_effect["kind"],
    "effectOrdinal": target_effect["ordinal"],
    "ownerEpoch": target_effect["ownerEpoch"],
    "journalSequence": expected_sequence,
    "nodeID": target_effect.get("nodeID"),
    "relativePath": target_effect.get("relativePath"),
    "manifestDigest": target_effect.get("manifestDigest"),
}
actual_ack_fields = {
    "itemID": ack["itemID"]["rawValue"],
    "kind": ack["kind"],
    "effectOrdinal": ack["effectOrdinal"],
    "ownerEpoch": ack["ownerEpoch"],
    "journalSequence": ack["journalSequence"],
    "nodeID": ack.get("nodeID"),
    "relativePath": ack.get("relativePath"),
    "manifestDigest": ack.get("manifestDigest"),
}
for key, expected in expected_ack_fields.items():
    actual = actual_ack_fields[key]
    if key in {"itemID", "ownerEpoch"}:
        expected = expected.lower()
        actual = actual.lower()
    if actual != expected:
        raise SystemExit(
            f"ACK {key} is not bound to its durable effect: {actual!r} != {expected!r}"
        )

terminal = {"completed", "rolledBack", "cancelled"}
safe_recovery = {
    "committing",
    "committedAwaitingCleanup",
    "sourceQuarantining",
    "cleaningSource",
    "cleanupRequired",
    "recoveryRequired",
}
if first["state"] not in terminal | safe_recovery:
    raise SystemExit(f"unsafe/unexpected recovery state: {first['state']}")
if strategy == "restore" and first["state"] != "rolledBack":
    raise SystemExit(f"restore did not converge to rolledBack: {first}")
if strategy == "discard":
    if window == "W2":
        if first["state"] != "recoveryRequired" or not first.get("recoveryError"):
            raise SystemExit(f"ambiguous discard W2 did not fail closed: {first}")
    elif first["state"] != "cancelled":
        raise SystemExit(f"discard did not converge to cancelled: {first}")

if first["state"] in safe_recovery:
    if not first["actionNames"] and not first.get("recoveryError"):
        raise SystemExit(
            f"nonterminal recovery is stuck without an action or error: {first}"
        )

def load_manifest(name):
    return json.loads((root / name).read_text())

def semantic_manifest(payload):
    volatile_identity = {"device", "inode", "link_count"}
    return {
        "exists": payload["exists"],
        "entries": [
            {
                key: value
                for key, value in entry.items()
                if key not in volatile_identity
            }
            for entry in payload["entries"]
        ],
    }

def root_identity(payload):
    if not payload["exists"] or not payload["entries"]:
        return None
    root_entry = next(
        (entry for entry in payload["entries"] if entry["path"] == "."),
        None,
    )
    if root_entry is None:
        return None
    return (
        root_entry.get("device"),
        root_entry.get("inode"),
        root_entry.get("kind"),
    )

def require_absent(payload, label):
    if payload["exists"]:
        raise SystemExit(f"{label} unexpectedly exists at acknowledged window")

def require_complete(payload, expected, label):
    if semantic_manifest(payload) != semantic_manifest(expected):
        raise SystemExit(f"{label} is not a complete canonical manifest")

def partial_entry_view(entry):
    ignored = {"device", "inode", "link_count"}
    if entry["kind"] == "directory":
        ignored.add("mtime_ns")
    return {
        key: value for key, value in entry.items()
        if key not in ignored
    }

def require_only_relative_removed(payload, expected, relative, label):
    if relative == ".":
        require_absent(payload, label)
        return
    if not payload["exists"]:
        raise SystemExit(f"{label} root disappeared while removing {relative}")
    expected_entries = {
        entry["path"]: partial_entry_view(entry)
        for entry in expected["entries"]
    }
    actual_entries = {
        entry["path"]: partial_entry_view(entry)
        for entry in payload["entries"]
    }
    if relative not in expected_entries:
        raise SystemExit(f"{label} ACK relative path is not in frozen manifest: {relative}")
    expected_entries.pop(relative)
    if actual_entries != expected_entries:
        raise SystemExit(
            f"{label} changed nodes other than acknowledged relative path {relative}"
        )

source_before_raw = load_manifest("source-before.manifest.json")
destination_before_raw = load_manifest("destination-before.manifest.json")
source_after_raw = load_manifest("source-after-recovery-1.manifest.json")
destination_after_raw = load_manifest("destination-after-recovery-1.manifest.json")
source_repeat_raw = load_manifest("source-after-recovery-2.manifest.json")
destination_repeat_raw = load_manifest("destination-after-recovery-2.manifest.json")

if source_after_raw != source_repeat_raw or destination_after_raw != destination_repeat_raw:
    raise SystemExit("repeated recovery changed a source/destination manifest")
if load_manifest("source-case-after-recovery-1.manifest.json") != \
        load_manifest("source-case-after-recovery-2.manifest.json"):
    raise SystemExit("repeated recovery changed the source-case filesystem")
if load_manifest("destination-case-after-recovery-1.manifest.json") != \
        load_manifest("destination-case-after-recovery-2.manifest.json"):
    raise SystemExit("repeated recovery changed the destination-case filesystem")

counter_lines = [
    line.split("\t")
    for line in (root / "syscall-attempts.tsv").read_text().splitlines()
    if line
]
if any(len(fields) != 6 for fields in counter_lines):
    raise SystemExit("malformed syscall-attempt evidence")
effect_attempt_ids = [fields[0].lower() for fields in counter_lines]
if len(effect_attempt_ids) != len(set(effect_attempt_ids)):
    raise SystemExit("one durable effect ID attempted more than one filesystem syscall")
effect_by_id = {
    effect["effectID"].lower(): effect for effect in first["effects"]
}
for fields in counter_lines:
    effect_id, operation_id, item_id, kind, ordinal, owner_epoch = fields
    effect = effect_by_id.get(effect_id.lower())
    if effect is None:
        raise SystemExit(f"syscall counter effect is not durable: {effect_id}")
    expected_fields = (
        first["operationID"].lower(),
        effect["itemID"].lower(),
        effect["kind"],
        str(effect["ordinal"]),
        effect["ownerEpoch"].lower(),
    )
    actual_fields = (
        operation_id.lower(),
        item_id.lower(),
        kind,
        ordinal,
        owner_epoch.lower(),
    )
    if actual_fields != expected_fields:
        raise SystemExit(
            f"syscall counter is not bound to durable effect {effect_id}: "
            f"{actual_fields!r} != {expected_fields!r}"
        )
completed_effect_ids = {
    effect["effectID"].lower()
    for effect in first["effects"]
    if effect.get("status") == "completed"
}
expected_attempt_ids = set(completed_effect_ids)
if window == "W2":
    # The process emitted W2 only after the target effect returned, but its
    # result was intentionally not durable. A later conservative inspection
    # may classify that already-issued syscall as ambiguous.
    expected_attempt_ids.add(ack["effectID"].lower())
if set(effect_attempt_ids) != expected_attempt_ids:
    raise SystemExit(
        "syscall counter set does not equal the ACK-attributed destructive set: "
        f"counter={sorted(effect_attempt_ids)} "
        f"expected={sorted(expected_attempt_ids)}"
    )
first_count = int((root / "syscall-count-after-recovery-1.txt").read_text())
second_count = int((root / "syscall-count-after-recovery-2.txt").read_text())
if first_count != second_count or second_count != len(counter_lines):
    raise SystemExit("repeated recovery issued another filesystem syscall")

ack_counter_lines = [
    line.split("\t")
    for line in (root / "syscall-attempts-at-ack.tsv").read_text().splitlines()
    if line
]
if any(len(fields) != 6 for fields in ack_counter_lines):
    raise SystemExit("malformed acknowledged-window syscall evidence")
ack_counter_ids = {fields[0].lower() for fields in ack_counter_lines}
target_effect_id = ack["effectID"].lower()
if window == "W1" and target_effect_id in ack_counter_ids:
    raise SystemExit("W1 target reached the destructive syscall before ACK")
if window in {"W2", "W3"} and target_effect_id not in ack_counter_ids:
    raise SystemExit("W2/W3 target ACK lacks a syscall-adjacent counter record")

source_at_ack = load_manifest("source-at-ack.manifest.json")
destination_at_ack = load_manifest("destination-at-ack.manifest.json")
stage_at_ack = load_manifest("stage-at-ack.manifest.json")
backup_at_ack = load_manifest("backup-at-ack.manifest.json")
quarantine_at_ack = load_manifest("quarantine-at-ack.manifest.json")
replacement_at_ack = load_manifest("replacement-at-ack.manifest.json")
post_effect_window = window in {"W2", "W3"}

if code == "COMMIT":
    if post_effect_window:
        require_absent(source_at_ack, "COMMIT source")
        require_complete(destination_at_ack, source_before_raw, "COMMIT final")
        if root_identity(destination_at_ack) != root_identity(source_before_raw):
            raise SystemExit("same-volume COMMIT did not preserve source identity")
    else:
        require_complete(source_at_ack, source_before_raw, "COMMIT source")
        require_absent(destination_at_ack, "COMMIT final")
elif code == "BACKUP":
    require_complete(source_at_ack, source_before_raw, "BACKUP replacement source")
    require_complete(stage_at_ack, source_before_raw, "BACKUP registered stage")
    if post_effect_window:
        require_absent(destination_at_ack, "BACKUP final")
        require_complete(backup_at_ack, destination_before_raw, "BACKUP old backup")
        if root_identity(backup_at_ack) != root_identity(destination_before_raw):
            raise SystemExit("BACKUP did not preserve old destination identity")
    else:
        require_complete(destination_at_ack, destination_before_raw, "BACKUP final")
        require_absent(backup_at_ack, "BACKUP registered backup")
elif code == "REPLCOMMIT":
    require_complete(source_at_ack, source_before_raw, "REPLCOMMIT source")
    require_complete(backup_at_ack, destination_before_raw, "REPLCOMMIT old backup")
    if post_effect_window:
        require_complete(destination_at_ack, source_before_raw, "REPLCOMMIT final")
        require_absent(stage_at_ack, "REPLCOMMIT registered stage")
    else:
        require_absent(destination_at_ack, "REPLCOMMIT final")
        require_complete(stage_at_ack, source_before_raw, "REPLCOMMIT registered stage")
elif code == "QUAR":
    require_complete(destination_at_ack, source_before_raw, "QUAR destination")
    if post_effect_window:
        require_absent(source_at_ack, "QUAR source")
        require_complete(quarantine_at_ack, source_before_raw, "QUAR quarantine")
        if root_identity(quarantine_at_ack) != root_identity(source_before_raw):
            raise SystemExit("QUAR did not preserve source identity")
    else:
        require_complete(source_at_ack, source_before_raw, "QUAR source")
        require_absent(quarantine_at_ack, "QUAR quarantine")
elif code == "QPURGENODE":
    require_complete(destination_at_ack, source_before_raw, "QPURGENODE destination")
    require_absent(source_at_ack, "QPURGENODE source")
    if post_effect_window:
        require_only_relative_removed(
            quarantine_at_ack,
            source_before_raw,
            ack.get("relativePath"),
            "QPURGENODE quarantine",
        )
    else:
        require_complete(
            quarantine_at_ack,
            source_before_raw,
            "QPURGENODE quarantine",
        )
elif code == "QPURGEROOT":
    require_complete(destination_at_ack, source_before_raw, "QPURGEROOT destination")
    require_absent(source_at_ack, "QPURGEROOT source")
    if post_effect_window:
        require_absent(quarantine_at_ack, "QPURGEROOT quarantine")
    elif (
        not quarantine_at_ack["exists"] or
        [entry["path"] for entry in quarantine_at_ack["entries"]] != ["."]
    ):
        raise SystemExit("QPURGEROOT W1 did not retain the empty registered root")
elif code == "ROLLBACK":
    require_complete(source_at_ack, source_before_raw, "ROLLBACK source")
    require_complete(backup_at_ack, destination_before_raw, "ROLLBACK backup")
    if post_effect_window:
        require_absent(destination_at_ack, "ROLLBACK final")
        require_complete(
            replacement_at_ack,
            source_before_raw,
            "ROLLBACK registered replacement",
        )
    else:
        require_complete(destination_at_ack, source_before_raw, "ROLLBACK final")
        require_absent(replacement_at_ack, "ROLLBACK registered replacement")
elif code == "RESTORE":
    require_complete(source_at_ack, source_before_raw, "RESTORE source")
    require_complete(
        replacement_at_ack,
        source_before_raw,
        "RESTORE registered replacement",
    )
    if post_effect_window:
        require_complete(destination_at_ack, destination_before_raw, "RESTORE final")
        require_absent(backup_at_ack, "RESTORE backup")
        if root_identity(destination_at_ack) != root_identity(destination_before_raw):
            raise SystemExit("RESTORE did not preserve old destination identity")
    else:
        require_absent(destination_at_ack, "RESTORE final")
        require_complete(backup_at_ack, destination_before_raw, "RESTORE backup")
elif code == "BACKUPPURGE":
    require_complete(source_at_ack, source_before_raw, "BACKUPPURGE source")
    require_complete(destination_at_ack, source_before_raw, "BACKUPPURGE final")
    if post_effect_window:
        require_absent(backup_at_ack, "BACKUPPURGE backup")
    else:
        require_complete(backup_at_ack, destination_before_raw, "BACKUPPURGE backup")
elif code == "STAGEDISCARD":
    require_complete(source_at_ack, source_before_raw, "STAGEDISCARD source")
    require_absent(destination_at_ack, "STAGEDISCARD final")
    if post_effect_window:
        require_only_relative_removed(
            stage_at_ack,
            source_before_raw,
            ack.get("relativePath"),
            "STAGEDISCARD registered stage",
        )
    else:
        require_complete(
            stage_at_ack,
            source_before_raw,
            "STAGEDISCARD registered stage",
        )

source_before = semantic_manifest(source_before_raw)
destination_before = semantic_manifest(destination_before_raw)
source_after = semantic_manifest(source_after_raw)
destination_after = semantic_manifest(destination_after_raw)

if code == "COMMIT":
    if destination_after != source_before or source_after["exists"]:
        raise SystemExit("COMMIT did not move the complete source manifest")
elif code in {"BACKUP", "REPLCOMMIT", "BACKUPPURGE"}:
    if destination_after != source_before or source_after != source_before:
        raise SystemExit(f"{code} did not preserve the complete replacement manifests")
elif code in {"ROLLBACK", "RESTORE"}:
    if destination_after != destination_before or source_after != source_before:
        raise SystemExit(f"{code} did not restore the exact original manifests")
elif code in {"QUAR", "QPURGENODE", "QPURGEROOT"}:
    if destination_after != source_before:
        raise SystemExit(f"{code} committed destination manifest differs from source")
elif code == "STAGEDISCARD":
    if destination_after["exists"] or source_after != source_before:
        raise SystemExit("discard changed source or exposed a destination")

sentinel_path = root / "sentinel-path.txt"
if sentinel_path.exists():
    sentinel = pathlib.Path(sentinel_path.read_text().strip())
    if not sentinel.is_file() or sentinel.stat().st_size != 1024:
        raise SystemExit("purge deleted or changed a manifest-external object")

(root / "predicate-summary.txt").write_text(
    f"state={first['state']}\n"
    f"repeat_state={second['state']}\n"
    f"effect_count={len(first['effects'])}\n"
    f"syscall_attempts={len(counter_lines)}\n"
    f"recovery_error={first.get('recoveryError')}\n"
)
PY
        unset RASCAL_M3_SYSCALL_COUNTER_PATH

        printf '%s\t%s\t%s\t%s\tPASS\n' \
            "$scenario" "$kind" "$window" "$fixture" \
            >> "$OUT/scenario-manifest.tsv"
    done < "$OUT/windows.tsv"
done < "$OUT/effect-codes.tsv"

expected_scenarios=30
[[ -z "${M3_CRASH_ONLY_CODE:-}" ]] || expected_scenarios=3
[[ "$(wc -l < "$OUT/scenario-manifest.tsv" | tr -d ' ')" == "$expected_scenarios" ]]
[[ "$(
    awk -F'\t' '$5=="PASS"{count++} END{print count+0}' \
        "$OUT/scenario-manifest.tsv"
)" == "$expected_scenarios" ]]
cmp "$OUT/head.txt" <(git -C "$ROOT" rev-parse HEAD)
FINALIZED=1
if [[ -n "${M3_CRASH_ONLY_CODE:-}" ]]; then
    echo "M3-CRASH-SUBSET PASS code=$M3_CRASH_ONLY_CODE scenarios=3 evidence=$OUT"
else
    echo "M3-CRASH-001 PASS scenarios=30 real_operations=30 skip=0 evidence=$OUT"
fi
