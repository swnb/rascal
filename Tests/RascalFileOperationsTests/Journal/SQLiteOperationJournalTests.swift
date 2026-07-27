import Foundation
import SQLite3
import XCTest
@testable import RascalFileOperations

final class SQLiteOperationJournalTests: XCTestCase {
    func testOpenConfiguresSchemaOwnerEpochAndRejectsSecondWriter() throws {
        let fixture = try JournalFixture()
        var first: SQLiteOperationJournal? = try SQLiteOperationJournal(url: fixture.url)
        let firstEpoch = try XCTUnwrap(first?.ownerEpoch)
        XCTAssertFalse(firstEpoch.uuidString.isEmpty)
        XCTAssertNotNil(first?.sqliteRuntimeVersion)

        XCTAssertThrowsError(try SQLiteOperationJournal(url: fixture.url)) { error in
            XCTAssertEqual(error as? JournalOwnerLeaseError, .alreadyOwned)
        }

        first = nil
        let successor = try SQLiteOperationJournal(url: fixture.url)
        XCTAssertNotEqual(successor.ownerEpoch, firstEpoch)
    }

    func testAdmissionReplayAndSequenceReservationSurviveRestart() throws {
        let fixture = try JournalFixture()
        var journal: SQLiteOperationJournal? = try SQLiteOperationJournal(url: fixture.url)
        let snapshot = makeSnapshot()
        let admission = try XCTUnwrap(journal).admit(snapshot, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(admission.operation.latestDurableSequence, 1)
        XCTAssertEqual(try journal?.reserveSequences(for: snapshot.id, count: 4), 2...5)
        journal = nil

        let reopened = try SQLiteOperationJournal(url: fixture.url)
        let loaded = try XCTUnwrap(reopened.loadOperations().first)
        XCTAssertEqual(loaded.snapshot.id, snapshot.id)
        XCTAssertEqual(loaded.latestDurableSequence, 1)
        XCTAssertEqual(loaded.reservedThrough, 5)
        let replay = try reopened.replay(
            operationID: snapshot.id,
            after: 0,
            through: 5,
            limit: 10
        )
        XCTAssertEqual(replay.map(\.sequence), [1])
        XCTAssertEqual(try reopened.reserveSequences(for: snapshot.id, count: 1), 6...6)
    }

    func testEffectIntentAndResultAreImmutableAndReadBack() throws {
        let fixture = try JournalFixture()
        let journal = try SQLiteOperationJournal(url: fixture.url)
        let admission = try journal.admit(makeSnapshot(), at: Date())
        var operation = admission.operation
        let reservation = try journal.reserveSequences(
            for: operation.snapshot.id,
            count: 2
        )
        operation.reservedThrough = reservation.upperBound
        let itemID = try XCTUnwrap(operation.snapshot.items.first?.id)
        let epoch = try XCTUnwrap(journal.ownerEpoch)
        let intent = DurableEffectIntent(
            effectID: UUID(),
            operationID: operation.snapshot.id,
            itemID: itemID,
            ownerEpoch: epoch,
            effectOrdinal: 1,
            kind: .stageCommit,
            expectedIdentity: Data("expected".utf8),
            intentSequence: reservation.lowerBound
        )
        try journal.appendEffectIntent(intent, checkpoint: operation)
        try journal.appendEffectIntent(intent, checkpoint: operation)

        let result = DurableEffectResultRecord(
            operationID: intent.operationID,
            itemID: itemID,
            effectID: intent.effectID,
            status: .completed,
            resultIdentity: Data("result".utf8),
            systemCode: nil,
            evidence: Data("evidence".utf8),
            resultSequence: reservation.upperBound
        )
        try journal.appendEffectResult(
            result,
            checkpoint: operation,
            summaryReceipt: nil
        )
        try journal.appendEffectResult(
            result,
            checkpoint: operation,
            summaryReceipt: nil
        )
        XCTAssertEqual(
            try journal.effectRecords(operationID: intent.operationID),
            [DurableEffectRecord(intent: intent, result: result)]
        )

        let changed = DurableEffectResultRecord(
            operationID: intent.operationID,
            itemID: itemID,
            effectID: intent.effectID,
            status: .ambiguous,
            resultIdentity: nil,
            systemCode: nil,
            evidence: Data(),
            resultSequence: reservation.upperBound
        )
        XCTAssertThrowsError(
            try journal.appendEffectResult(
                changed,
                checkpoint: operation,
                summaryReceipt: nil
            )
        )
    }

    func testManifestIsImmutableAndOrderedForLeafToRootPurge() throws {
        let fixture = try JournalFixture()
        let journal = try SQLiteOperationJournal(url: fixture.url)
        let admission = try journal.admit(makeSnapshot(), at: Date())
        let itemID = try XCTUnwrap(admission.operation.snapshot.items.first?.id)
        let nodes = [
            DurableManifestNode(
                nodeID: "leaf",
                parentNodeID: "root",
                relativePath: "child",
                depth: 1,
                kind: .regular,
                identity: Data("leaf-identity".utf8),
                digest: "leaf-digest",
                purgeOrdinal: 1
            ),
            DurableManifestNode(
                nodeID: "root",
                parentNodeID: nil,
                relativePath: ".",
                depth: 0,
                kind: .directory,
                identity: Data("root-identity".utf8),
                digest: "tree-digest",
                purgeOrdinal: 2
            ),
        ]
        try journal.replaceManifest(
            operationID: admission.operation.snapshot.id,
            itemID: itemID,
            nodes: nodes
        )
        XCTAssertEqual(
            try journal.manifest(
                operationID: admission.operation.snapshot.id,
                itemID: itemID
            ),
            nodes
        )
        try journal.replaceManifest(
            operationID: admission.operation.snapshot.id,
            itemID: itemID,
            nodes: nodes
        )
        var changed = nodes
        changed[0] = DurableManifestNode(
            nodeID: "leaf",
            parentNodeID: "root",
            relativePath: "other",
            depth: 1,
            kind: .regular,
            identity: Data("leaf-identity".utf8),
            digest: "leaf-digest",
            purgeOrdinal: 1
        )
        XCTAssertThrowsError(
            try journal.replaceManifest(
                operationID: admission.operation.snapshot.id,
                itemID: itemID,
                nodes: changed
            )
        )
    }

    func testRecoveryActionOfferIsFencedByOwnerEpoch() throws {
        let fixture = try JournalFixture()
        let action = RecoveryAction.retrySourceCleanup(
            RecoveryCommand(actionID: UUID(), expectedSequence: 1)
        )
        let snapshot = replacingActions(makeSnapshot(), with: [action])
        var first: SQLiteOperationJournal? = try SQLiteOperationJournal(url: fixture.url)
        let operationID = try XCTUnwrap(first).admit(snapshot, at: Date()).operation.snapshot.id
        XCTAssertTrue(
            try XCTUnwrap(first).recoveryActionIsAuthorized(
                operationID: operationID,
                action: action
            )
        )
        first = nil

        let successor = try SQLiteOperationJournal(url: fixture.url)
        XCTAssertFalse(
            try successor.recoveryActionIsAuthorized(
                operationID: operationID,
                action: action
            )
        )
    }

    func testSequenceReservationPreservesOldOwnerActionUntilAtomicReissue() throws {
        let fixture = try JournalFixture()
        let stale = RecoveryAction.finalizeKnownCommit(
            RecoveryCommand(actionID: UUID(), expectedSequence: 1)
        )
        let snapshot = replacingActions(makeSnapshot(), with: [stale])
        var first: SQLiteOperationJournal? = try SQLiteOperationJournal(url: fixture.url)
        let operationID = try XCTUnwrap(first).admit(
            snapshot,
            at: Date()
        ).operation.snapshot.id
        first = nil

        let successor = try SQLiteOperationJournal(url: fixture.url)
        XCTAssertFalse(
            try successor.recoveryActionIsAuthorized(
                operationID: operationID,
                action: stale
            )
        )
        var operation = try XCTUnwrap(successor.loadOperations().first)
        let reservation = try successor.reserveSequences(
            for: operationID,
            count: 1
        )
        XCTAssertEqual(reservation, 2...2)

        let current = RecoveryAction.finalizeKnownCommit(
            RecoveryCommand(actionID: UUID(), expectedSequence: 2)
        )
        operation.snapshot = replacingActions(
            operation.snapshot,
            with: [current],
            latestSequence: 2
        )
        operation.latestDurableSequence = 2
        operation.latestEmittedSequence = 2
        operation.reservedThrough = 2
        try successor.commit(
            operation,
            event: OperationEvent(
                operationID: operationID,
                itemID: operation.snapshot.items.first?.id,
                sequence: 2,
                timestamp: Date(),
                durability: .durable,
                payload: .recoveryAvailable([current])
            )
        )

        XCTAssertFalse(
            try successor.recoveryActionIsAuthorized(
                operationID: operationID,
                action: stale
            )
        )
        XCTAssertTrue(
            try successor.recoveryActionIsAuthorized(
                operationID: operationID,
                action: current
            )
        )
    }

    func testRecoverySelectionRevokesSiblingAndRepeatedCheckpointIsStable() throws {
        let fixture = try JournalFixture()
        let first = RecoveryAction.finalizeKnownCommit(
            RecoveryCommand(actionID: UUID(), expectedSequence: 1)
        )
        let sibling = RecoveryAction.restoreBackup(
            RecoveryCommand(actionID: UUID(), expectedSequence: 1)
        )
        let journal = try SQLiteOperationJournal(url: fixture.url)
        var operation = try journal.admit(
            replacingActions(makeSnapshot(), with: [first, sibling]),
            at: Date()
        ).operation
        operation.snapshot = replacingActions(operation.snapshot, with: [first])
        operation.inProgressRecoveryActions = [first.command.actionID]
        try journal.checkpoint(operation)
        try journal.checkpoint(operation)

        XCTAssertTrue(
            try journal.recoveryActionIsAuthorized(
                operationID: operation.snapshot.id,
                action: first
            )
        )
        XCTAssertFalse(
            try journal.recoveryActionIsAuthorized(
                operationID: operation.snapshot.id,
                action: sibling
            )
        )
    }

    func testReceiptAllowsOnlyPendingToCompleteMonotonicProjection() throws {
        let fixture = try JournalFixture()
        let journal = try SQLiteOperationJournal(url: fixture.url)
        var operation = try journal.admit(makeSnapshot(), at: Date()).operation
        let reservation = try journal.reserveSequences(
            for: operation.snapshot.id,
            count: 4
        )
        operation.reservedThrough = reservation.upperBound
        let itemID = try XCTUnwrap(operation.snapshot.items.first?.id)
        let epoch = try XCTUnwrap(journal.ownerEpoch)
        let quarantine = URL(fileURLWithPath: "/tmp/quarantine-\(UUID().uuidString)")
        let pending = OperationReceiptSummary(
            committedIdentityDigest: "commit-identity",
            backupURL: nil,
            quarantineURL: quarantine,
            sourceCleanupPending: true
        )
        let pendingOperation = replacingReceipt(
            operation,
            itemID: itemID,
            receipt: pending
        )
        let commitIntent = DurableEffectIntent(
            effectID: UUID(),
            operationID: operation.snapshot.id,
            itemID: itemID,
            ownerEpoch: epoch,
            effectOrdinal: 1,
            kind: .stageCommit,
            expectedIdentity: Data("commit".utf8),
            intentSequence: reservation.lowerBound
        )
        try journal.appendEffectIntent(commitIntent, checkpoint: operation)
        try journal.appendEffectResult(
            DurableEffectResultRecord(
                operationID: operation.snapshot.id,
                itemID: itemID,
                effectID: commitIntent.effectID,
                status: .completed,
                resultIdentity: Data("commit-result".utf8),
                systemCode: nil,
                evidence: Data(),
                resultSequence: reservation.lowerBound + 1
            ),
            checkpoint: pendingOperation,
            summaryReceipt: pending
        )

        let cleanupIntent = DurableEffectIntent(
            effectID: UUID(),
            operationID: operation.snapshot.id,
            itemID: itemID,
            ownerEpoch: epoch,
            effectOrdinal: 2,
            kind: .purgeQuarantineRoot,
            expectedIdentity: Data("cleanup".utf8),
            intentSequence: reservation.lowerBound + 2
        )
        try journal.appendEffectIntent(cleanupIntent, checkpoint: pendingOperation)
        let cleanupResult = DurableEffectResultRecord(
            operationID: operation.snapshot.id,
            itemID: itemID,
            effectID: cleanupIntent.effectID,
            status: .completed,
            resultIdentity: Data("absent".utf8),
            systemCode: nil,
            evidence: Data(),
            resultSequence: reservation.upperBound
        )
        let completed = OperationReceiptSummary(
            committedIdentityDigest: pending.committedIdentityDigest,
            backupURL: nil,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
        let completedOperation = replacingReceipt(
            pendingOperation,
            itemID: itemID,
            receipt: completed
        )
        try journal.appendEffectResult(
            cleanupResult,
            checkpoint: completedOperation,
            summaryReceipt: completed
        )
        XCTAssertThrowsError(
            try journal.appendEffectResult(
                cleanupResult,
                checkpoint: replacingReceipt(
                    completedOperation,
                    itemID: itemID,
                    receipt: OperationReceiptSummary(
                        committedIdentityDigest: "changed",
                        backupURL: nil,
                        quarantineURL: nil,
                        sourceCleanupPending: false
                    )
                ),
                summaryReceipt: OperationReceiptSummary(
                    committedIdentityDigest: "changed",
                    backupURL: nil,
                    quarantineURL: nil,
                    sourceCleanupPending: false
                )
            )
        )
    }

    func testReceiptEventAllowsOnlyRetainedSourceConvergence() throws {
        let fixture = try JournalFixture()
        let journal = try SQLiteOperationJournal(url: fixture.url)
        var operation = try journal.admit(makeSnapshot(), at: Date()).operation
        let reservation = try journal.reserveSequences(
            for: operation.snapshot.id,
            count: 3
        )
        operation.reservedThrough = reservation.upperBound
        let itemID = try XCTUnwrap(operation.snapshot.items.first?.id)
        let epoch = try XCTUnwrap(journal.ownerEpoch)
        let pending = OperationReceiptSummary(
            committedIdentityDigest: "retained-source-commit",
            backupURL: nil,
            quarantineURL: URL(fileURLWithPath: "/tmp/never-created-quarantine"),
            sourceCleanupPending: true
        )
        let pendingOperation = replacingReceipt(
            operation,
            itemID: itemID,
            receipt: pending
        )
        let intent = DurableEffectIntent(
            effectID: UUID(),
            operationID: operation.snapshot.id,
            itemID: itemID,
            ownerEpoch: epoch,
            effectOrdinal: 1,
            kind: .stageCommit,
            expectedIdentity: Data("commit".utf8),
            intentSequence: reservation.lowerBound
        )
        try journal.appendEffectIntent(intent, checkpoint: operation)
        try journal.appendEffectResult(
            DurableEffectResultRecord(
                operationID: operation.snapshot.id,
                itemID: itemID,
                effectID: intent.effectID,
                status: .completed,
                resultIdentity: Data("commit-result".utf8),
                systemCode: nil,
                evidence: Data(),
                resultSequence: reservation.lowerBound + 1
            ),
            checkpoint: pendingOperation,
            summaryReceipt: pending
        )

        let retained = OperationReceiptSummary(
            committedIdentityDigest: pending.committedIdentityDigest,
            backupURL: pending.backupURL,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
        var retainedOperation = replacingReceipt(
            pendingOperation,
            itemID: itemID,
            receipt: retained
        )
        retainedOperation.latestDurableSequence = reservation.upperBound
        retainedOperation.latestEmittedSequence = reservation.upperBound
        let event = OperationEvent(
            operationID: operation.snapshot.id,
            itemID: itemID,
            sequence: reservation.upperBound,
            timestamp: Date(),
            durability: .durable,
            payload: .receiptRecorded(retained)
        )
        XCTAssertNoThrow(try journal.commit(retainedOperation, event: event))
        XCTAssertEqual(
            try journal.loadOperations().first?.snapshot.items.first?.receipt,
            retained
        )

        let changed = OperationReceiptSummary(
            committedIdentityDigest: "changed",
            backupURL: nil,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
        XCTAssertThrowsError(
            try journal.checkpoint(
                replacingReceipt(retainedOperation, itemID: itemID, receipt: changed)
            )
        )
    }

    func testReceiptAcceptsExactRetryAfterDurableNotPerformedAttempt() throws {
        let fixture = try JournalFixture()
        let journal = try SQLiteOperationJournal(url: fixture.url)
        var operation = try journal.admit(makeSnapshot(), at: Date()).operation
        let reservation = try journal.reserveSequences(
            for: operation.snapshot.id,
            count: 4
        )
        operation.reservedThrough = reservation.upperBound
        let itemID = try XCTUnwrap(operation.snapshot.items.first?.id)
        let epoch = try XCTUnwrap(journal.ownerEpoch)
        let frozenIdentity = Data("same-frozen-preparation".utf8)
        let first = DurableEffectIntent(
            effectID: UUID(),
            operationID: operation.snapshot.id,
            itemID: itemID,
            ownerEpoch: epoch,
            effectOrdinal: 1,
            kind: .stageCommit,
            expectedIdentity: frozenIdentity,
            manifestDigest: "manifest",
            intentSequence: reservation.lowerBound
        )
        try journal.appendEffectIntent(first, checkpoint: operation)
        try journal.appendEffectResult(
            DurableEffectResultRecord(
                operationID: first.operationID,
                itemID: itemID,
                effectID: first.effectID,
                status: .notPerformed,
                resultIdentity: nil,
                systemCode: nil,
                evidence: Data("restart-inspection".utf8),
                resultSequence: reservation.lowerBound + 1
            ),
            checkpoint: operation,
            summaryReceipt: nil
        )

        let retry = DurableEffectIntent(
            effectID: UUID(),
            operationID: operation.snapshot.id,
            itemID: itemID,
            ownerEpoch: epoch,
            effectOrdinal: 2,
            kind: .stageCommit,
            expectedIdentity: frozenIdentity,
            manifestDigest: "manifest",
            intentSequence: reservation.lowerBound + 2
        )
        try journal.appendEffectIntent(retry, checkpoint: operation)
        let receipt = OperationReceiptSummary(
            committedIdentityDigest: "commit",
            backupURL: nil,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
        operation = replacingReceipt(operation, itemID: itemID, receipt: receipt)
        XCTAssertNoThrow(
            try journal.appendEffectResult(
                DurableEffectResultRecord(
                    operationID: retry.operationID,
                    itemID: itemID,
                    effectID: retry.effectID,
                    status: .completed,
                    resultIdentity: Data("result".utf8),
                    systemCode: nil,
                    evidence: Data("rename".utf8),
                    resultSequence: reservation.upperBound
                ),
                checkpoint: operation,
                summaryReceipt: receipt
            )
        )
    }

    func testRetentionUsesExactAgeAndCountBoundaries() throws {
        let fixture = try JournalFixture()
        let now = Date()
        var ids: [OperationID] = []
        do {
            let journal = try SQLiteOperationJournal(url: fixture.url)
            for _ in 0..<3 {
                let admission = try journal.admit(makeSnapshot(), at: now)
                try journal.checkpoint(terminal(admission.operation))
                ids.append(admission.operation.snapshot.id)
            }
        }
        try setUpdatedMilliseconds(
            fixture.url,
            [
                ids[0]: milliseconds(now.addingTimeInterval(-29 * 86_400)),
                ids[1]: milliseconds(now.addingTimeInterval(-30 * 86_400)),
                ids[2]: milliseconds(now.addingTimeInterval(-31 * 86_400)),
            ]
        )
        do {
            let journal = try SQLiteOperationJournal(url: fixture.url)
            let result = try journal.applyRetention(now: now)
            XCTAssertEqual(result.deletedOperationIDs, [ids[2]])
            XCTAssertEqual(Set(try journal.loadOperations().map(\.snapshot.id)), Set(ids.prefix(2)))
        }

        let countFixture = try JournalFixture()
        do {
            let journal = try SQLiteOperationJournal(url: countFixture.url)
            for offset in 0..<101 {
                let admission = try journal.admit(
                    makeSnapshot(),
                    at: now.addingTimeInterval(TimeInterval(offset))
                )
                try journal.checkpoint(terminal(admission.operation))
            }
        }
        let countJournal = try SQLiteOperationJournal(url: countFixture.url)
        XCTAssertEqual(try countJournal.applyRetention(now: now).deletedOperationIDs.count, 1)
        XCTAssertEqual(try countJournal.loadOperations().count, 100)
    }

    func testClearPreservesNonterminalAndFutureSchemaFailsClosed() throws {
        let fixture = try JournalFixture()
        let plannedID: OperationID
        let terminalID: OperationID
        do {
            let journal = try SQLiteOperationJournal(url: fixture.url)
            plannedID = try journal.admit(makeSnapshot(), at: Date()).operation.snapshot.id
            let terminalAdmission = try journal.admit(makeSnapshot(), at: Date())
            terminalID = terminalAdmission.operation.snapshot.id
            try journal.checkpoint(terminal(terminalAdmission.operation))
            XCTAssertEqual(
                try journal.clearSafeTerminalOperations(now: Date()).deletedOperationIDs,
                [terminalID]
            )
            XCTAssertEqual(try journal.loadOperations().map(\.snapshot.id), [plannedID])
        }

        let connection = try SQLiteConnection(url: fixture.url)
        try connection.execute("PRAGMA user_version=2")
        XCTAssertThrowsError(try SQLiteOperationJournal(url: fixture.url))
    }

    func testCorruptEnvelopeAndMissingRequiredIndexFailClosed() throws {
        let envelopeFixture = try JournalFixture()
        do {
            let journal = try SQLiteOperationJournal(url: envelopeFixture.url)
            _ = try journal.admit(makeSnapshot(), at: Date())
        }
        do {
            let connection = try SQLiteConnection(url: envelopeFixture.url)
            try connection.execute(
                "UPDATE operations SET snapshot_blob=x'00' WHERE operation_id IS NOT NULL"
            )
        }
        let ownerCountBefore = try scalarCount(
            envelopeFixture.url,
            sql: "SELECT COUNT(*) FROM owner_epochs"
        )
        XCTAssertThrowsError(try SQLiteOperationJournal(url: envelopeFixture.url))
        XCTAssertEqual(
            try scalarCount(envelopeFixture.url, sql: "SELECT COUNT(*) FROM owner_epochs"),
            ownerCountBefore
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeFixture.url.path))

        let indexFixture = try JournalFixture()
        do {
            _ = try SQLiteOperationJournal(url: indexFixture.url)
        }
        do {
            let connection = try SQLiteConnection(url: indexFixture.url)
            try connection.execute("DROP INDEX operation_effects_order")
        }
        XCTAssertThrowsError(try SQLiteOperationJournal(url: indexFixture.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFixture.url.path))

        let triggerFixture = try JournalFixture()
        do {
            _ = try SQLiteOperationJournal(url: triggerFixture.url)
        }
        do {
            let connection = try SQLiteConnection(url: triggerFixture.url)
            try connection.execute(
                """
                CREATE TRIGGER unexpected_operation_trigger
                AFTER INSERT ON operations BEGIN SELECT 1; END
                """
            )
        }
        XCTAssertThrowsError(try SQLiteOperationJournal(url: triggerFixture.url))
    }

    func testCheckpointRejectsSequenceRollbackAndReceiptInjection() throws {
        let fixture = try JournalFixture()
        let journal = try SQLiteOperationJournal(url: fixture.url)
        var operation = try journal.admit(makeSnapshot(), at: Date()).operation
        let reservation = try journal.reserveSequences(for: operation.snapshot.id, count: 1)
        operation.reservedThrough = reservation.upperBound
        try journal.checkpoint(operation)

        var stale = operation
        stale.reservedThrough -= 1
        XCTAssertThrowsError(try journal.checkpoint(stale))

        let itemID = try XCTUnwrap(operation.snapshot.items.first?.id)
        let receipt = OperationReceiptSummary(
            committedIdentityDigest: "not-derived",
            backupURL: nil,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
        XCTAssertThrowsError(
            try journal.checkpoint(replacingReceipt(operation, itemID: itemID, receipt: receipt))
        )
    }

    private func makeSnapshot() -> OperationSnapshot {
        let operationID = OperationID(rawValue: UUID())
        let item = OperationItemSnapshot(
            id: OperationItemID(rawValue: UUID()),
            source: URL(fileURLWithPath: "/tmp/source-\(UUID().uuidString)"),
            destination: URL(fileURLWithPath: "/tmp/destination-\(UUID().uuidString)"),
            state: .pending,
            progress: .zero,
            metadata: nil,
            verification: nil,
            receipt: nil,
            failure: nil
        )
        let request = OperationRequest(
            kind: .copy,
            sources: [item.source],
            destination: item.destination?.deletingLastPathComponent(),
            destinationMode: .container
        )
        return OperationSnapshot(
            schemaVersion: 1,
            id: operationID,
            kind: .copy,
            state: .planned,
            latestSequence: 0,
            request: request,
            effectiveMetadataPolicy: .finderCompatible,
            effectiveVerificationPolicy: .structural,
            progress: .zero,
            items: [item],
            pendingDecision: nil,
            terminalFailure: nil,
            availableActions: [],
            hasPartialCommit: false,
            sourceRetained: false
        )
    }

    private func replacingReceipt(
        _ operation: JournalOperation,
        itemID: OperationItemID,
        receipt: OperationReceiptSummary
    ) -> JournalOperation {
        var operation = operation
        let snapshot = operation.snapshot
        let items = snapshot.items.map { item in
            guard item.id == itemID else { return item }
            return OperationItemSnapshot(
                id: item.id,
                source: item.source,
                destination: item.destination,
                state: item.state,
                progress: item.progress,
                metadata: item.metadata,
                verification: item.verification,
                receipt: receipt,
                failure: item.failure
            )
        }
        operation.snapshot = OperationSnapshot(
            schemaVersion: snapshot.schemaVersion,
            id: snapshot.id,
            kind: snapshot.kind,
            state: snapshot.state,
            latestSequence: snapshot.latestSequence,
            request: snapshot.request,
            effectiveMetadataPolicy: snapshot.effectiveMetadataPolicy,
            effectiveVerificationPolicy: snapshot.effectiveVerificationPolicy,
            progress: snapshot.progress,
            items: items,
            pendingDecision: snapshot.pendingDecision,
            terminalFailure: snapshot.terminalFailure,
            availableActions: snapshot.availableActions,
            hasPartialCommit: snapshot.hasPartialCommit,
            sourceRetained: snapshot.sourceRetained
        )
        operation.committedEffects[itemID] = receipt
        return operation
    }

    private func terminal(_ operation: JournalOperation) -> JournalOperation {
        var result = operation
        let snapshot = operation.snapshot
        result.snapshot = OperationSnapshot(
            schemaVersion: snapshot.schemaVersion,
            id: snapshot.id,
            kind: snapshot.kind,
            state: .completed,
            latestSequence: snapshot.latestSequence,
            request: snapshot.request,
            effectiveMetadataPolicy: snapshot.effectiveMetadataPolicy,
            effectiveVerificationPolicy: snapshot.effectiveVerificationPolicy,
            progress: snapshot.progress,
            items: snapshot.items,
            pendingDecision: nil,
            terminalFailure: nil,
            availableActions: [],
            hasPartialCommit: false,
            sourceRetained: false
        )
        return result
    }

    private func replacingActions(
        _ snapshot: OperationSnapshot,
        with actions: [RecoveryAction],
        latestSequence: EventSequence? = nil
    ) -> OperationSnapshot {
        OperationSnapshot(
            schemaVersion: snapshot.schemaVersion,
            id: snapshot.id,
            kind: snapshot.kind,
            state: snapshot.state,
            latestSequence: latestSequence ?? snapshot.latestSequence,
            request: snapshot.request,
            effectiveMetadataPolicy: snapshot.effectiveMetadataPolicy,
            effectiveVerificationPolicy: snapshot.effectiveVerificationPolicy,
            progress: snapshot.progress,
            items: snapshot.items,
            pendingDecision: snapshot.pendingDecision,
            terminalFailure: snapshot.terminalFailure,
            availableActions: actions,
            hasPartialCommit: snapshot.hasPartialCommit,
            sourceRetained: snapshot.sourceRetained
        )
    }

    private func setUpdatedMilliseconds(
        _ url: URL,
        _ values: [OperationID: Int64]
    ) throws {
        let connection = try SQLiteConnection(url: url)
        let update = try connection.statement(
            "UPDATE operations SET updated_ms=? WHERE operation_id=?"
        )
        for (id, value) in values {
            try update.bind(value, at: 1)
            try update.bind(id.rawValue.uuidString.lowercased(), at: 2)
            XCTAssertEqual(try update.step(), SQLITE_DONE)
            try update.reset()
        }
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private func scalarCount(_ url: URL, sql: String) throws -> Int64 {
        let connection = try SQLiteConnection(url: url)
        let query = try connection.statement(sql)
        XCTAssertEqual(try query.step(), SQLITE_ROW)
        return query.int64(at: 0)
    }
}

private final class JournalFixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rascal-sqlite-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("operations.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
