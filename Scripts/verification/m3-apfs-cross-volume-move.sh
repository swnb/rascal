#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m3-apfs-move/$RUN_ID}"
SCRATCH="${TMPDIR:-/tmp}/rascal-m3-apfs-scratch-$RUN_ID"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rascal-m3-apfs.XXXXXX")"
mkdir -p "$OUT" "$SCRATCH"

SOURCE_MOUNT=""
DESTINATION_MOUNT=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$DESTINATION_MOUNT" ]]; then
        hdiutil detach "$DESTINATION_MOUNT" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "$SOURCE_MOUNT" ]]; then
        hdiutil detach "$SOURCE_MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_ROOT" "$SCRATCH"
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

mount_image() {
    local image="$1" plist="$2"
    hdiutil attach -nobrowse -owners on -plist "$image" > "$plist"
    "$PYTHON_BIN" - "$plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)
mounts = [entry.get("mount-point") for entry in payload.get("system-entities", [])]
mounts = [value for value in mounts if value]
if len(mounts) != 1:
    raise SystemExit(f"expected exactly one mount point, got {mounts}")
print(mounts[0])
PY
}

hdiutil create -size 128m -fs APFS -volname RASCAL_M3_SOURCE \
    "$TEMP_ROOT/source.dmg" > "$OUT/source-create.txt"
hdiutil create -size 128m -fs APFS -volname RASCAL_M3_DESTINATION \
    "$TEMP_ROOT/destination.dmg" > "$OUT/destination-create.txt"
SOURCE_MOUNT="$(mount_image "$TEMP_ROOT/source.dmg" "$OUT/source-attach.plist")"
DESTINATION_MOUNT="$(mount_image "$TEMP_ROOT/destination.dmg" "$OUT/destination-attach.plist")"

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
    if filesystem != "apfs" or not uuid:
        raise SystemExit(f"{label} is not attributable APFS: fs={filesystem} uuid={uuid}")
    rows.append((label, uuid, filesystem, info.get("MountPoint", "")))
if rows[0][1] == rows[1][1]:
    raise SystemExit("M3 source and destination volume UUIDs are equal")
pathlib.Path(sys.argv[3]).write_text(
    "label\tuuid\tfilesystem\tmount\n" +
    "\n".join("\t".join(row) for row in rows) + "\n"
)
PY

run_suite() {
    local filter="$1" name="$2" expected="$3"
    (
        cd "$ROOT"
        RASCAL_M3_VOLUME_A="$SOURCE_MOUNT" \
        RASCAL_M3_VOLUME_B="$DESTINATION_MOUNT" \
        CFFIXED_USER_HOME="${TMPDIR:-/tmp}/rascal-m3-apfs-home-$RUN_ID" \
        CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-apfs-clang-$RUN_ID" \
        SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/rascal-m3-apfs-swift-$RUN_ID" \
        swift test --disable-sandbox --scratch-path "$SCRATCH" \
            --filter "$filter"
    ) > "$OUT/$name.stdout" 2> "$OUT/$name.stderr"
    grep -F "Executed $expected tests, with 0 failures" \
        "$OUT/$name.stdout" >/dev/null
    if grep -Fi "skipped" "$OUT/$name.stdout" "$OUT/$name.stderr" >/dev/null; then
        echo "M3 mandatory $name suite reported a skip" >&2
        exit 1
    fi
}

run_suite NativeTransactionalMoveTests move-tests 9
run_suite NativeTransactionalReplaceTests replace-tests 8
run_suite RecoverySafetyTests recovery-action-tests 36

PROBE="$SCRATCH/arm64-apple-macosx/debug/FileOpsCrashProbe"
[[ -x "$PROBE" ]]
retain_root="$OUT/restart-retain"
retain_source="$SOURCE_MOUNT/restart-retain-source.bin"
retain_destination="$DESTINATION_MOUNT/restart-retain-destination.bin"
retain_journal="$DESTINATION_MOUNT/restart-retain-operations.sqlite"
retain_counter="$retain_root/syscall-attempts.tsv"
mkdir -p "$retain_root"
mkfile 16k "$retain_source"
: > "$retain_counter"
export RASCAL_M3_SYSCALL_COUNTER_PATH="$retain_counter"
"$PROBE" --real-barrier-worker \
    "$retain_journal" "$retain_source" "$retain_destination" \
    > "$retain_root/worker.stdout" 2> "$retain_root/worker.stderr" &
