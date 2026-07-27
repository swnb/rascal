import Foundation
import RascalFileOperations
import Darwin

private let usage = """
usage:
  FileOpsCrashProbe --self-check
  FileOpsCrashProbe --worker <journal> <sandbox> <kind> <window> <scenario> <nonce> <operation> <item>
  FileOpsCrashProbe --recover <journal> <sandbox> <kind> <operation> <item>
  FileOpsCrashProbe --real-worker <journal> <source> <destination> <operation-kind> <effect-kind> <window> <scenario> <nonce>
  FileOpsCrashProbe --real-prepare <journal> <source> <destination> <operation-kind>
  FileOpsCrashProbe --real-action <journal> <operation> <action> <effect-kind> <window> <scenario> <nonce>
  FileOpsCrashProbe --real-converge <journal> <operation> <strategy>
  FileOpsCrashProbe --journal-wal-worker <journal>
  FileOpsCrashProbe --try-open-journal <journal>
  FileOpsCrashProbe --try-service-safe-mode <journal>
  FileOpsCrashProbe --real-prepare-hold <journal> <source> <destination>
  FileOpsCrashProbe --assert-stale-action <journal> <fixture-json>
  FileOpsCrashProbe --real-barrier-worker <journal> <source> <destination>
  FileOpsCrashProbe --real-retain <journal> <operation>
  FileOpsCrashProbe --journal-process-self-check <journal>
  FileOpsCrashProbe --assert-no-owner-fd <lock-path>
"""

private final class PipeAcknowledgementController: FailpointController {
    private let kind: DurableEffectKind?
    private let target: CrashAcknowledgementWindow

    init(kind: DurableEffectKind? = nil, target: CrashAcknowledgementWindow) {
        self.kind = kind
        self.target = target
    }

    func hit(_ point: Failpoint, operationID: OperationID) async {
        _ = point
        _ = operationID
    }

