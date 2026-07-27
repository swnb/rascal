import Foundation
import XCTest
@testable import RascalFileOperations
import RascalFileOperationsTestSupport

final class NativeTransactionalMoveTests: XCTestCase {
    func testSameVolumeMoveUsesOneDurableRenameEffect() async throws {
        let fixture = try TransactionalFixture()
        let source = fixture.root.appendingPathComponent("source.txt")
        let destination = fixture.root.appendingPathComponent("destination.txt")
        try Data("same-volume".utf8).write(to: source)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))

        let terminal = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("same-volume".utf8))
        service = nil
        let journal = try SQLiteOperationJournal(url: fixture.journalURL)
        let effects = try journal.effectRecords(operationID: id)
        XCTAssertEqual(effects.map(\.intent.kind), [.stageCommit])
        XCTAssertTrue(effects.allSatisfy { $0.result?.status == .completed })
    }

    func testSourceReplacementAfterPreflightCannotReachTransactionalPlan() async throws {
        let fixture = try TransactionalFixture()
        let source = fixture.root.appendingPathComponent("source.txt")
        let original = fixture.root.appendingPathComponent("source.original.txt")
        let destination = fixture.root.appendingPathComponent("destination.txt")
        try Data("trusted".utf8).write(to: source)
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .preflightReadyBeforePlan)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL,
            serviceFailpoints: failpoints
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: source, to: original)
        try Data("replacement".utf8).write(to: source)
        await gate.release()

        let stopped = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(stopped.state, .failedRecoverable)
        XCTAssertEqual(stopped.terminalFailure?.code, .sourceChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("trusted".utf8))

        service = nil
        let journal = try SQLiteOperationJournal(url: fixture.journalURL)
        XCTAssertTrue(try journal.effectRecords(operationID: id).isEmpty)
    }

    func testSourceReplacementAfterVerificationCannotBeAdoptedByEffectIntent() async throws {
        let fixture = try TransactionalFixture()
        let source = fixture.root.appendingPathComponent("source.txt")
        let original = fixture.root.appendingPathComponent("source.original.txt")
        let destination = fixture.root.appendingPathComponent("destination.txt")
        let counter = fixture.root.appendingPathComponent("syscalls.tsv")
        try Data("trusted".utf8).write(to: source)
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .verificationReadyBeforeEffects)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL,
            serviceFailpoints: failpoints,
            crashScenario: CrashScenarioContext(
                scenarioID: "post-verification-source-replacement",
                runNonce: UUID(),
                syscallCounterURL: counter
            )
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: source, to: original)
        try Data("replacement".utf8).write(to: source)
        await gate.release()

        let stopped = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(stopped.state, .failedRecoverable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("trusted".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: counter.path))

        service = nil
        let journal = try SQLiteOperationJournal(url: fixture.journalURL)
        XCTAssertTrue(try journal.effectRecords(operationID: id).isEmpty)
    }

    func testDestinationParentReplacementAfterVerificationCannotBeAdopted() async throws {
        let fixture = try TransactionalFixture()
        let sourceParent = fixture.root.appendingPathComponent(
            "source-parent",
            isDirectory: true
        )
        let destinationParent = fixture.root.appendingPathComponent(
            "destination-parent",
            isDirectory: true
        )
        let originalParent = fixture.root.appendingPathComponent(
            "destination-parent.original",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationParent,
            withIntermediateDirectories: true
        )
        let source = sourceParent.appendingPathComponent("source.txt")
        let destination = destinationParent.appendingPathComponent("destination.txt")
        let counter = fixture.root.appendingPathComponent("syscalls.tsv")
        try Data("trusted".utf8).write(to: source)
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .verificationReadyBeforeEffects)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL,
            serviceFailpoints: failpoints,
            crashScenario: CrashScenarioContext(
                scenarioID: "post-verification-parent-replacement",
                runNonce: UUID(),
                syscallCounterURL: counter
            )
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: destinationParent, to: originalParent)
        try FileManager.default.createDirectory(
            at: destinationParent,
            withIntermediateDirectories: true
        )
        await gate.release()

        let stopped = try await waitForTerminal(id, service: XCTUnwrap(service))
        XCTAssertEqual(stopped.state, .failedRecoverable)
        XCTAssertEqual(try Data(contentsOf: source), Data("trusted".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: counter.path))

        service = nil
        let journal = try SQLiteOperationJournal(url: fixture.journalURL)
        XCTAssertTrue(try journal.effectRecords(operationID: id).isEmpty)
    }

    func testCrossVolumeMovePersistsCommitQuarantineAndLeafToRootPurge() async throws {
        guard let sourceRoot = ProcessInfo.processInfo.environment["RASCAL_M3_VOLUME_A"],
              let destinationRoot = ProcessInfo.processInfo.environment["RASCAL_M3_VOLUME_B"] else {
            throw XCTSkip("M3 cross-volume gate supplies two mounted APFS roots")
        }
        let run = UUID().uuidString
        let sourceDirectory = URL(fileURLWithPath: sourceRoot)
            .appendingPathComponent("m3-source-\(run)", isDirectory: true)
        let destinationDirectory = URL(fileURLWithPath: destinationRoot)
            .appendingPathComponent("m3-destination-\(run)", isDirectory: true)
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
        let source = sourceDirectory.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("cross-volume".utf8).write(
            to: source.appendingPathComponent("nested/payload.txt")
        )
        let destination = destinationDirectory.appendingPathComponent(
            "moved",
            isDirectory: true
        )
        let journalURL = destinationDirectory.appendingPathComponent("operations.sqlite")
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL
        )
        let id = try await XCTUnwrap(service).submit(OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .structural
        ))

        let terminal = try await waitForTerminal(
            id,
            service: XCTUnwrap(service),
            timeout: .seconds(30)
        )
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.effectiveVerificationPolicy, .sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("nested/payload.txt")),
            Data("cross-volume".utf8)
        )

        service = nil
        let journal = try SQLiteOperationJournal(url: journalURL)
        let effects = try journal.effectRecords(operationID: id)
        XCTAssertEqual(effects.first?.intent.kind, .stageCommit)
        XCTAssertEqual(effects.dropFirst().first?.intent.kind, .quarantineSource)
        XCTAssertEqual(effects.last?.intent.kind, .purgeQuarantineRoot)
        XCTAssertTrue(effects.contains { $0.intent.kind == .purgeQuarantineNode })
        XCTAssertTrue(effects.allSatisfy { $0.result?.status == .completed })
        let purgeOrdinals = effects
            .filter {
                $0.intent.kind == .purgeQuarantineNode ||
                    $0.intent.kind == .purgeQuarantineRoot
            }
            .map(\.intent.effectOrdinal)
        XCTAssertEqual(purgeOrdinals, purgeOrdinals.sorted())
    }

    func testCrossVolumeBarrierCancelRetainsSourceWithoutQuarantineIntent() async throws {
        let roots = try requiredVolumeRoots()
        let fixture = try CrossVolumeFixture(
            sourceRoot: roots.source,
            destinationRoot: roots.destination,
            label: "barrier"
        )
        defer { fixture.cleanup() }
        try fixture.writeSourceTree()
        let barrier = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(barrier, for: .committedAwaitingCleanup)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL,
            serviceFailpoints: failpoints
        )
        let id = try await XCTUnwrap(service).submit(fixture.moveRequest)
        try await barrier.waitUntilEntered()

        try await XCTUnwrap(service).cancel(id)
        let retained = try await XCTUnwrap(service).snapshot(id)
        let mode = try await XCTUnwrap(service).diagnosticServiceMode()
        XCTAssertEqual(
            retained.state,
            .completedWithSourceRetained,
            "serviceMode=\(mode) failure=\(String(describing: retained.terminalFailure))"
        )
        XCTAssertTrue(
            retained.sourceRetained,
            "serviceMode=\(mode) failure=\(String(describing: retained.terminalFailure))"
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.sourcePayload),
            Data("trusted-cross-volume".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationPayload),
            Data("trusted-cross-volume".utf8)
        )

        await barrier.release()
        // Let the suspended execution task observe the terminal projection and
        // relinquish its last strong reference before reopening the sole-writer
        // journal for read-back.
        try await Task.sleep(nanoseconds: 200_000_000)
        service = nil
        let journal = try await reopenJournal(fixture.journalURL)
        let effects = try journal.effectRecords(operationID: id)
        XCTAssertEqual(effects.map(\.intent.kind), [.stageCommit])
        XCTAssertFalse(effects.contains { $0.intent.kind == .quarantineSource })
    }

    func testCrossVolumeRetainFailsClosedWhenSourceParentWasReplaced() async throws {
        let roots = try requiredVolumeRoots()
        let fixture = try CrossVolumeFixture(
            sourceRoot: roots.source,
            destinationRoot: roots.destination,
            label: "retain-parent"
        )
        defer { fixture.cleanup() }
        try fixture.writeSourceTree()
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(gate, for: .committedAwaitingCleanup)
        let service = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL,
            serviceFailpoints: failpoints
        )
        let id = try await service.submit(fixture.moveRequest)
        try await gate.waitUntilEntered()

        try FileManager.default.moveItem(
            at: fixture.sourceDirectory,
            to: fixture.displacedParent
        )
        try FileManager.default.createDirectory(
            at: fixture.sourceDirectory,
            withIntermediateDirectories: true
        )
        await service.cancel(id)
        let stopped = try await service.snapshot(id)
        XCTAssertEqual(stopped.state, .recoveryRequired)
        XCTAssertNotEqual(stopped.state, .completedWithSourceRetained)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationPayload),
            Data("trusted-cross-volume".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.displacedParent.appendingPathComponent(
                "tree/nested/payload.txt"
            )),
            Data("trusted-cross-volume".utf8)
        )
        await gate.release()
    }

    func testExternalMoveToQuarantineBeforeFirstIntentIsNeverAdopted() async throws {
        let roots = try requiredVolumeRoots()
        let fixture = try CrossVolumeFixture(
            sourceRoot: roots.source,
            destinationRoot: roots.destination,
            label: "pre-intent-quarantine"
        )
        defer { fixture.cleanup() }
        try fixture.writeSourceTree()
        let gate = ContinuationGate()
        let failpoints = FakeFailpointController()
        await failpoints.setGate(
            gate,
            for: .sourceCleanupInspectedBeforeQuarantineIntent
        )
        let counter = fixture.destinationDirectory.appendingPathComponent(
            "syscalls.tsv"
        )
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: fixture.journalURL,
            serviceFailpoints: failpoints,
            crashScenario: CrashScenarioContext(
                scenarioID: "pre-intent-quarantine-external-move",
                runNonce: UUID(),
                syscallCounterURL: counter
            )
        )
        let id = try await XCTUnwrap(service).submit(fixture.moveRequest)
        try await gate.waitUntilEntered()
        let snapshot = try await XCTUnwrap(service).snapshot(id)
        let itemID = try XCTUnwrap(snapshot.items.first?.id)
        let quarantine = fixture.sourceDirectory.appendingPathComponent(
            ".rascal-quarantine-" +
                id.rawValue.uuidString.lowercased() + "-" +
                itemID.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
        let counterBefore = try Data(contentsOf: counter)
        try FileManager.default.moveItem(at: fixture.source, to: quarantine)
        await gate.release()

        let stopped = try await waitForTerminal(
            id,
            service: XCTUnwrap(service),
            timeout: .seconds(30)
        )
        XCTAssertTrue(
            [.cleanupRequired, .recoveryRequired].contains(stopped.state)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent(
                "nested/payload.txt"
            )),
            Data("trusted-cross-volume".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationPayload),
            Data("trusted-cross-volume".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: counter), counterBefore)

        service = nil
        let journal = try SQLiteOperationJournal(url: fixture.journalURL)
        XCTAssertFalse(try journal.effectRecords(operationID: id).contains {
            [
                .quarantineSource,
                .purgeQuarantineNode,
                .purgeQuarantineRoot,
            ].contains($0.intent.kind)
        })
    }

    func testCrossVolumeCleanupIdentityRacesStopConservatively() async throws {
        let roots = try requiredVolumeRoots()
        for mutation in CleanupMutation.allCases {
            let fixture = try CrossVolumeFixture(
                sourceRoot: roots.source,
                destinationRoot: roots.destination,
                label: mutation.rawValue
            )
            defer { fixture.cleanup() }
            try fixture.writeSourceTree()
            let gate = TargetAcknowledgementGate(
                kind: mutation == .sourceIdentity
                    ? .quarantineSource
                    : .purgeQuarantineNode,
                window: .intentDurableBeforeEffect
            )
            var service: FileOperationService? = try FileOperationService.makeTransactional(
                journalURL: fixture.journalURL,
                serviceFailpoints: gate,
                crashScenario: CrashScenarioContext(
                    scenarioID: "M3-CLEAN-IDENTITY-\(mutation.rawValue)",
                    runNonce: UUID()
                )
            )
            let id = try await XCTUnwrap(service).submit(fixture.moveRequest)
            try await gate.waitUntilEntered()

            do {
                if mutation == .sourceIdentity {
                    try fixture.replaceSourceIdentity()
                } else {
                    let snapshot = try await XCTUnwrap(service).snapshot(id)
                    let quarantine = try XCTUnwrap(
                        snapshot.items.first?.receipt?.quarantineURL
                    )
                    try fixture.apply(mutation, to: quarantine)
                }
                await gate.release()
            } catch {
                await gate.release()
                throw error
            }

            let stopped = try await waitForTerminal(
                id,
                service: XCTUnwrap(service),
                timeout: .seconds(30)
            )
            XCTAssertTrue(
                [.cleanupRequired, .recoveryRequired].contains(stopped.state),
                "\(mutation.rawValue) unexpectedly converged to \(stopped.state)"
            )
            XCTAssertEqual(
                try Data(contentsOf: fixture.destinationPayload),
                Data("trusted-cross-volume".utf8),
                "\(mutation.rawValue) changed the committed destination"
            )
            try fixture.assertExternalObjectSurvived(mutation)

            service = nil
            let journal = try SQLiteOperationJournal(url: fixture.journalURL)
            let effects = try journal.effectRecords(operationID: id)
            if mutation == .sourceIdentity {
                XCTAssertEqual(
                    effects.last?.intent.kind,
                    .quarantineSource
                )
                XCTAssertEqual(effects.last?.result?.status, .ambiguous)
            } else {
                XCTAssertTrue(effects.contains {
                    $0.intent.kind == .quarantineSource &&
                        $0.result?.status == .completed
                })
                XCTAssertTrue(effects.contains {
                    $0.intent.kind == .purgeQuarantineNode &&
                        $0.result?.status == .ambiguous
                })
                XCTAssertFalse(effects.contains {
                    [.purgeQuarantineNode, .purgeQuarantineRoot]
                        .contains($0.intent.kind) &&
                        $0.result?.status == .completed
                })
            }
        }
    }

    private func requiredVolumeRoots() throws -> (source: URL, destination: URL) {
        guard let source = ProcessInfo.processInfo.environment["RASCAL_M3_VOLUME_A"],
              let destination =
                ProcessInfo.processInfo.environment["RASCAL_M3_VOLUME_B"] else {
            throw XCTSkip("M3 cross-volume gate supplies two mounted APFS roots")
        }
        return (
            URL(fileURLWithPath: source, isDirectory: true),
            URL(fileURLWithPath: destination, isDirectory: true)
        )
    }

    private func reopenJournal(_ url: URL) async throws -> SQLiteOperationJournal {
        var lastError: Error?
        for _ in 0..<100 {
            do {
                return try SQLiteOperationJournal(url: url)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        guard let lastError else {
            throw NSError(
                domain: "Rascal.M3.MoveTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "journal reopen exhausted without error"]
            )
        }
        throw lastError
    }

    private func waitForTerminal(
        _ id: OperationID,
        service: FileOperationService,
        timeout: Duration = .seconds(15)
    ) async throws -> OperationSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = try await service.snapshot(id)
            if [
                OperationState.completed,
                .completedWithSkips,
                .completedWithSourceRetained,
                .cancelled,
                .failedRecoverable,
                .recoveryRequired,
                .cleanupRequired,
                .rolledBack,
            ].contains(snapshot.state) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(
            "transactional move did not reach a terminal state; " +
                "serviceMode=\(await service.diagnosticServiceMode())"
        )
        return try await service.snapshot(id)
    }
}

