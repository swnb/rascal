import Foundation

package struct JournalRetentionResult: Sendable, Equatable {
    package let deletedOperationIDs: [OperationID]
}

package struct DurableEffectRegistration: Sendable {
    package let intents: [DurableEffectIntent]
    package let operation: JournalOperation
}

package struct DurableManifestNode: Codable, Sendable, Equatable {
    package let nodeID: String
    package let parentNodeID: String?
    package let relativePath: String
    package let depth: Int
    package let kind: NativeNodeKind
    package let identity: Data
    package let digest: String?
    package let purgeOrdinal: UInt64

    package init(
        nodeID: String,
        parentNodeID: String?,
        relativePath: String,
        depth: Int,
        kind: NativeNodeKind,
        identity: Data,
        digest: String?,
        purgeOrdinal: UInt64
    ) {
        self.nodeID = nodeID
        self.parentNodeID = parentNodeID
        self.relativePath = relativePath
        self.depth = depth
        self.kind = kind
        self.identity = identity
        self.digest = digest
        self.purgeOrdinal = purgeOrdinal
    }
}

/// M3-only extension of the frozen M1 journal seam. All methods are
/// synchronous because FileOperationService is the sole connection owner and
/// must never suspend while a SQLite transaction or statement is active.
package protocol DurableEffectJournal: OperationJournal {
    var ownerEpoch: UUID? { get }
    var sqliteRuntimeVersion: String? { get }

    func appendEffectIntent(
        _ intent: DurableEffectIntent,
        checkpoint operation: JournalOperation
    ) throws
    /// Atomically freezes the manifest and the complete mutation inventory.
    /// No filesystem effect is authorized until this transaction succeeds.
    func registerEffectPreparations(
        operationID: OperationID,
        itemID: OperationItemID,
        preparations: [DurableEffectPreparation],
        manifest: [DurableManifestNode],
        checkpoint operation: JournalOperation
    ) throws -> DurableEffectRegistration
    func appendEffectResult(
        _ result: DurableEffectResultRecord,
        checkpoint operation: JournalOperation,
        summaryReceipt: OperationReceiptSummary?
    ) throws
    func effectRecords(operationID: OperationID) throws -> [DurableEffectRecord]
    func replaceManifest(
        operationID: OperationID,
        itemID: OperationItemID,
        nodes: [DurableManifestNode]
    ) throws
    func manifest(
        operationID: OperationID,
        itemID: OperationItemID
    ) throws -> [DurableManifestNode]
    func recoveryActionIsAuthorized(
        operationID: OperationID,
        action: RecoveryAction
    ) throws -> Bool
    func applyRetention(now: Date) throws -> JournalRetentionResult
    func clearSafeTerminalOperations(now: Date) throws -> JournalRetentionResult
}
