import Foundation

/// Closed M3 inventory. Adding a destructive effect changes the crash matrix
/// and therefore requires an OpenSpec design update before implementation.
package enum DurableEffectKind: String, Codable, Sendable, CaseIterable {
    case stageCommit
    case backupDestination
    case commitReplacement
    case quarantineSource
    case purgeQuarantineNode
    case purgeQuarantineRoot
    case rollbackCommittedDestination
    case restoreBackup
    case purgeBackup
    case discardStaging
}

package enum DurableEffectResultStatus: String, Codable, Sendable {
    case completed
    case notPerformed
    case ambiguous
}

/// Immutable write-ahead description for exactly one filesystem mutation.
/// Identity blobs are versioned adapter evidence; paths alone never authorize
/// a retry, cleanup, or deletion.
package struct DurableEffectIntent: Codable, Sendable, Equatable {
    package let effectID: UUID
    package let operationID: OperationID
    package let itemID: OperationItemID
    package let attemptID: UUID?
    package let actionID: UUID?
    package let ownerEpoch: UUID
    package let effectOrdinal: UInt64
    package let kind: DurableEffectKind
    package let nodeID: String?
    package let relativePath: String?
    package let expectedIdentity: Data
    package let manifestDigest: String?
    package let intentSequence: EventSequence

    package init(
        effectID: UUID,
        operationID: OperationID,
        itemID: OperationItemID,
        attemptID: UUID? = nil,
        actionID: UUID? = nil,
        ownerEpoch: UUID,
        effectOrdinal: UInt64,
        kind: DurableEffectKind,
        nodeID: String? = nil,
        relativePath: String? = nil,
        expectedIdentity: Data,
        manifestDigest: String? = nil,
        intentSequence: EventSequence
    ) {
        self.effectID = effectID
        self.operationID = operationID
        self.itemID = itemID
        self.attemptID = attemptID
        self.actionID = actionID
        self.ownerEpoch = ownerEpoch
        self.effectOrdinal = effectOrdinal
        self.kind = kind
        self.nodeID = nodeID
        self.relativePath = relativePath
        self.expectedIdentity = expectedIdentity
        self.manifestDigest = manifestDigest
        self.intentSequence = intentSequence
    }
}

/// Immutable outcome appended after the filesystem call returns. A missing
/// result means the crash window is unresolved and must be inspected.
package struct DurableEffectResultRecord: Codable, Sendable, Equatable {
    package let operationID: OperationID
    package let itemID: OperationItemID
    package let effectID: UUID
    package let status: DurableEffectResultStatus
    package let resultIdentity: Data?
    package let systemCode: Int32?
    package let evidence: Data
    package let resultSequence: EventSequence

    package init(
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID,
        status: DurableEffectResultStatus,
        resultIdentity: Data?,
        systemCode: Int32?,
        evidence: Data,
        resultSequence: EventSequence
    ) {
        self.operationID = operationID
        self.itemID = itemID
        self.effectID = effectID
        self.status = status
        self.resultIdentity = resultIdentity
        self.systemCode = systemCode
        self.evidence = evidence
        self.resultSequence = resultSequence
    }
}

package struct DurableEffectRecord: Sendable, Equatable {
    package let intent: DurableEffectIntent
    package let result: DurableEffectResultRecord?
}

package struct DurableEffectPreparation: Sendable, Equatable {
    package let kind: DurableEffectKind
    package let nodeID: String?
    package let relativePath: String?
    package let expectedIdentity: Data
    package let manifestDigest: String?

    package init(
        kind: DurableEffectKind,
        nodeID: String? = nil,
        relativePath: String? = nil,
        expectedIdentity: Data,
        manifestDigest: String? = nil
    ) {
        self.kind = kind
        self.nodeID = nodeID
        self.relativePath = relativePath
        self.expectedIdentity = expectedIdentity
        self.manifestDigest = manifestDigest
    }
}

package struct CrashScenarioContext: Sendable, Equatable {
    package let scenarioID: String
    package let runNonce: UUID
    package let syscallCounterURL: URL?

    package init(
        scenarioID: String,
        runNonce: UUID,
        syscallCounterURL: URL? = nil
    ) {
        self.scenarioID = scenarioID
        self.runNonce = runNonce
        self.syscallCounterURL = syscallCounterURL
    }
}

package enum CrashAcknowledgementWindow: String, Codable, Sendable, CaseIterable {
    case intentDurableBeforeEffect
    case effectReturnedBeforeResult
    case resultDurableBeforeNextEffect
}