private enum CleanupMutation: String, CaseIterable {
    case sourceIdentity = "source-identity"
    case unexpectedChild = "unexpected-child"
    case symlinkSwap = "symlink-swap"
    case hardlinkSwap = "hardlink-swap"
    case missingNode = "missing-node"
    case parentIdentity = "parent-identity"
}

private final class TargetAcknowledgementGate: @unchecked Sendable, FailpointController {
    private let kind: DurableEffectKind
    private let window: CrashAcknowledgementWindow
    private let gate = ContinuationGate()

    init(kind: DurableEffectKind, window: CrashAcknowledgementWindow) {
        self.kind = kind
        self.window = window
    }

    func hit(_ point: Failpoint, operationID: OperationID) async {
        _ = point
        _ = operationID
    }

    func hit(_ acknowledgement: CrashAcknowledgement) async {
        guard acknowledgement.kind == kind,
              acknowledgement.window == window else {
            return
        }
        await gate.wait()
    }

    func waitUntilEntered() async throws {
        try await gate.waitUntilEntered()
    }

    func release() async {
        await gate.release()
    }
}

private final class CrossVolumeFixture {
    let sourceDirectory: URL
    let destinationDirectory: URL
    let source: URL
    let destination: URL
    let journalURL: URL
    let externalObject: URL
    let displacedSource: URL
    let displacedParent: URL