    func hit(_ acknowledgement: CrashAcknowledgement) async {
        guard acknowledgement.window == target,
              kind == nil || acknowledgement.kind == kind else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(acknowledgement)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            try FileHandle.standardOutput.synchronize()
        } catch {
            FileHandle.standardError.write(
                Data("ACK serialization failed: \(error)\n".utf8)
            )
            exit(EX_IOERR)
        }
        while true {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}

private final class RetainBarrierController: FailpointController {
    func hit(_ point: Failpoint, operationID: OperationID) async {
        guard point == .committedAwaitingCleanup else { return }
        FileHandle.standardOutput.write(
            Data(("retain-barrier " +
                  operationID.rawValue.uuidString.lowercased() + "\n").utf8)
        )
        try? FileHandle.standardOutput.synchronize()
        while true {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    func hit(_ acknowledgement: CrashAcknowledgement) async {
        _ = acknowledgement
    }
}

private struct RecoverySummary: Codable {
    let ownerEpoch: UUID
    let effectRecords: Int
    let completed: Int
    let notPerformed: Int
    let ambiguous: Int
    let counter: Int
    let fromExists: Bool
    let toExists: Bool
    let targetExists: Bool
}

private struct RealOperationSummary: Codable {
    let operationID: UUID
    let state: OperationState
    let itemState: OperationItemState?
    let actionNames: [String]
    let actionIDs: [UUID]
    let ownerEpoch: UUID?
    let effects: [RealEffectSummary]
    let source: String?
    let destination: String?
    let sourceExists: Bool
    let destinationExists: Bool
    let recoveryError: String?
    let startupRuns: Int
    let startupActionIssuances: Int
}

private struct RealEffectSummary: Codable {
    let effectID: UUID
    let itemID: UUID
    let kind: DurableEffectKind
    let ordinal: UInt64
    let ownerEpoch: UUID
    let intentSequence: EventSequence
    let resultSequence: EventSequence?
    let status: DurableEffectResultStatus?
    let nodeID: String?
    let relativePath: String?
    let manifestDigest: String?
}

private struct StaleActionFixture: Codable {
    let operationID: OperationID
    let action: RecoveryAction
    let ownerEpoch: UUID
}

@main
private enum CrashProbeMain {
    private static var crashSyscallCounterURL: URL? {
        ProcessInfo.processInfo.environment[
            "RASCAL_M3_SYSCALL_COUNTER_PATH"
        ].map { URL(fileURLWithPath: $0) }
    }

    static func main() async {
        do {
            let arguments = CommandLine.arguments
            if arguments == [arguments[0], "--self-check"] {
                print("FileOpsCrashProbe M3 durable ACK driver: ready")
                return
            }
            guard arguments.count >= 2 else { throw ProbeError.usage }
            switch arguments[1] {
            case "--worker":
                guard arguments.count == 10 else { throw ProbeError.usage }
                try await runWorker(arguments)
            case "--recover":
                guard arguments.count == 7 else { throw ProbeError.usage }
                try await runRecovery(arguments)
            case "--real-worker":
                guard arguments.count == 10 else { throw ProbeError.usage }
                try await runRealWorker(arguments)
            case "--real-prepare":
                guard arguments.count == 6 else { throw ProbeError.usage }
                try await runRealPrepare(arguments)
            case "--real-action":
                guard arguments.count == 9 else { throw ProbeError.usage }
                try await runRealAction(arguments)
            case "--real-converge":
                guard arguments.count == 5 else { throw ProbeError.usage }
                try await runRealConvergence(arguments)
            case "--journal-wal-worker":
                guard arguments.count == 3 else { throw ProbeError.usage }
                try await runJournalWALWorker(arguments)
            case "--try-open-journal":
                guard arguments.count == 3 else { throw ProbeError.usage }
                _ = try SQLiteOperationJournal(
                    url: URL(fileURLWithPath: arguments[2])
                )
                print("journal-opened")
            case "--try-service-safe-mode":
                guard arguments.count == 3 else { throw ProbeError.usage }
                try await assertServiceSafeMode(
                    journal: URL(fileURLWithPath: arguments[2])
                )
            case "--real-prepare-hold":
                guard arguments.count == 5 else { throw ProbeError.usage }
                try await runRealPrepareHold(arguments)
            case "--assert-stale-action":
                guard arguments.count == 4 else { throw ProbeError.usage }
                try await assertStaleAction(arguments)
            case "--real-barrier-worker":
                guard arguments.count == 5 else { throw ProbeError.usage }
                try await runRealBarrierWorker(arguments)
            case "--real-retain":
                guard arguments.count == 4 else { throw ProbeError.usage }
                try await runRealRetain(arguments)
            case "--assert-no-owner-fd":
                guard arguments.count == 3 else { throw ProbeError.usage }
                try assertNoOpenDescriptor(path: arguments[2])
                print("owner-fd-not-inherited")
            case "--journal-process-self-check":
                guard arguments.count == 3 else { throw ProbeError.usage }
                try journalProcessSelfCheck(
                    journal: URL(fileURLWithPath: arguments[2])
                )
            default:
                throw ProbeError.usage
            }
        } catch ProbeError.usage {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(EX_USAGE)
        } catch {
            FileHandle.standardError.write(Data("FileOpsCrashProbe: \(error)\n".utf8))
            exit(EX_SOFTWARE)
        }
    }

    private static func runWorker(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let sandbox = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard let kind = DurableEffectKind(rawValue: arguments[4]),
              let window = CrashAcknowledgementWindow(rawValue: arguments[5]),
              let nonce = UUID(uuidString: arguments[7]),
              let operationUUID = UUID(uuidString: arguments[8]),
              let itemUUID = UUID(uuidString: arguments[9]) else {
            throw ProbeError.usage
        }
        let spec = try makeSpec(kind: kind, sandbox: sandbox)
        let service = try FileOperationService.makeCrashHarness(
            journalURL: journal,
            operationID: OperationID(rawValue: operationUUID),
            itemID: OperationItemID(rawValue: itemUUID),
            spec: spec,
            serviceFailpoints: PipeAcknowledgementController(target: window),
            crashScenario: CrashScenarioContext(
                scenarioID: arguments[6],
                runNonce: nonce
            )
        )
        _ = try await service.runCrashHarnessEffect()
        throw ProbeError.missingAcknowledgement
    }

    private static func runRealWorker(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let source = URL(fileURLWithPath: arguments[3])
        let destination = URL(fileURLWithPath: arguments[4])
        guard let operationKind = OperationKind(rawValue: arguments[5]),
              [.move, .replace].contains(operationKind),
              let effectKind = DurableEffectKind(rawValue: arguments[6]),
              let window = CrashAcknowledgementWindow(rawValue: arguments[7]),
              let nonce = UUID(uuidString: arguments[9]) else {
            throw ProbeError.usage
        }
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            serviceFailpoints: PipeAcknowledgementController(
                kind: effectKind,
                target: window
            ),
            crashScenario: CrashScenarioContext(
                scenarioID: arguments[8],
                runNonce: nonce,
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        let id = try await service.submit(realRequest(
            kind: operationKind,
            source: source,
            destination: destination
        ))
        let snapshot = try await waitForRealOperation(id, service: service)
        throw ProbeError.realOperation(
            "target ACK was not reached; state=\(snapshot.state.rawValue) " +
            "item=\(snapshot.items.first?.state.rawValue ?? "missing") " +
            "failure=\(snapshot.terminalFailure?.diagnostic ?? "none") " +
            "actions=\(snapshot.availableActions.map(actionName))"
        )
    }

    private static func runRealPrepare(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let source = URL(fileURLWithPath: arguments[3])
        let destination = URL(fileURLWithPath: arguments[4])
        guard let operationKind = OperationKind(rawValue: arguments[5]),
              [.move, .replace].contains(operationKind) else {
            throw ProbeError.usage
        }
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            crashScenario: CrashScenarioContext(
                scenarioID: "real-prepare",
                runNonce: UUID(),
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        let id = try await service.submit(realRequest(
            kind: operationKind,
            source: source,
            destination: destination
        ))
        let snapshot = try await waitForRealOperation(id, service: service)
        guard snapshot.state == .recoveryRequired || snapshot.state == .completed else {
            throw ProbeError.realOperation(
                "fixture preparation stopped in \(snapshot.state.rawValue)"
            )
        }
        print(id.rawValue.uuidString)
    }

    private static func runRealAction(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        guard let operationUUID = UUID(uuidString: arguments[3]),
              let effectKind = DurableEffectKind(rawValue: arguments[5]),
              let window = CrashAcknowledgementWindow(rawValue: arguments[6]),
              let nonce = UUID(uuidString: arguments[8]) else {
            throw ProbeError.usage
        }
        let id = OperationID(rawValue: operationUUID)
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            serviceFailpoints: PipeAcknowledgementController(
                kind: effectKind,
                target: window
            ),
            crashScenario: CrashScenarioContext(
                scenarioID: arguments[7],
                runNonce: nonce,
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        let snapshot = try await service.snapshot(id)
        let action = try requireAction(named: arguments[4], in: snapshot)
        try await service.recover(id, action: action)
        throw ProbeError.missingAcknowledgement
    }

    private static func runRealConvergence(_ arguments: [String]) async throws {
        let journalURL = URL(fileURLWithPath: arguments[2])
        guard let operationUUID = UUID(uuidString: arguments[3]) else {
            throw ProbeError.usage
        }
        let strategy = arguments[4]
        guard ["commit", "discard", "restore", "observe"].contains(strategy) else {
            throw ProbeError.usage
        }
        let id = OperationID(rawValue: operationUUID)
        var service: FileOperationService? = try FileOperationService.makeTransactional(
            journalURL: journalURL,
            crashScenario: CrashScenarioContext(
                scenarioID: "real-converge",
                runNonce: UUID(),
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        var snapshot = try await require(service, "transactional service").snapshot(id)
        var recoveryError: String?
        if strategy != "observe" {
            for _ in 0..<12 {
                guard !isSettled(snapshot.state) else { break }
                var action = preferredAction(
                    in: snapshot,
                    strategy: strategy
                )
                if action == nil {
                    // W3 may already have an atomic receipt and only need the
                    // service scheduler to converge the durable projection.
                    for _ in 0..<200 {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        snapshot = try await require(
                            service,
                            "transactional service"
                        ).snapshot(id)
                        if isSettled(snapshot.state) { break }
                        action = preferredAction(
                            in: snapshot,
                            strategy: strategy
                        )
                        if action != nil { break }
                    }
                }
                guard let action else {
                    recoveryError = "no \(strategy) action in \(snapshot.state.rawValue)"
                    break
                }
                do {
                    try await require(service, "transactional service")
                        .recover(id, action: action)
                } catch {
                    recoveryError = "selected=\(actionID(action)) " +
                        String(describing: error)
                    break
                }
                snapshot = try await require(service, "transactional service").snapshot(id)
            }
        }
        let source = snapshot.items.first?.source
        let destination = snapshot.items.first?.destination
        let startupCounters = try await require(service, "transactional service")
            .diagnosticStartupCounters()
        service = nil
        let journal = try SQLiteOperationJournal(url: journalURL)
        let effects = try journal.effectRecords(operationID: id).map {
            RealEffectSummary(
                effectID: $0.intent.effectID,
                itemID: $0.intent.itemID.rawValue,
                kind: $0.intent.kind,
                ordinal: $0.intent.effectOrdinal,
                ownerEpoch: $0.intent.ownerEpoch,
                intentSequence: $0.intent.intentSequence,
                resultSequence: $0.result?.resultSequence,
                status: $0.result?.status,
                nodeID: $0.intent.nodeID,
                relativePath: $0.intent.relativePath,
                manifestDigest: $0.intent.manifestDigest
            )
        }
        let summary = RealOperationSummary(
            operationID: operationUUID,
            state: snapshot.state,
            itemState: snapshot.items.first?.state,
            actionNames: snapshot.availableActions.map(actionName),
            actionIDs: snapshot.availableActions.map(actionID),
            ownerEpoch: journal.ownerEpoch,
            effects: effects,
            source: source?.path,
            destination: destination?.path,
            sourceExists: source.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false,
            destinationExists: destination.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false,
            recoveryError: recoveryError,
            startupRuns: startupCounters.runs,
            startupActionIssuances: startupCounters.actions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(summary))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func runJournalWALWorker(_ arguments: [String]) async throws {
        let journalURL = URL(fileURLWithPath: arguments[2])
        let journal = try SQLiteOperationJournal(url: journalURL)
        if try journal.loadOperations().isEmpty {
            let operationID = OperationID(rawValue: UUID())
            let itemID = OperationItemID(rawValue: UUID())
            let item = OperationItemSnapshot(
                id: itemID,
                source: journalURL,
                destination: journalURL,
                state: .pending,
                progress: .zero,
                metadata: nil,
                verification: nil,
                receipt: nil,
                failure: nil
            )
            let request = OperationRequest(
                kind: .copy,
                sources: [journalURL],
                destination: journalURL,
                destinationMode: .exact,
                conflictPolicy: .stop
            )
            let snapshot = OperationSnapshot(
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
            _ = try journal.admit(snapshot, at: Date())
        }
        let wal = URL(fileURLWithPath: journalURL.path + "-wal")
        let shm = URL(fileURLWithPath: journalURL.path + "-shm")
        guard fileSize(wal) > 0, fileSize(shm) > 0 else {
            throw ProbeError.processCheck("journal WAL recovery set is incomplete")
        }
        FileHandle.standardOutput.write(Data("journal-wal-ready\n".utf8))
        try FileHandle.standardOutput.synchronize()
        withExtendedLifetime(journal) {
            while true {
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    private static func assertServiceSafeMode(journal: URL) async throws {
        let service = try FileOperationService(
            configuration: ServiceConfiguration(journalURL: journal)
        )
        let mode = await service.diagnosticServiceMode()
        guard mode.contains("journalUnavailable") else {
            throw ProbeError.processCheck(
                "corrupt journal did not project journalUnavailable: \(mode)"
            )
        }
        do {
            let parent = journal.deletingLastPathComponent()
            _ = try await service.submit(OperationRequest(
                kind: .copy,
                sources: [
                    parent.appendingPathComponent("safe-mode-source.bin")
                ],
                destination: parent.appendingPathComponent(
                    "safe-mode-destination.bin"
                ),
                destinationMode: .exact,
                conflictPolicy: .stop
            ))
            throw ProbeError.processCheck(
                "safe-mode service unexpectedly admitted a mutation"
            )
        } catch let failure as FileOperationFailure
            where failure.code == .serviceSafeMode {
            print("service-safe-mode PASS mode=\(mode)")
        }
    }

    private static func runRealPrepareHold(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let source = URL(fileURLWithPath: arguments[3])
        let destination = URL(fileURLWithPath: arguments[4])
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            crashScenario: CrashScenarioContext(
                scenarioID: "real-prepare-hold",
                runNonce: UUID(),
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        let operationID = try await service.submit(realRequest(
            kind: .replace,
            source: source,
            destination: destination
        ))
        let snapshot = try await waitForRealOperation(
            operationID,
            service: service
        )
        let action = try requireAction(
            named: "finalizeKnownCommit",
            in: snapshot
        )
        let ownerEpoch = try require(
            await service.crashHarnessOwnerEpoch(),
            "prepared owner epoch"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(StaleActionFixture(
            operationID: operationID,
            action: action,
            ownerEpoch: ownerEpoch
        )))
        FileHandle.standardOutput.write(Data("\n".utf8))
        try FileHandle.standardOutput.synchronize()
        withExtendedLifetime(service) {
            while true {
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    private static func assertStaleAction(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let fixture = try JSONDecoder().decode(
            StaleActionFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        )
        let before = crashSyscallCounterURL.map(counterLines) ?? 0
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            crashScenario: CrashScenarioContext(
                scenarioID: "assert-stale-action",
                runNonce: UUID(),
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        do {
            try await service.recover(
                fixture.operationID,
                action: fixture.action
            )
            throw ProbeError.processCheck(
                "old-owner recovery action was accepted"
            )
        } catch let failure as FileOperationFailure
            where failure.code == .controlRejected {
            let after = crashSyscallCounterURL.map(counterLines) ?? 0
            let successorEpoch = try require(
                await service.crashHarnessOwnerEpoch(),
                "successor owner epoch"
            )
            guard successorEpoch != fixture.ownerEpoch, before == after else {
                throw ProbeError.processCheck(
                    "stale action changed epoch or syscall evidence"
                )
            }
            print(
                "stale-action-rejected PASS old=" +
                    fixture.ownerEpoch.uuidString.lowercased() +
                    " successor=" + successorEpoch.uuidString.lowercased() +
                    " syscalls=\(after)"
            )
        }
    }

    private static func runRealBarrierWorker(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let source = URL(fileURLWithPath: arguments[3])
        let destination = URL(fileURLWithPath: arguments[4])
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            serviceFailpoints: RetainBarrierController(),
            crashScenario: CrashScenarioContext(
                scenarioID: "real-retain-barrier",
                runNonce: UUID(),
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        let id = try await service.submit(realRequest(
            kind: .move,
            source: source,
            destination: destination
        ))
        _ = try await waitForRealOperation(id, service: service)
        throw ProbeError.realOperation(
            "retain barrier worker unexpectedly passed its failpoint"
        )
    }

    private static func runRealRetain(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        guard let rawID = UUID(uuidString: arguments[3]) else {
            throw ProbeError.usage
        }
        let id = OperationID(rawValue: rawID)
        let service = try FileOperationService.makeTransactional(
            journalURL: journal,
            crashScenario: CrashScenarioContext(
                scenarioID: "real-retain-restart",
                runNonce: UUID(),
                syscallCounterURL: crashSyscallCounterURL
            )
        )
        var snapshot = try await service.snapshot(id)
        for _ in 0..<500 where snapshot.availableActions.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
            snapshot = try await service.snapshot(id)
        }
        let retain = try requireAction(named: "retainSource", in: snapshot)
        try await service.recover(id, action: retain)
        snapshot = try await service.snapshot(id)
        guard snapshot.state == .completedWithSourceRetained,
              snapshot.sourceRetained else {
            throw ProbeError.realOperation(
                "restart retain did not converge: \(snapshot.state.rawValue)"
            )
        }
        print("restart-retain PASS operation=\(rawID.uuidString.lowercased())")
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func realRequest(
        kind: OperationKind,
        source: URL,
        destination: URL
    ) -> OperationRequest {
        OperationRequest(
            kind: kind,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: kind == .replace ? .replace : .stop,
            verificationPolicy: .sha256
        )
    }

    private static func waitForRealOperation(
        _ id: OperationID,
        service: FileOperationService
    ) async throws -> OperationSnapshot {
        for _ in 0..<3_000 {
            let snapshot = try await service.snapshot(id)
            if isSettled(snapshot.state) || snapshot.state == .recoveryRequired ||
                snapshot.state == .cleanupRequired {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.realOperation("operation did not settle before timeout")
    }

    private static func isSettled(_ state: OperationState) -> Bool {
        [
            .completed,
            .completedWithSkips,
            .completedWithSourceRetained,
            .cancelled,
            .rolledBack,
        ].contains(state)
    }

    private static func preferredAction(
        in snapshot: OperationSnapshot,
        strategy: String
    ) -> RecoveryAction? {
        let order: [String]
        if strategy == "discard" {
            order = ["discardKnownStaging", "restoreBackup"]
        } else if strategy == "restore" {
            order = ["restoreBackup"]
        } else {
            order = [
                "resumeFromVerifiedStage",
                "retrySourceCleanup",
                "finalizeKnownCommit",
            ]
        }
        for name in order {
            if let action = snapshot.availableActions.first(where: {
                actionName($0) == name
            }) {
                return action
            }
        }
        return nil
    }

    private static func requireAction(
        named name: String,
        in snapshot: OperationSnapshot
    ) throws -> RecoveryAction {
        guard let action = snapshot.availableActions.first(where: {
            actionName($0) == name
        }) else {
            throw ProbeError.realOperation(
                "missing \(name) action; state=\(snapshot.state.rawValue), " +
                    "actions=\(snapshot.availableActions.map(actionName))"
            )
        }
        return action
    }

    private static func actionName(_ action: RecoveryAction) -> String {
        switch action {
        case .resumeFromVerifiedStage: "resumeFromVerifiedStage"
        case .retrySourceCleanup: "retrySourceCleanup"
        case .retainSource: "retainSource"
        case .rollbackCommittedDestination: "rollbackCommittedDestination"
        case .restoreBackup: "restoreBackup"
        case .finalizeKnownCommit: "finalizeKnownCommit"
        case .discardKnownStaging: "discardKnownStaging"
        }
    }

    private static func actionID(_ action: RecoveryAction) -> UUID {
        switch action {
        case let .resumeFromVerifiedStage(command),
             let .retrySourceCleanup(command),
             let .retainSource(command),
             let .rollbackCommittedDestination(command),
             let .restoreBackup(command),
             let .finalizeKnownCommit(command),
             let .discardKnownStaging(command):
            command.actionID
        }
    }

    private static func runRecovery(_ arguments: [String]) async throws {
        let journal = URL(fileURLWithPath: arguments[2])
        let sandbox = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard let kind = DurableEffectKind(rawValue: arguments[4]),
              let operationUUID = UUID(uuidString: arguments[5]),
              let itemUUID = UUID(uuidString: arguments[6]) else {
            throw ProbeError.usage
        }
        let spec = try makeSpec(kind: kind, sandbox: sandbox)
        let service = try FileOperationService.makeCrashHarness(
            journalURL: journal,
            operationID: OperationID(rawValue: operationUUID),
            itemID: OperationItemID(rawValue: itemUUID),
            spec: spec
        )
        let records = try await service.runCrashHarnessEffect()
        let ownerEpoch = try require(
            await service.crashHarnessOwnerEpoch(),
            "recovery owner epoch"
        )
        let statuses = records.compactMap(\.result?.status)
        let summary = RecoverySummary(
            ownerEpoch: ownerEpoch,
            effectRecords: records.count,
            completed: statuses.filter { $0 == .completed }.count,
            notPerformed: statuses.filter { $0 == .notPerformed }.count,
            ambiguous: statuses.filter { $0 == .ambiguous }.count,
            counter: counterLines(sandbox.appendingPathComponent("counter.log")),
            fromExists: FileManager.default.fileExists(
                atPath: sandbox.appendingPathComponent("from").path
            ),
            toExists: FileManager.default.fileExists(
                atPath: sandbox.appendingPathComponent("to").path
            ),
            targetExists: FileManager.default.fileExists(
                atPath: sandbox.appendingPathComponent("target").path
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(summary))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func makeSpec(
        kind: DurableEffectKind,
        sandbox: URL
    ) throws -> CrashHarnessEffectSpec {
        let specURL = sandbox.appendingPathComponent("spec.json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: specURL) {
            let spec = try decoder.decode(CrashHarnessEffectSpec.self, from: data)
            guard spec.kind == kind else { throw ProbeError.usage }
            return spec
        }
        let counter = sandbox.appendingPathComponent("counter.log")
        let spec: CrashHarnessEffectSpec
        switch kind {
        case .stageCommit, .backupDestination, .commitReplacement,
             .quarantineSource, .rollbackCommittedDestination, .restoreBackup:
            spec = try .rename(
                kind: kind,
                from: sandbox.appendingPathComponent("from"),
                to: sandbox.appendingPathComponent("to"),
                counterURL: counter
            )
        case .purgeQuarantineRoot:
            spec = try .unlink(
                kind: kind,
                target: sandbox.appendingPathComponent("target", isDirectory: true),
                targetIsDirectory: true,
                counterURL: counter
            )
        case .purgeQuarantineNode, .purgeBackup, .discardStaging:
            spec = try .unlink(
                kind: kind,
                target: sandbox.appendingPathComponent("target"),
                targetIsDirectory: false,
                counterURL: counter
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(spec).write(to: specURL, options: .atomic)
        return spec
    }

    private static func counterLines(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return 0
        }
        return text.split(separator: "\n").count
    }

    private static func journalProcessSelfCheck(journal: URL) throws {
        var owner: SQLiteOperationJournal? = try SQLiteOperationJournal(url: journal)
        let firstEpoch = try require(owner?.ownerEpoch, "owner epoch")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let lockPath = journal.deletingLastPathComponent()
            .appendingPathComponent("operations.sqlite.owner.lock").path

        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--assert-no-owner-fd", lockPath]
        let helperOutput = Pipe()
        helper.standardOutput = helperOutput
        helper.standardError = FileHandle.standardError
        try helper.run()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0 else {
            throw ProbeError.processCheck("helper inherited the owner descriptor")
        }

        let contender = Process()
        contender.executableURL = executable
        contender.arguments = ["--try-open-journal", journal.path]
        contender.standardOutput = FileHandle.standardOutput
        contender.standardError = FileHandle.standardError
        try contender.run()
        contender.waitUntilExit()
        guard contender.terminationStatus != 0 else {
            throw ProbeError.processCheck("second process acquired an active owner journal")
        }

        owner = nil
        let successor = try SQLiteOperationJournal(url: journal)
        let successorEpoch = try require(successor.ownerEpoch, "successor epoch")
        guard successorEpoch != firstEpoch else {
            throw ProbeError.processCheck("successor reused the former owner epoch")
        }
        print(
            "journal-process-self-check PASS first=\(firstEpoch.uuidString.lowercased()) " +
                "successor=\(successorEpoch.uuidString.lowercased())"
        )
    }

    private static func assertNoOpenDescriptor(path: String) throws {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        for descriptor in 0..<1024 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(Int32(descriptor), F_GETPATH, &buffer) == 0 {
                let candidate = String(cString: buffer)
                if URL(fileURLWithPath: candidate).standardizedFileURL.path == canonical {
                    throw ProbeError.processCheck(
                        "descriptor \(descriptor) still references \(canonical)"
                    )
                }
            }
        }
    }

    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw ProbeError.processCheck("missing \(label)") }
        return value
    }
}

private enum ProbeError: Error {
    case usage
    case missingAcknowledgement
    case processCheck(String)
    case realOperation(String)
}