/// Test-only control message. It is emitted only after the corresponding
/// journal boundary described by `window`; it is not an operation event and
/// never acts as durability evidence by itself.
package struct CrashAcknowledgement: Codable, Sendable, Equatable {
    package let scenarioID: String
    package let runNonce: UUID
    package let operationID: OperationID
    package let itemID: OperationItemID
    package let effectID: UUID
    package let kind: DurableEffectKind
    package let effectOrdinal: UInt64
    package let window: CrashAcknowledgementWindow
    package let ownerEpoch: UUID
    package let journalSequence: EventSequence
    package let nodeID: String?
    package let relativePath: String?
    package let manifestDigest: String?

    package init(
        scenarioID: String,
        runNonce: UUID,
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID,
        kind: DurableEffectKind,
        effectOrdinal: UInt64,
        window: CrashAcknowledgementWindow,
        ownerEpoch: UUID,
        journalSequence: EventSequence,
        nodeID: String? = nil,
        relativePath: String? = nil,
        manifestDigest: String? = nil
    ) {
        self.scenarioID = scenarioID
        self.runNonce = runNonce
        self.operationID = operationID
        self.itemID = itemID
        self.effectID = effectID
        self.kind = kind
        self.effectOrdinal = effectOrdinal
        self.window = window
        self.ownerEpoch = ownerEpoch
        self.journalSequence = journalSequence
        self.nodeID = nodeID
        self.relativePath = relativePath
        self.manifestDigest = manifestDigest
    }
}

package enum DurableEffectExecutionOutcome: Sendable {
    case completed(identity: Data, evidence: Data)
    case notPerformed(evidence: Data)
    case ambiguous(FileOperationFailure, evidence: Data)

    package var status: DurableEffectResultStatus {
        switch self {
        case .completed: return .completed
        case .notPerformed: return .notPerformed
        case .ambiguous: return .ambiguous
        }
    }

    package var identity: Data? {
        guard case let .completed(identity, _) = self else { return nil }
        return identity
    }

    package var evidence: Data {
        switch self {
        case let .completed(_, evidence), let .notPerformed(evidence),
             let .ambiguous(_, evidence):
            return evidence
        }
    }

    package var failure: FileOperationFailure? {
        guard case let .ambiguous(failure, _) = self else { return nil }
        return failure
    }
}

/// The service actor invokes one effect at a time after its intent is durable.
/// Implementations own filesystem syscalls only; they never own SQLite.
package protocol DurableEffectExecutor: OperationExecutor {
    func manifestNodes(for context: ExecutionContext) async throws -> [DurableManifestNode]
    func prepareEffects(
        for phase: ExecutionPhase,
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async throws -> [DurableEffectPreparation]
    /// Reconstructs a recovery mutation exclusively from durable facts supplied
    /// by the service. A restarted owner cannot rely on planning registries.
    func prepareRecoveryEffects(
        for action: RecoveryAction,
        context: ExecutionContext,
        receipt: OperationReceiptSummary?,
        records: [DurableEffectRecord],
        manifest: [DurableManifestNode]
    ) async throws -> [DurableEffectPreparation]
    /// Proves that retaining a cleanup-pending source is safe using only
    /// journaled identities and manifests. This is deliberately separate from
    /// the process-local inspection seam because recovery may run after a
    /// different owner has restarted the service.
    func inspectSourceForRetention(
        context: ExecutionContext,
        receipt: OperationReceiptSummary,
        records: [DurableEffectRecord],
        manifest: [DurableManifestNode]
    ) async -> ExecutionSourceInspection
    func perform(_ intent: DurableEffectIntent) async -> DurableEffectExecutionOutcome
    func inspect(_ intent: DurableEffectIntent) async -> DurableEffectExecutionOutcome
    func summaryReceipt(
        for phase: ExecutionPhase,
        completed records: [DurableEffectRecord],
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async -> OperationReceiptSummary?
    func outcome(
        for phase: ExecutionPhase,
        completed records: [DurableEffectRecord],
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async -> ExecutionPhaseOutcome
}

package extension DurableEffectExecutor {
    func inspectSourceForRetention(
        context: ExecutionContext,
        receipt: OperationReceiptSummary,
        records: [DurableEffectRecord],
        manifest: [DurableManifestNode]
    ) async -> ExecutionSourceInspection {
        _ = receipt
        _ = records
        _ = manifest
        return .unknown(FileOperationFailure(
            code: .recoveryRequired,
            operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "durable source-retention inspection is unavailable",
            retryable: false
        ))
    }

    func prepareRecoveryEffects(
        for action: RecoveryAction,
        context: ExecutionContext,
        receipt: OperationReceiptSummary?,
        records: [DurableEffectRecord],
        manifest: [DurableManifestNode]
    ) async throws -> [DurableEffectPreparation] {
        _ = action
        _ = receipt
        _ = records
        _ = manifest
        throw FileOperationFailure(
            code: .featureDisabled,
            operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "durable recovery preparation is unavailable",
            retryable: false
        )
    }
}