retain_pid=$!
printf '%s\n' "$retain_pid" > "$retain_root/worker.pid"
for _ in $(seq 1 600); do
    grep -F "retain-barrier " "$retain_root/worker.stdout" >/dev/null 2>&1 \
        && break
    kill -0 "$retain_pid" 2>/dev/null || break
    sleep 0.05
done
grep -F "retain-barrier " "$retain_root/worker.stdout" >/dev/null
retain_operation="$(
    awk '/^retain-barrier /{print $2; exit}' "$retain_root/worker.stdout"
)"
[[ -n "$retain_operation" ]]
shasum -a 256 "$retain_source" "$retain_destination" \
    > "$retain_root/user-before.sha256"
retain_count_before="$(wc -l < "$retain_counter" | tr -d ' ')"
kill -9 "$retain_pid"
set +e
wait "$retain_pid"
retain_status=$?
set -e
printf '%s\n' "$retain_status" > "$retain_root/worker.exit"
[[ "$retain_status" == 137 ]]
"$PROBE" --real-retain "$retain_journal" "$retain_operation" \
    > "$retain_root/restart.stdout" 2> "$retain_root/restart.stderr"
grep -F "restart-retain PASS" "$retain_root/restart.stdout" >/dev/null
retain_count_after="$(wc -l < "$retain_counter" | tr -d ' ')"
[[ "$retain_count_before" == "$retain_count_after" ]]
shasum -a 256 "$retain_source" "$retain_destination" \
    > "$retain_root/user-after.sha256"
cmp "$retain_root/user-before.sha256" "$retain_root/user-after.sha256"
unset RASCAL_M3_SYSCALL_COUNTER_PATH

"$PYTHON_BIN" - \
    "$OUT/move-tests.stdout" \
    "$OUT/replace-tests.stdout" \
    "$OUT/recovery-action-tests.stdout" \
    "$OUT/bindings.tsv" <<'PY'
import pathlib
import re
import sys

def observed(path, suite):
    return re.findall(
        rf"{suite} (test[A-Za-z0-9_]+)\]' passed",
        pathlib.Path(path).read_text(),
    )

