import Foundation
import XCTest
@testable import RascalFileOperations
import RascalFileOperationsTestSupport

final class NativeTransactionalReplaceTests: XCTestCase {
    func testDestinationReplacementAfterPreflightCannotReachTransactionalPlan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rascal-m3-replace-preflight-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        let destination = root.appendingPathComponent("existing.txt")
        let original = root.appendingPathComponent("existing.original.txt")
        let journalURL = root.appendingPathComponent("operations.sqlite")
        try Data("new-content".utf8).write(to: source)
        try Data("old-content".utf8).write(to: destination)
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .preflightReadyBeforePlan)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL,
            serviceFailpoints: failpoints
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: destination, to: original)
        try Data("replacement-destination".utf8).write(to: destination)
        await gate.release()

        let stopped = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(stopped.state, .failedRecoverable)
        XCTAssertEqual(stopped.terminalFailure?.code, .destinationChanged)
        XCTAssertEqual(try Data(contentsOf: source), Data("new-content".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("replacement-destination".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: original), Data("old-content".utf8))

        service = nil
        let journal = try SQLiteOperationJournal(url: journalURL)
        XCTAssertTrue(try journal.effectRecords(operationID: id).isEmpty)
    }

    func testDestinationReplacementAfterVerificationCannotBeAdoptedByBackupIntent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rascal-m3-replace-post-verification-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        let destination = root.appendingPathComponent("existing.txt")
        let original = root.appendingPathComponent("existing.original.txt")
        let journalURL = root.appendingPathComponent("operations.sqlite")
        let counter = root.appendingPathComponent("syscalls.tsv")
        try Data("new-content".utf8).write(to: source)
        try Data("old-content".utf8).write(to: destination)
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .verificationReadyBeforeEffects)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL,
            serviceFailpoints: failpoints,
            crashScenario: CrashScenarioContext(
                scenarioID: "post-verification-destination-replacement",
                runNonce: UUID(),
                syscallCounterURL: counter
            )
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: destination, to: original)
        try Data("replacement-destination".utf8).write(to: destination)
        await gate.release()

        let stopped = try await waitForTerminal(id, service: XCTUnwrap(service))
        service = nil
        XCTAssertFalse(
            try SQLiteOperationJournal(url: journalURL)
                .effectRecords(operationID: id)
                .contains {
                    [.backupDestination, .commitReplacement].contains($0.intent.kind)
                }
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("new-content".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("replacement-destination".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: original), Data("old-content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: counter.path))
        XCTAssertTrue([
            OperationState.failedRecoverable,
            .cleanupRequired,
            .recoveryRequired,
            .cancelled,
        ].contains(stopped.state))
    }

    func testStagingReplacementAfterVerificationCannotBeAdoptedByCommitIntent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rascal-m3-stage-post-verification-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        let destination = root.appendingPathComponent("existing.txt")
        let journalURL = root.appendingPathComponent("operations.sqlite")
        let counter = root.appendingPathComponent("syscalls.tsv")
        try Data("new-content".utf8).write(to: source)
        try Data("old-content".utf8).write(to: destination)
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .verificationReadyBeforeEffects)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL,
            serviceFailpoints: failpoints,
            crashScenario: CrashScenarioContext(
                scenarioID: "post-verification-staging-replacement",
                runNonce: UUID(),
                syscallCounterURL: counter
            )
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        let stage = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: root.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        let stageURL = root.appendingPathComponent(stage)
        let originalStage = root.appendingPathComponent(stage + ".original")
        try FileManager.default.moveItem(at: stageURL, to: originalStage)
        try Data("untrusted-stage".utf8).write(to: stageURL)
        await gate.release()

        let stopped = try await waitForTerminal(id, service: XCTUnwrap(service))
        service = nil
        XCTAssertFalse(
            try SQLiteOperationJournal(url: journalURL)
                .effectRecords(operationID: id)
                .contains {
                    [.backupDestination, .commitReplacement].contains($0.intent.kind)
                }
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("new-content".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old-content".utf8))
        XCTAssertEqual(try Data(contentsOf: stageURL), Data("untrusted-stage".utf8))
        XCTAssertEqual(try Data(contentsOf: originalStage), Data("new-content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: counter.path))
        XCTAssertTrue([
            OperationState.failedRecoverable,
            .cleanupRequired,
            .recoveryRequired,
            .cancelled,
        ].contains(stopped.state))
    }

    func testReplaceFinalizeIsEpochFencedAndPurgesBackupExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rascal-m3-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        let destination = root.appendingPathComponent("existing.txt")
        let journalURL = root.appendingPathComponent("operations.sqlite")
        try Data("new-content".utf8).write(to: source)
        try Data("old-content".utf8).write(to: destination)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))

        let pending = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(pending.state, .recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: source), Data("new-content".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new-content".utf8))
        let backup = try XCTUnwrap(pending.items.first?.receipt?.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup), Data("old-content".utf8))
        let staleFinalize = try finalizeAction(in: pending, stage: "before restart")

        service = nil
        service = try FileOperationService.makeTransactional(journalURL: journalURL)
        let reissued = try await XCTUnwrap(service).snapshot(id)
        let restartMode = try await XCTUnwrap(service).diagnosticServiceMode()
        let currentFinalize = try finalizeAction(
            in: reissued,
            stage: "after restart; serviceMode=\(restartMode)"
        )
        XCTAssertNotEqual(staleFinalize.command.actionID, currentFinalize.command.actionID)
        do {
            try await XCTUnwrap(service).recover(id, action: staleFinalize)
            XCTFail("stale owner action unexpectedly executed")
        } catch let failure as FileOperationFailure {
            XCTAssertEqual(failure.code, .controlRejected)
        }
        XCTAssertEqual(try Data(contentsOf: backup), Data("old-content".utf8))

        try await XCTUnwrap(service).recover(id, action: currentFinalize)
        try await XCTUnwrap(service).recover(id, action: currentFinalize)
        let terminal = try await XCTUnwrap(service).snapshot(id)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        service = nil
        let journal = try SQLiteOperationJournal(url: journalURL)
        let effects = try journal.effectRecords(operationID: id)
        XCTAssertEqual(
            effects.map(\.intent.kind),
            [.backupDestination, .commitReplacement, .purgeBackup]
        )
        XCTAssertTrue(effects.allSatisfy { $0.result?.status == .completed })
        XCTAssertEqual(
            try journal.applyRetention(
                now: Date().addingTimeInterval(31 * 86_400)
            ).deletedOperationIDs,
            [id],
            "completed finalize+purgeBackup releases the immutable backup receipt"
        )
    }

    func testRestoreBackupMovesNewObjectAsideAndRestoresOldDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rascal-m3-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        let destination = root.appendingPathComponent("existing.txt")
        let journalURL = root.appendingPathComponent("operations.sqlite")
        try Data("new-content".utf8).write(to: source)
        try Data("old-content".utf8).write(to: destination)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))
        let pending = try await waitForTerminal(id, service: XCTUnwrap(service))
        let restore = try restoreAction(in: pending)
        let backup = try XCTUnwrap(pending.items.first?.receipt?.backupURL)

        try await XCTUnwrap(service).recover(id, action: restore)
        try await XCTUnwrap(service).recover(id, action: restore)
        let terminal = try await XCTUnwrap(service).snapshot(id)
        XCTAssertEqual(terminal.state, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old-content".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new-content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        service = nil
        let journal = try SQLiteOperationJournal(url: journalURL)
        XCTAssertEqual(
            try journal.effectRecords(operationID: id).map(\.intent.kind),
            [
                .backupDestination,
                .commitReplacement,
                .rollbackCommittedDestination,
                .restoreBackup,
            ]
        )
    }

    func testFinalizeRejectsSameInodeContentMutationWithoutRevokingRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rascal-m3-finalize-mutation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        let destination = root.appendingPathComponent("existing.txt")
        let journalURL = root.appendingPathComponent("operations.sqlite")
        try Data("new-content".utf8).write(to: source)
        try Data("old-content".utf8).write(to: destination)
        let service = try FileOperationService.makeTransactional(journalURL: journalURL)
        let id = try await service.submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))
        let pending = try await waitForTerminal(id, service: service)
        let finalize = try finalizeAction(in: pending, stage: "before content mutation")
        let backup = try XCTUnwrap(pending.items.first?.receipt?.backupURL)
        let handle = try FileHandle(forWritingTo: destination)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("mutated-same-inode".utf8))
        try handle.synchronize()
        try handle.close()

        do {
            try await service.recover(id, action: finalize)
            XCTFail("finalize accepted a same-inode content mutation")
        } catch let failure as FileOperationFailure {
            XCTAssertEqual(failure.code, .sourceChanged)
        }
        let stillRecoverable = try await service.snapshot(id)
        XCTAssertEqual(stillRecoverable.state, .recoveryRequired)
        XCTAssertTrue(stillRecoverable.availableActions.contains {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        })
        let restore = try restoreAction(in: stillRecoverable)
        XCTAssertEqual(try Data(contentsOf: backup), Data("old-content".utf8))

        try await service.recover(id, action: restore)
        let terminal = try await service.snapshot(id)
        XCTAssertEqual(terminal.state, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old-content".utf8))
    }

    func testFinalizePurgesNonemptyDirectoryBackupLeafToRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rascal-m3-directory-replace-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new", isDirectory: true)
        let destination = root.appendingPathComponent("existing", isDirectory: true)
        let journalURL = root.appendingPathComponent("operations.sqlite")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("new-content".utf8).write(
            to: source.appendingPathComponent("nested/new.txt")
        )
        try Data("old-content".utf8).write(
            to: destination.appendingPathComponent("nested/old.txt")
        )
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .replace,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .replace,
            verificationPolicy: .sha256
        ))
        let pending = try await waitForTerminal(id, service: XCTUnwrap(service))
        let backup = try XCTUnwrap(pending.items.first?.receipt?.backupURL)
        XCTAssertEqual(
            try Data(contentsOf: backup.appendingPathComponent("nested/old.txt")),
            Data("old-content".utf8)
        )
        try await XCTUnwrap(service).recover(
            id,
            action: finalizeAction(in: pending, stage: "directory backup")
        )
        let terminal = try await XCTUnwrap(service).snapshot(id)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("nested/new.txt")),
            Data("new-content".utf8)
        )

        service = nil
        let records = try SQLiteOperationJournal(url: journalURL)
            .effectRecords(operationID: id)
        let purges = records.filter { $0.intent.kind == .purgeBackup }
        XCTAssertEqual(purges.count, 3)
        XCTAssertEqual(
            purges.map(\.intent.relativePath),
            ["nested/old.txt", "nested", "."]
        )
        XCTAssertTrue(purges.allSatisfy { $0.result?.status == .completed })
    }

    func testCrossVolumeMoveReplaceFinalizesOnlyAfterSourceCleanup() async throws {
        guard let sourceRoot = ProcessInfo.processInfo.environment["RASCAL_M3_VOLUME_A"],
              let destinationRoot =
                ProcessInfo.processInfo.environment["RASCAL_M3_VOLUME_B"] else {
            throw XCTSkip("M3 cross-volume gate supplies two mounted APFS roots")
        }
        let run = UUID().uuidString
        let sourceDirectory = URL(fileURLWithPath: sourceRoot, isDirectory: true)
            .appendingPathComponent("m3-move-replace-source-\(run)", isDirectory: true)
        let destinationDirectory = URL(
            fileURLWithPath: destinationRoot,
            isDirectory: true
        ).appendingPathComponent(
            "m3-move-replace-destination-\(run)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let source = sourceDirectory.appendingPathComponent("new.txt")
        let destination = destinationDirectory.appendingPathComponent("existing.txt")
        let journalURL = destinationDirectory.appendingPathComponent("operations.sqlite")
        try Data("new-move-content".utf8).write(to: source)
        try Data("old-move-content".utf8).write(to: destination)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .ask,
            verificationPolicy: .structural
        ))
        let decision = try await waitForDecision(id, service: XCTUnwrap(service))
        try await XCTUnwrap(service).resolve(
            XCTUnwrap(decision.pendingDecision?.token),
            with: .replace(scope: .item)
        )

        let pending = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(pending.state, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("new-move-content".utf8)
        )
        let backup = try XCTUnwrap(pending.items.first?.receipt?.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup), Data("old-move-content".utf8))
        let finalize = try finalizeAction(in: pending, stage: "move replace")

        try await XCTUnwrap(service).recover(id, action: finalize)
        try await XCTUnwrap(service).recover(id, action: finalize)
        let terminal = try await XCTUnwrap(service).snapshot(id)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        service = nil
        let journal = try SQLiteOperationJournal(url: journalURL)
        let effects = try journal.effectRecords(operationID: id)
        XCTAssertEqual(
            effects.map(\.intent.kind),
            [
                .backupDestination,
                .commitReplacement,
                .quarantineSource,
                .purgeQuarantineRoot,
                .purgeBackup,
            ]
        )
        XCTAssertTrue(effects.allSatisfy { $0.result?.status == .completed })
    }

    private func finalizeAction(
        in snapshot: OperationSnapshot,
        stage: String
    ) throws -> RecoveryAction {
        try XCTUnwrap(snapshot.availableActions.first {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        }, """
        missing finalize action \(stage); state=\(snapshot.state); \
        receipts=\(snapshot.items.map(\.receipt)); actions=\(snapshot.availableActions)
        """)
    }

    private func restoreAction(in snapshot: OperationSnapshot) throws -> RecoveryAction {
        try XCTUnwrap(snapshot.availableActions.first {
            if case .restoreBackup = $0 { return true }
            return false
        })
    }

    private func waitForTerminal(
        _ id: OperationID,
        service: FileOperationService
    ) async throws -> OperationSnapshot {
        for _ in 0..<750 {
            let snapshot = try await service.snapshot(id)
            if [
                OperationState.completed,
                .failedRecoverable,
                .recoveryRequired,
                .cleanupRequired,
            ].contains(snapshot.state) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(
            "transactional replace did not reach a terminal state; " +
                "serviceMode=\(await service.diagnosticServiceMode())"
        )
        return try await service.snapshot(id)
    }

    private func waitForDecision(
        _ id: OperationID,
        service: FileOperationService
    ) async throws -> OperationSnapshot {
        for _ in 0..<750 {
            let snapshot = try await service.snapshot(id)
            if snapshot.state == .waitingForDecision,
               snapshot.pendingDecision != nil {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("transactional move replace did not request an explicit decision")
        return try await service.snapshot(id)
    }
}