    var sourcePayload: URL {
        source.appendingPathComponent("nested/payload.txt")
    }

    var destinationPayload: URL {
        destination.appendingPathComponent("nested/payload.txt")
    }

    var moveRequest: OperationRequest {
        OperationRequest(
            kind: .move,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .structural
        )
    }

    init(sourceRoot: URL, destinationRoot: URL, label: String) throws {
        let run = "\(label)-\(UUID().uuidString)"
        sourceDirectory = sourceRoot.appendingPathComponent(
            "m3-source-\(run)",
            isDirectory: true
        )
        destinationDirectory = destinationRoot.appendingPathComponent(
            "m3-destination-\(run)",
            isDirectory: true
        )
        source = sourceDirectory.appendingPathComponent("tree", isDirectory: true)
        destination = destinationDirectory.appendingPathComponent(
            "moved",
            isDirectory: true
        )
        journalURL = destinationDirectory.appendingPathComponent("operations.sqlite")
        externalObject = sourceDirectory.appendingPathComponent("external.txt")
        displacedSource = sourceDirectory.appendingPathComponent(
            "trusted-source-before-race",
            isDirectory: true
        )
        displacedParent = sourceDirectory.deletingLastPathComponent()
            .appendingPathComponent("displaced-parent-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
    }

    func writeSourceTree() throws {
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("trusted-cross-volume".utf8).write(to: sourcePayload)
        try Data("external-must-survive".utf8).write(to: externalObject)
    }

    func replaceSourceIdentity() throws {
        try FileManager.default.moveItem(at: source, to: displacedSource)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("replacement-race".utf8).write(to: sourcePayload)
    }

    func apply(_ mutation: CleanupMutation, to quarantine: URL) throws {
        let payload = quarantine.appendingPathComponent("nested/payload.txt")
        switch mutation {
        case .unexpectedChild:
            try Data("unexpected-must-survive".utf8).write(
                to: quarantine.appendingPathComponent("unexpected.txt")
            )
        case .symlinkSwap:
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.createSymbolicLink(
                at: payload,
                withDestinationURL: externalObject
            )
        case .hardlinkSwap:
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.linkItem(at: externalObject, to: payload)
        case .missingNode:
            try FileManager.default.removeItem(at: payload)
        case .parentIdentity:
            try FileManager.default.moveItem(
                at: sourceDirectory,
                to: displacedParent
            )
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )
        case .sourceIdentity:
            preconditionFailure("source identity mutation is applied before quarantine")
        }
    }

    func assertExternalObjectSurvived(_ mutation: CleanupMutation) throws {
        switch mutation {
        case .sourceIdentity:
            XCTAssertEqual(
                try Data(contentsOf: displacedSource.appendingPathComponent(
                    "nested/payload.txt"
                )),
                Data("trusted-cross-volume".utf8)
            )
            XCTAssertEqual(try Data(contentsOf: sourcePayload), Data("replacement-race".utf8))
        case .parentIdentity:
            XCTAssertEqual(
                try Data(contentsOf: displacedParent.appendingPathComponent("external.txt")),
                Data("external-must-survive".utf8)
            )
        default:
            XCTAssertEqual(
                try Data(contentsOf: externalObject),
                Data("external-must-survive".utf8)
            )
        }
    }

    func cleanup() {
        for path in [sourceDirectory, destinationDirectory, displacedParent]
        where FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
    }
}

private final class TransactionalFixture {
    let root: URL
    let journalURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rascal-m3-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        journalURL = root.appendingPathComponent("operations.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