move = observed(sys.argv[1], "NativeTransactionalMoveTests")
replace = observed(sys.argv[2], "NativeTransactionalReplaceTests")
recovery = observed(sys.argv[3], "RecoverySafetyTests")
expected_move = {
    "testSameVolumeMoveUsesOneDurableRenameEffect",
    "testSourceReplacementAfterPreflightCannotReachTransactionalPlan",
    "testSourceReplacementAfterVerificationCannotBeAdoptedByEffectIntent",
    "testDestinationParentReplacementAfterVerificationCannotBeAdopted",
    "testCrossVolumeMovePersistsCommitQuarantineAndLeafToRootPurge",
    "testCrossVolumeBarrierCancelRetainsSourceWithoutQuarantineIntent",
    "testCrossVolumeRetainFailsClosedWhenSourceParentWasReplaced",
    "testExternalMoveToQuarantineBeforeFirstIntentIsNeverAdopted",
    "testCrossVolumeCleanupIdentityRacesStopConservatively",
}
expected_replace = {
    "testDestinationReplacementAfterPreflightCannotReachTransactionalPlan",
    "testDestinationReplacementAfterVerificationCannotBeAdoptedByBackupIntent",
    "testStagingReplacementAfterVerificationCannotBeAdoptedByCommitIntent",
    "testReplaceFinalizeIsEpochFencedAndPurgesBackupExactlyOnce",
    "testRestoreBackupMovesNewObjectAsideAndRestoresOldDestination",
    "testFinalizeRejectsSameInodeContentMutationWithoutRevokingRestore",
    "testFinalizePurgesNonemptyDirectoryBackupLeafToRoot",
    "testCrossVolumeMoveReplaceFinalizesOnlyAfterSourceCleanup",
}
expected_recovery = {
    "testQueuedPlannedOperationCanBeCancelledWithoutReleasingActiveSlot",
    "testQueuedAdmissionIsReplayDiscoverableBeforeExecutionStarts",
    "testPreflightCancellationKeepsActiveSlotUntilAdapterQuiesces",
    "testInitialCleanupInspectionHandlesAllOutcomesWithoutGuessing",
    "testCleanupRetryReinspectsIdentityAndKeepsChangedOrUnknownTokenLiveAcrossRestart",
    "testCleanupRetryAndRetainConvergeFromConfirmedSourceStateAndAreRestartIdempotent",
    "testRestartFailsClosedForUnexplainedCommitAndCleanupEffects",
    "testPhaseAuthorizationIsRecheckedAfterActorReentrancyWindow",
    "testMoveVerificationUsesKnownTopologyAndFailsClosedWhenUnknown",
    "testResumeFromVerifiedStageExecutesAndIsDurablyIdempotentAcrossRestart",
    "testMultiItemRollbackResumesFromDurablePerItemLedgerAfterRestart",
    "testNotCommittedInspectionDurablyCleansStagingBeforeRollbackCancellation",
    "testFinalizeCommittedItemsExecutesOnceAndClearsTerminalFailure",
    "testCleanupRecoveryTreatsConfirmedAbsentSourceAsCompletedWithoutDelete",
    "testAmbiguousRecoveryEffectIsInspectedAndNeverReplayed",
    "testRecoveryResultCheckpointFailureInspectsWithoutSecondEffect",
    "testTwoItemRecoveryPersistsEachIntentAndInspectsOnlyAmbiguousSecondItem",
    "testIntentBeforeEffectCrashReusesStableEffectIDAfterNotPerformedInspection",
    "testFinalRecoveryCommandCheckpointCanBeCompletedAfterRestartWithoutEffectReplay",
    "testRecoveryCleanupReceiptFailureRestartsWithoutSecondCleanup",
    "testUnknownRecoveryInspectionPreservesIntentAndTokenWithoutNewMutation",
    "testConcurrentSameRecoveryActionHasOneLeaseAndOneEffect",
    "testDurableRecoveryChoiceRejectsSiblingInProcessAndAfterRestart",
    "testFatalStartupDominatesRecoverableStateInBothLoadOrders",
    "testRecoveryModeGuardsAllControlsAndRejectsSiblingAdmission",
    "testFatalModeControlsProduceNoJournalMutationOrFilesystemEffect",
    "testProgressJournalFailureRevokesPhaseBeforeAnyFilesystemEffect",
    "testRestartTreatsInterruptedPrecommitAsRecoveryRequiredWithoutAction",
    "testDiscardProjectionRepairsAfterItemTerminalCheckpointFailure",
    "testRollbackProjectionRepairsAfterItemsTerminalCheckpointFailure",
    "testFinalizeProjectionRepairsAfterItemsTerminalCheckpointFailure",
    "testCleanupProjectionRepairsAfterItemTerminalCheckpointFailure",
    "testRetainProjectionRepairsAfterItemTerminalCheckpointFailure",
    "testInitialStagingCancelIntentBeforeEffectRestartsWithSameEffectIDOnce",
    "testInitialStagingCancelAmbiguousSurvivesRestartAndConvergesByInspection",
    "testInitialStagingCancelResultJournalFailureRestartsWithoutSecondEffect",
}
if set(move) != expected_move or len(move) != len(expected_move):
    raise SystemExit(f"move test inventory mismatch: {move}")
if set(replace) != expected_replace or len(replace) != len(expected_replace):
    raise SystemExit(f"replace test inventory mismatch: {replace}")
if set(recovery) != expected_recovery or len(recovery) != len(expected_recovery):
    raise SystemExit(f"recovery test inventory mismatch: {recovery}")
action_bindings = {
    "resumeFromVerifiedStage":
        "testResumeFromVerifiedStageExecutesAndIsDurablyIdempotentAcrossRestart",
    "retrySourceCleanup":
        "testCleanupRetryReinspectsIdentityAndKeepsChangedOrUnknownTokenLiveAcrossRestart",
    "retainSource":
        "testCleanupRetryAndRetainConvergeFromConfirmedSourceStateAndAreRestartIdempotent",
    "rollbackCommittedDestination":
        "testMultiItemRollbackResumesFromDurablePerItemLedgerAfterRestart",
    "restoreBackup":
        "testRestoreBackupMovesNewObjectAsideAndRestoresOldDestination",
    "finalizeKnownCommit":
        "testFinalizeCommittedItemsExecutesOnceAndClearsTerminalFailure",
    "discardKnownStaging":
        "testNotCommittedInspectionDurablyCleansStagingBeforeRollbackCancellation",
}
for action, test in action_bindings.items():
    inventory = replace if action == "restoreBackup" else recovery
    if test not in inventory:
        raise SystemExit(f"{action} binding is missing exact test {test}")
bindings = {
    "M3-MOVE-POLICY-001": [
        "testSourceReplacementAfterPreflightCannotReachTransactionalPlan",
        "testDestinationReplacementAfterPreflightCannotReachTransactionalPlan",
        "testSourceReplacementAfterVerificationCannotBeAdoptedByEffectIntent",
        "testDestinationReplacementAfterVerificationCannotBeAdoptedByBackupIntent",
        "testStagingReplacementAfterVerificationCannotBeAdoptedByCommitIntent",
        "testDestinationParentReplacementAfterVerificationCannotBeAdopted",
        "testExternalMoveToQuarantineBeforeFirstIntentIsNeverAdopted",
        "testCrossVolumeMovePersistsCommitQuarantineAndLeafToRootPurge",
    ],
    "M3-MOVE-ORDER-001": [
        "testCrossVolumeMovePersistsCommitQuarantineAndLeafToRootPurge",
        "testFinalizePurgesNonemptyDirectoryBackupLeafToRoot",
    ],
    "M3-MOVE-BARRIER-001": [
        "testCrossVolumeBarrierCancelRetainsSourceWithoutQuarantineIntent",
        "testCrossVolumeRetainFailsClosedWhenSourceParentWasReplaced",
        "SIGKILL-restart-retain-durable-manifest",
    ],
    "M3-CLEAN-IDENTITY-001": [
        "testCrossVolumeCleanupIdentityRacesStopConservatively",
        "testCrossVolumeRetainFailsClosedWhenSourceParentWasReplaced",
    ],
    "M3-REPLACE-BACKUP-001": [
        "testReplaceFinalizeIsEpochFencedAndPurgesBackupExactlyOnce",
        "testFinalizeRejectsSameInodeContentMutationWithoutRevokingRestore",
        "testFinalizePurgesNonemptyDirectoryBackupLeafToRoot",
    ],
    "M3-RECOVERY-ACTION-001": [
        *[
            f"{action}={test}"
            for action, test in sorted(action_bindings.items())
        ],
        "testConcurrentSameRecoveryActionHasOneLeaseAndOneEffect",
        "testDurableRecoveryChoiceRejectsSiblingInProcessAndAfterRestart",
        f"RecoverySafetyTests-exact-set-{len(recovery)}",
    ],
}
pathlib.Path(sys.argv[4]).write_text(
    "\n".join(
        f"{scenario}\tPASS\t{'+'.join(evidence)}"
        for scenario, evidence in bindings.items()
    ) + "\n"
)
PY
cmp "$OUT/head.txt" <(git -C "$ROOT" rev-parse HEAD)
echo "M3-MOVE-POLICY-001 M3-MOVE-ORDER-001 M3-MOVE-BARRIER-001 M3-CLEAN-IDENTITY-001 M3-REPLACE-BACKUP-001 M3-RECOVERY-ACTION-001 PASS skip=0 evidence=$OUT"
