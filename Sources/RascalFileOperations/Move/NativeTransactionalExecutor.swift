import Foundation
import Darwin

private struct NativeEffectPayload: Codable {
    let from: URL?
    let to: URL?
    let target: URL?
    let expectedObject: NativeStableObjectIdentity
    let expectedFromParent: NativeStableObjectIdentity?
    let expectedToParent: NativeStableObjectIdentity?
    /// Optional frozen tree carried by a rename intent when a later recovery
    /// action must delete the renamed object leaf-to-root after restart.
    let embeddedManifest: [DurableManifestNode]?
    /// Distinguishes a move's original source from an operation-owned staging
    /// path without relying on URL spelling (`/tmp` versus `/private/tmp`).
    let sourceRole: String?

    init(
        from: URL?,
        to: URL?,
        target: URL?,
        expectedObject: NativeStableObjectIdentity,
        expectedFromParent: NativeStableObjectIdentity?,
        expectedToParent: NativeStableObjectIdentity?,
        embeddedManifest: [DurableManifestNode]? = nil,
        sourceRole: String? = nil
    ) {
        self.from = from
        self.to = to
        self.target = target
        self.expectedObject = expectedObject
        self.expectedFromParent = expectedFromParent
        self.expectedToParent = expectedToParent
        self.embeddedManifest = embeddedManifest
        self.sourceRole = sourceRole
    }
}

private struct NativeManifestIdentityEvidence: Codable {
    let source: NativeStableObjectIdentity
    let staging: NativeStableObjectIdentity?
    let sourceParent: NativeStableObjectIdentity?
}

package final class NativeTransactionalExecutor: @unchecked Sendable, DurableEffectExecutor {
    private struct ItemState: Sendable {
        let workspace: NativeTransactionalWorkspace.Item
        let copyContext: ExecutionContext?
        let manifest: NativeTreeManifest
        let manifestNodes: [DurableManifestNode]
        let destinationManifestNodes: [DurableManifestNode]
        let backupURL: URL?
        let quarantineURL: URL?
    }

    private struct PurgePreflightState: Sendable {
        let quarantineURL: URL
        var nodes: [DurableManifestNode]
        let rootParentIdentity: NativeStableObjectIdentity
        var validated: Bool
    }

    private let workspace: NativeTransactionalWorkspace
    private let copyExecutor: NativeCopyExecutor
    private let lock = NSLock()
    private let crashSyscallCounterURL: URL?
    private var states: [NativeCopyWorkspaceRegistry.Key: ItemState] = [:]
    private var purgePreflights: [
        NativeCopyWorkspaceRegistry.Key: PurgePreflightState
    ] = [:]
    /// The first source-cleanup pass freezes and registers quarantine before
    /// mutation. A later pass in the same executor reuses that exact
    /// preparation after the source has moved; it must not reconstruct a new
    /// authorization from two absent/live paths.
    private var quarantinePreparations: [
        NativeCopyWorkspaceRegistry.Key: DurableEffectPreparation
    ] = [:]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    package init(
        workspace: NativeTransactionalWorkspace,
        faults: NativeCopyFaultController = NativeCopyFaultController(),
        crashSyscallCounterURL: URL? = nil
    ) {
        self.workspace = workspace
        self.crashSyscallCounterURL = crashSyscallCounterURL
        copyExecutor = NativeCopyExecutor(
            registry: workspace.copyRegistry,
            faults: faults
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    package func plan(
        _ context: ExecutionContext,
        controls: ExecutionControls
    ) async throws -> ExecutionPlan {
        guard let item = workspace.item(
            operationID: context.operationID,
            itemID: context.itemID
        ) else {
            throw FileOperationFailure(
                code: .invariantViolation,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "transactional executor is missing preflight state",
                retryable: false
            )
        }
        guard try NativePathInspector.identity(at: item.source) == item.sourceIdentity,
              try NativePathInspector.stableIdentity(
                at: item.source.deletingLastPathComponent()
              ) == item.sourceParentIdentity else {
            throw failure(
                context,
                code: .sourceChanged,
                diagnostic: "source or source parent changed after preflight"
            )
        }
        guard try NativePathInspector.stableIdentity(
            at: item.destination.deletingLastPathComponent()
        ) == item.destinationParentIdentity else {
            throw failure(
                context,
                code: .destinationChanged,
                diagnostic: "destination parent changed after preflight"
            )
        }
        let currentDestination: NativeCompositeIdentity?
        do {
            currentDestination = try NativePathInspector.identity(at: item.destination)
        } catch let native as NativeFileError where native.systemCode == ENOENT {
            currentDestination = nil
        }
        guard currentDestination == item.destinationIdentity else {
            throw failure(
                context,
                code: .destinationChanged,
                diagnostic: "destination identity changed after preflight"
            )
        }

        let includeDigests = context.verificationPolicy == .sha256 ||
            item.mode == .crossVolumeMove || item.mode == .moveReplace ||
            item.mode == .standaloneReplace
        let manifest = try NativeTreeManifest.capture(
            root: item.source,
            includeContentDigests: includeDigests
        )
        let nodes = try makeManifestNodes(root: item.source, manifest: manifest)
        let destinationNodes: [DurableManifestNode]
        if item.destinationIdentity != nil {
            let destinationManifest = try NativeTreeManifest.capture(
                root: item.destination,
                includeContentDigests: true
            )
            destinationNodes = try makeManifestNodes(
                root: item.destination,
                manifest: destinationManifest
            )
        } else {
            destinationNodes = []
        }
        let backup = [.standaloneReplace, .moveReplace].contains(item.mode)
            ? recoveryURL(
                parent: item.destination.deletingLastPathComponent(),
                prefix: "backup",
                context: context
            )
            : nil
        let quarantine = [.crossVolumeMove, .moveReplace].contains(item.mode)
            ? recoveryURL(
                parent: item.source.deletingLastPathComponent(),
                prefix: "quarantine",
                context: context
            )
            : nil
        if let backup, lstatExists(backup) {
            throw failure(
                context,
                code: .recoveryRequired,
                diagnostic: "replace backup path already exists"
            )
        }
        if let quarantine, lstatExists(quarantine) {
            throw failure(
                context,
                code: .recoveryRequired,
                diagnostic: "move quarantine path already exists"
            )
        }

        let copyContext: ExecutionContext?
        if item.mode == .sameVolumeMove {
            copyContext = nil
        } else {
            let copy = context.replacingRequestForTransactionalCopy()
            _ = try await copyExecutor.plan(copy, controls: controls)
            copyContext = copy
        }
        let key = key(context)
        lock.withLock {
            states[key] = ItemState(
                workspace: item,
                copyContext: copyContext,
                manifest: manifest,
                manifestNodes: nodes,
                destinationManifestNodes: destinationNodes,
                backupURL: backup,
                quarantineURL: quarantine
            )
        }
        let cleanup = [.crossVolumeMove, .moveReplace].contains(item.mode)
        return ExecutionPlan(
            sourceDisposition: cleanup ? .cleanupRequired : .noCleanup
        )
    }

    package func perform(
        _ phase: ExecutionPhase,
        context: ExecutionContext,
        plan: ExecutionPlan,
        controls: ExecutionControls,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async -> ExecutionPhaseOutcome {
        guard let state = state(context) else {
            return .failed(failure(
                context,
                code: .invariantViolation,
                diagnostic: "transactional execution state is unavailable"
            ))
        }
        if phase == .commit || phase == .sourceCleanup {
            return .failed(failure(
                context,
                code: .invariantViolation,
                diagnostic: "destructive phase bypassed durable effect protocol"
            ))
        }
        guard let copyContext = state.copyContext else {
            switch phase {
            case .staging:
                return .staged
            case .metadata:
                return .metadataApplied(MetadataOutcome(
                    preserved: Set(MetadataField.allCases),
                    degraded: [],
                    unknown: []
                ))
            case .verification:
                do {
                    let current = try NativeTreeManifest.capture(
                        root: state.workspace.source,
                        includeContentDigests: context.verificationPolicy == .sha256
                    )
                    guard state.manifest.firstMismatch(
                        against: current,
                        policy: context.verificationPolicy
                    ) == nil else {
                        return .failed(failure(
                            context,
                            code: .sourceChanged,
                            diagnostic: "same-volume move source changed before commit"
                        ))
                    }
                    return .verified(VerificationOutcome(
                        policy: context.verificationPolicy,
                        sourceDigest: context.verificationPolicy == .sha256
                            ? current.digest : nil,
                        stagedDigest: context.verificationPolicy == .sha256
                            ? current.digest : nil,
                        manifestDigest: current.digest
                    ))
                } catch {
                    return .failed(failure(
                        context,
                        code: .sourceChanged,
                        diagnostic: String(describing: error)
                    ))
                }
            case .commit, .sourceCleanup:
                fatalError("handled above")
            }
        }
        return await copyExecutor.perform(
            phase,
            context: copyContext,
            plan: plan,
            controls: controls,
            progress: progress
        )
    }

    package func manifestNodes(
        for context: ExecutionContext
    ) async throws -> [DurableManifestNode] {
        guard let state = state(context) else {
            throw failure(
                context,
                code: .invariantViolation,
                diagnostic: "manifest requested before transactional planning"
            )
        }
        let record = workspace.copyRegistry.record(for: key(context))
        return try state.manifestNodes.map { node in
            let source = try decoder.decode(
                NativeStableObjectIdentity.self,
                from: node.identity
            )
            return DurableManifestNode(
                nodeID: node.nodeID,
                parentNodeID: node.parentNodeID,
                relativePath: node.relativePath,
                depth: node.depth,
                kind: node.kind,
                identity: try encoder.encode(NativeManifestIdentityEvidence(
                    source: source,
                    staging: record?.ownedNodes[node.relativePath],
                    sourceParent: node.relativePath == "."
                        ? state.workspace.sourceParentIdentity : nil
                )),
                digest: node.digest,
                purgeOrdinal: node.purgeOrdinal
            )
        }
    }

    package func prepareEffects(
        for phase: ExecutionPhase,
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async throws -> [DurableEffectPreparation] {
        _ = plan
        guard let state = state(context) else {
            throw failure(
                context,
                code: .invariantViolation,
                diagnostic: "durable effects requested before planning"
            )
        }
        switch phase {
        case .commit:
            switch state.workspace.mode {
            case .sameVolumeMove:
                return [try renamePreparation(
                    kind: .stageCommit,
                    from: state.workspace.source,
                    to: state.workspace.destination,
                    expectedObject: stableIdentity(state.workspace.sourceIdentity),
                    expectedFromParent: state.workspace.sourceParentIdentity,
                    expectedToParent: state.workspace.destinationParentIdentity,
                    sourceRole: "source",
                    manifestDigest: state.manifest.digest
                )]
            case .crossVolumeMove:
                let staging = try stagingEvidence(state, context: context)
                return [try renamePreparation(
                    kind: .stageCommit,
                    from: staging.url,
                    to: state.workspace.destination,
                    expectedObject: staging.identity,
                    expectedFromParent: staging.parentIdentity,
                    expectedToParent: state.workspace.destinationParentIdentity,
                    sourceRole: "staging",
                    manifestDigest: state.manifest.digest
                )]
            case .standaloneReplace, .moveReplace:
                let backup = try required(state.backupURL, context, "backup")
                let destinationIdentity = try required(
                    state.workspace.destinationIdentity,
                    context,
                    "frozen replacement destination identity"
                )
                let staging = try stagingEvidence(state, context: context)
                return [
                    try renamePreparation(
                        kind: .backupDestination,
                        from: state.workspace.destination,
                        to: backup,
                        expectedObject: stableIdentity(destinationIdentity),
                        expectedFromParent: state.workspace.destinationParentIdentity,
                        expectedToParent: state.workspace.destinationParentIdentity,
                        manifestDigest: nil,
                        embeddedManifest: state.destinationManifestNodes
                    ),
                    try renamePreparation(
                        kind: .commitReplacement,
                        from: staging.url,
                        to: state.workspace.destination,
                        expectedObject: staging.identity,
                        expectedFromParent: staging.parentIdentity,
                        expectedToParent: state.workspace.destinationParentIdentity,
                        expectedRegistrationDestination: stableIdentity(
                            destinationIdentity
                        ),
                        sourceRole: "staging",
                        manifestDigest: state.manifest.digest
                    ),
                ]
            }
        case .sourceCleanup:
            let quarantine = try required(state.quarantineURL, context, "quarantine")
            let frozenSource = stableIdentity(state.workspace.sourceIdentity)
            let stateKey = key(context)
            let quarantinePreparation: DurableEffectPreparation
            if let frozen = lock.withLock({
                quarantinePreparations[stateKey]
            }) {
                quarantinePreparation = frozen
            } else {
                let prepared = try renamePreparation(
                    kind: .quarantineSource,
                    from: state.workspace.source,
                    to: quarantine,
                    expectedObject: frozenSource,
                    expectedFromParent: state.workspace.sourceParentIdentity,
                    expectedToParent: state.workspace.sourceParentIdentity,
                    manifestDigest: state.manifest.digest
                )
                lock.withLock {
                    quarantinePreparations[stateKey] = prepared
                }
                quarantinePreparation = prepared
            }
            let quarantinePayload = try decoder.decode(
                NativeEffectPayload.self,
                from: quarantinePreparation.expectedIdentity
            )
            let rootParent = try required(
                quarantinePayload.expectedToParent,
                context,
                "quarantine parent identity"
            )
            registerPurgePreflight(
                context: context,
                quarantine: quarantine,
                nodes: state.manifestNodes,
                rootParent: rootParent
            )
            var effects = [quarantinePreparation]
            for node in state.manifestNodes where node.relativePath != "." {
                let target = quarantine.appendingPathComponent(
                    node.relativePath,
                    isDirectory: node.kind == .directory
                )
                let payload = try purgePayload(
                    target: target,
                    node: node,
                    manifest: state.manifestNodes,
                    rootParent: rootParent
                )
                effects.append(DurableEffectPreparation(
                    kind: .purgeQuarantineNode,
                    nodeID: node.nodeID,
                    relativePath: node.relativePath,
                    expectedIdentity: try encoder.encode(payload),
                    manifestDigest: state.manifest.digest
                ))
            }
            guard let root = state.manifestNodes.first(where: { $0.relativePath == "." }) else {
                throw failure(
                    context,
                    code: .invariantViolation,
                    diagnostic: "source manifest has no root node"
                )
            }
            effects.append(DurableEffectPreparation(
                kind: .purgeQuarantineRoot,
                expectedIdentity: try encoder.encode(
                    purgePayload(
                        target: quarantine,
                        node: root,
                        manifest: state.manifestNodes,
                        rootParent: rootParent
                    )
                ),
                manifestDigest: state.manifest.digest
            ))
            return effects
        default:
            return []
        }
    }

    package func prepareRecoveryEffects(
        for action: RecoveryAction,
        context: ExecutionContext,
        receipt: OperationReceiptSummary?,
        records: [DurableEffectRecord],
        manifest: [DurableManifestNode]
    ) async throws -> [DurableEffectPreparation] {
        let itemRecords = records.filter { $0.intent.itemID == context.itemID }
        func preparation(_ record: DurableEffectRecord) -> DurableEffectPreparation {
            DurableEffectPreparation(
                kind: record.intent.kind,
                nodeID: record.intent.nodeID,
                relativePath: record.intent.relativePath,
                expectedIdentity: record.intent.expectedIdentity,
                manifestDigest: record.intent.manifestDigest
            )
        }

        func completedPayload(_ kind: DurableEffectKind) throws -> NativeEffectPayload {
            guard let record = itemRecords.last(where: {
                $0.intent.kind == kind && $0.result?.status == .completed
            }) else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "durable \(kind.rawValue) result is unavailable"
                )
            }
            return try decoder.decode(
                NativeEffectPayload.self,
                from: record.intent.expectedIdentity
            )
        }

        func verify(_ url: URL, equals expected: NativeStableObjectIdentity,
                    label: String) throws {
            guard try NativePathInspector.stableIdentity(at: url) == expected else {
                throw failure(
                    context,
                    code: .sourceChanged,
                    diagnostic: "\(label) identity changed before recovery"
                )
            }
        }

        switch action {
        case .finalizeKnownCommit:
            let backup = try completedPayload(.backupDestination)
            let commit = try completedPayload(.commitReplacement)
            let backupURL = try required(backup.to, context, "backup URL")
            let finalURL = try required(commit.to, context, "final URL")
            try verify(finalURL, equals: commit.expectedObject, label: "final")
            try verify(backupURL, equals: backup.expectedObject, label: "backup")
            guard let expectedFinalDigest = itemRecords.last(where: {
                $0.intent.kind == .commitReplacement &&
                    $0.result?.status == .completed
            })?.intent.manifestDigest else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "finalize lacks a frozen final manifest digest"
                )
            }
            let currentFinal = try NativeTreeManifest.capture(
                root: finalURL,
                includeContentDigests: true
            )
            guard currentFinal.digest == expectedFinalDigest else {
                throw failure(
                    context,
                    code: .sourceChanged,
                    diagnostic: "final content or metadata changed before backup purge"
                )
            }
            guard let backupManifest = backup.embeddedManifest,
                  !backupManifest.isEmpty,
                  let root = backupManifest.first(where: {
                      $0.relativePath == "."
                  }),
                  try sourceIdentity(from: root.identity) == backup.expectedObject else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "backup purge lacks a complete frozen tree manifest"
                )
            }
            let rootParent = try required(
                backup.expectedToParent,
                context,
                "backup parent identity"
            )
            let existing = itemRecords.filter {
                $0.intent.kind == .purgeBackup
            }
            var existingByNode: [String: DurableEffectRecord] = [:]
            for record in existing {
                if let nodeID = record.intent.nodeID {
                    existingByNode[nodeID] = record
                }
            }
            let completedNodeIDs = Set(existing.compactMap { record -> String? in
                record.result?.status == .completed ? record.intent.nodeID : nil
            })
            registerPurgePreflight(
                context: context,
                quarantine: backupURL,
                nodes: backupManifest.filter {
                    !completedNodeIDs.contains($0.nodeID)
                },
                rootParent: rootParent
            )
            return try backupManifest
                .sorted { $0.purgeOrdinal < $1.purgeOrdinal }
                .map { node in
                    if let frozen = existingByNode[node.nodeID] {
                        return preparation(frozen)
                    }
                    let target = node.relativePath == "."
                        ? backupURL
                        : backupURL.appendingPathComponent(
                            node.relativePath,
                            isDirectory: node.kind == .directory
                        )
                    return DurableEffectPreparation(
                        kind: .purgeBackup,
                        nodeID: node.nodeID,
                        relativePath: node.relativePath,
                        expectedIdentity: try encoder.encode(
                            purgePayload(
                                target: target,
                                node: node,
                                manifest: backupManifest,
                                rootParent: rootParent
                            )
                        ),
                        manifestDigest: expectedFinalDigest
                    )
                }

        case .restoreBackup:
            let backup = try completedPayload(.backupDestination)
            let commit = try completedPayload(.commitReplacement)
            let backupURL = try required(backup.to, context, "backup URL")
            let finalURL = try required(commit.to, context, "final URL")
            let existingRecovery = itemRecords
                .filter {
                    [.rollbackCommittedDestination, .restoreBackup]
                        .contains($0.intent.kind)
                }
                .sorted { $0.intent.effectOrdinal < $1.intent.effectOrdinal }
            if existingRecovery.contains(where: { $0.intent.kind == .restoreBackup }) {
                return existingRecovery.map(preparation)
            }
            if existingRecovery.isEmpty {
                try verify(finalURL, equals: commit.expectedObject, label: "final")
            }
            try verify(backupURL, equals: backup.expectedObject, label: "backup")
            let rollbackURL = recoveryURL(
                parent: finalURL.deletingLastPathComponent(),
                prefix: "replacement",
                context: context
            )
            guard !lstatExists(rollbackURL) || !existingRecovery.isEmpty else {
                throw failure(
                    context,
                    code: .destinationChanged,
                    diagnostic: "replacement recovery area is not absent"
                )
            }
            var preparations = existingRecovery.map(preparation)
            if preparations.isEmpty {
                preparations.append(try renamePreparation(
                    kind: .rollbackCommittedDestination,
                    from: finalURL,
                    to: rollbackURL,
                    expectedObject: commit.expectedObject,
                    expectedFromParent: try required(
                        commit.expectedToParent,
                        context,
                        "committed destination parent identity"
                    ),
                    expectedToParent: try required(
                        commit.expectedToParent,
                        context,
                        "replacement recovery parent identity"
                    ),
                    manifestDigest: commitPayloadManifestDigest(itemRecords)
                ))
            }
            preparations.append(try renamePreparation(
                    kind: .restoreBackup,
                    from: backupURL,
                    to: finalURL,
                    expectedObject: backup.expectedObject,
                    expectedFromParent: try required(
                        backup.expectedToParent,
                        context,
                        "backup parent identity"
                    ),
                    expectedToParent: try required(
                        commit.expectedToParent,
                        context,
                        "final parent identity"
                    ),
                    expectedRegistrationDestination: commit.expectedObject,
                    registrationDestinationMayBeAbsent: !existingRecovery.isEmpty,
                    manifestDigest: nil
                ))
            return preparations

        case .rollbackCommittedDestination:
            if let existing = itemRecords.last(where: {
                $0.intent.kind == .rollbackCommittedDestination
            }) {
                return [preparation(existing)]
            }
            let commit = try completedPayload(
                itemRecords.contains(where: { $0.intent.kind == .commitReplacement })
                    ? .commitReplacement : .stageCommit
            )
            let finalURL = try required(commit.to, context, "committed destination")
            try verify(finalURL, equals: commit.expectedObject, label: "destination")
            let target = lstatExists(context.source)
                ? recoveryURL(
                    parent: finalURL.deletingLastPathComponent(),
                    prefix: "rollback",
                    context: context
                )
                : context.source
            let targetParent = target == context.source
                ? try required(
                    commit.expectedFromParent,
                    context,
                    "original source parent identity"
                )
                : try required(
                    commit.expectedToParent,
                    context,
                    "rollback recovery parent identity"
                )
            guard !lstatExists(target) else {
                throw failure(
                    context,
                    code: .destinationChanged,
                    diagnostic: "rollback destination is not absent"
                )
            }
            return [try renamePreparation(
                kind: .rollbackCommittedDestination,
                from: finalURL,
                to: target,
                expectedObject: commit.expectedObject,
                expectedFromParent: try required(
                    commit.expectedToParent,
                    context,
                    "committed destination parent identity"
                ),
                expectedToParent: targetParent,
                manifestDigest: commitPayloadManifestDigest(itemRecords)
            )]

        case .discardKnownStaging:
            guard let stage = itemRecords.last(where: {
                [.stageCommit, .commitReplacement].contains($0.intent.kind) &&
                    ($0.result == nil || $0.result?.status == .notPerformed)
            }) else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "known staging has no durable commit intent"
                )
            }
            let payload = try decoder.decode(
                NativeEffectPayload.self,
                from: stage.intent.expectedIdentity
            )
            let staging = try required(payload.from, context, "staging URL")
            try verify(staging, equals: payload.expectedObject, label: "staging")
            let rootParent = try required(
                payload.expectedFromParent,
                context,
                "staging parent identity"
            )
            let ordered = manifest.sorted {
                $0.purgeOrdinal < $1.purgeOrdinal
            }
            guard !ordered.isEmpty else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "known staging lacks a frozen node manifest"
                )
            }
            let byID = Dictionary(
                uniqueKeysWithValues: ordered.map { ($0.nodeID, $0) }
            )
            let stagingNodes = try ordered.map { node in
                DurableManifestNode(
                    nodeID: node.nodeID,
                    parentNodeID: node.parentNodeID,
                    relativePath: node.relativePath,
                    depth: node.depth,
                    kind: node.kind,
                    identity: try encoder.encode(stagingIdentity(from: node.identity)),
                    digest: node.digest,
                    purgeOrdinal: node.purgeOrdinal
                )
            }
            let existing = itemRecords.filter {
                $0.intent.kind == .discardStaging
            }
            let completedNodeIDs = Set(existing.compactMap {
                $0.result?.status == .completed ? $0.intent.nodeID : nil
            })
            registerPurgePreflight(
                context: context,
                quarantine: staging,
                nodes: stagingNodes.filter {
                    !completedNodeIDs.contains($0.nodeID)
                },
                rootParent: rootParent
            )
            return try ordered.map { node in
                if let frozen = existing.last(where: {
                    $0.intent.nodeID == node.nodeID &&
                        $0.intent.relativePath == node.relativePath
                }) {
                    return preparation(frozen)
                }
                let target = node.relativePath == "."
                    ? staging
                    : staging.appendingPathComponent(
                        node.relativePath,
                        isDirectory: node.kind == .directory
                    )
                let expectedParent: NativeStableObjectIdentity
                if let parentNodeID = node.parentNodeID,
                   let parent = byID[parentNodeID] {
                    expectedParent = try stagingIdentity(from: parent.identity)
                } else {
                    expectedParent = rootParent
                }
                return DurableEffectPreparation(
                    kind: .discardStaging,
                    nodeID: node.nodeID,
                    relativePath: node.relativePath,
                    expectedIdentity: try encoder.encode(NativeEffectPayload(
                        from: nil,
                        to: nil,
                        target: target,
                        expectedObject: try stagingIdentity(from: node.identity),
                        expectedFromParent: nil,
                        expectedToParent: expectedParent
                    )),
                    manifestDigest: stage.intent.manifestDigest
                )
            }

        case .retrySourceCleanup:
            guard let receipt, let quarantine = receipt.quarantineURL,
                  let root = manifest.first(where: { $0.relativePath == "." }) else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "cleanup recovery lacks receipt or frozen root manifest"
                )
            }
            var existing: [String: DurableEffectRecord] = [:]
            for record in itemRecords where [
                .quarantineSource,
                .purgeQuarantineNode,
                .purgeQuarantineRoot,
            ].contains(record.intent.kind) {
                let key = record.intent.kind.rawValue + "|" +
                    (record.intent.nodeID ?? "") + "|" +
                    (record.intent.relativePath ?? "")
                existing[key] = record
            }
            func existingPreparation(
                _ kind: DurableEffectKind,
                nodeID: String? = nil,
                relativePath: String? = nil
            ) -> DurableEffectPreparation? {
                let key = kind.rawValue + "|" + (nodeID ?? "") + "|" +
                    (relativePath ?? "")
                return existing[key].map(preparation)
            }
            let manifestDigest = itemRecords.first(where: {
                [.stageCommit, .commitReplacement].contains($0.intent.kind)
            })?.intent.manifestDigest
            var result: [DurableEffectPreparation] = []
            if let frozen = existingPreparation(.quarantineSource) {
                result.append(frozen)
            } else {
                let expected = try sourceIdentity(from: root.identity)
                result.append(try renamePreparation(
                    kind: .quarantineSource,
                    from: context.source,
                    to: quarantine,
                    expectedObject: expected,
                    expectedFromParent: try sourceParentIdentity(from: root.identity),
                    expectedToParent: try sourceParentIdentity(from: root.identity),
                    manifestDigest: manifestDigest
                ))
            }
            let quarantinePayload = try decoder.decode(
                NativeEffectPayload.self,
                from: result[0].expectedIdentity
            )
            let rootParent = try required(
                quarantinePayload.expectedToParent,
                context,
                "quarantine parent identity"
            )
            let completedNodeIDs = Set(itemRecords.compactMap { record -> String? in
                guard record.intent.kind == .purgeQuarantineNode,
                      record.result?.status == .completed else {
                    return nil
                }
                return record.intent.nodeID
            })
            let rootCompleted = itemRecords.contains {
                $0.intent.kind == .purgeQuarantineRoot &&
                    $0.result?.status == .completed
            }
            let remainingManifest = manifest.filter {
                if $0.relativePath == "." { return !rootCompleted }
                return !completedNodeIDs.contains($0.nodeID)
            }
            registerPurgePreflight(
                context: context,
                quarantine: quarantine,
                nodes: remainingManifest,
                rootParent: rootParent
            )
            for node in manifest
            where node.relativePath != "." {
                if let frozen = existingPreparation(
                    .purgeQuarantineNode,
                    nodeID: node.nodeID,
                    relativePath: node.relativePath
                ) {
                    result.append(frozen)
                } else {
                    let target = quarantine.appendingPathComponent(
                        node.relativePath,
                        isDirectory: node.kind == .directory
                    )
                    result.append(DurableEffectPreparation(
                        kind: .purgeQuarantineNode,
                        nodeID: node.nodeID,
                        relativePath: node.relativePath,
                        expectedIdentity: try encoder.encode(
                            purgePayload(
                                target: target,
                                node: node,
                                manifest: manifest,
                                rootParent: rootParent
                            )
                        ),
                        manifestDigest: manifestDigest
                    ))
                }
            }
            if let frozen = existingPreparation(.purgeQuarantineRoot) {
                result.append(frozen)
            } else {
                result.append(DurableEffectPreparation(
                    kind: .purgeQuarantineRoot,
                    expectedIdentity: try encoder.encode(
                        purgePayload(
                            target: quarantine,
                            node: root,
                            manifest: manifest,
                            rootParent: rootParent
                        )
                    ),
                    manifestDigest: manifestDigest
                ))
            }
            return result

        case .resumeFromVerifiedStage:
            let commitKinds: Set<DurableEffectKind> = [
                .stageCommit, .backupDestination, .commitReplacement,
            ]
            let commitRecords = itemRecords
                .filter {
                    commitKinds.contains($0.intent.kind)
                }
                .sorted { $0.intent.effectOrdinal < $1.intent.effectOrdinal }
            var latestByKind: [DurableEffectKind: DurableEffectRecord] = [:]
            for record in commitRecords {
                latestByKind[record.intent.kind] = record
            }
            let resumable = latestByKind.values.sorted {
                $0.intent.effectOrdinal < $1.intent.effectOrdinal
            }
            guard !resumable.isEmpty,
                  resumable.allSatisfy({
                      $0.result?.status == .completed ||
                          $0.result?.status == .notPerformed
                  }) else {
                throw failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "verified-stage resume lacks a uniquely resolved commit chain"
                )
            }
            // Paths and identities come only from the frozen ledger. Restart
            // recovery must not recreate a staging plan in process memory.
            return resumable.map(preparation)

        case .retainSource:
            throw failure(
                context,
                code: .recoveryRequired,
                diagnostic: "recovery action requires a uniquely reconstructable durable chain"
            )
        }
    }

    package func perform(
        _ intent: DurableEffectIntent
    ) async -> DurableEffectExecutionOutcome {
        do {
            let payload = try decoder.decode(
                NativeEffectPayload.self,
                from: intent.expectedIdentity
            )
            switch intent.kind {
            case .stageCommit, .backupDestination, .commitReplacement,
                 .quarantineSource, .rollbackCommittedDestination,
                 .restoreBackup:
                let from = try required(payload.from, intent, "rename source")
                let to = try required(payload.to, intent, "rename destination")
                try exclusiveRename(
                    from: from,
                    to: to,
                    payload: payload,
                    intent: intent
                )
                let identity = try NativePathInspector.stableIdentity(at: to)
                return .completed(
                    identity: try encoder.encode(identity),
                    evidence: Data("renameatx_np:RENAME_EXCL".utf8)
                )
            case .purgeQuarantineNode, .purgeQuarantineRoot,
                 .purgeBackup, .discardStaging:
                let target = try required(payload.target, intent, "purge target")
                if intent.kind == .purgeQuarantineNode ||
                    intent.kind == .purgeQuarantineRoot ||
                    intent.kind == .purgeBackup ||
                    intent.kind == .discardStaging {
                    try validatePurgePreflightIfNeeded(intent)
                    invalidatePurgePreflight(intent)
                }
                try anchoredUnlink(
                    target: target,
                    payload: payload,
                    intent: intent
                )
                if intent.kind == .purgeQuarantineNode ||
                    intent.kind == .purgeQuarantineRoot ||
                    intent.kind == .purgeBackup ||
                    intent.kind == .discardStaging {
                    advancePurgePreflight(intent)
                }
                return .completed(
                    identity: Data("absent".utf8),
                    evidence: Data("unlinkat:no-follow".utf8)
                )
            }
        } catch let native as NativeFileError {
            return .ambiguous(
                native.failure(
                    operationID: intent.operationID,
                    itemID: intent.itemID
                ),
                evidence: Data(native.message.utf8)
            )
        } catch {
            return .ambiguous(
                FileOperationFailure(
                    code: .recoveryRequired,
                    operationID: intent.operationID,
                    itemID: intent.itemID,
                    diagnostic: String(describing: error),
                    retryable: false
                ),
                evidence: Data(String(describing: error).utf8)
            )
        }
    }

    package func inspect(
        _ intent: DurableEffectIntent
    ) async -> DurableEffectExecutionOutcome {
        do {
            let payload = try decoder.decode(
                NativeEffectPayload.self,
                from: intent.expectedIdentity
            )
            if let from = payload.from, let to = payload.to {
                guard let expectedFromParent = payload.expectedFromParent,
                      let expectedToParent = payload.expectedToParent else {
                    return ambiguousInspection(
                        intent,
                        diagnostic: "rename lacks frozen parent identity"
                    )
                }
                let fromIdentity = try anchoredIdentityIfPresent(
                    at: from,
                    expectedParent: expectedFromParent
                )
                let toIdentity = try anchoredIdentityIfPresent(
                    at: to,
                    expectedParent: expectedToParent
                )
                if fromIdentity == nil, toIdentity == payload.expectedObject {
                    return .completed(
                        identity: try encoder.encode(payload.expectedObject),
                        evidence: Data("rename-inspection:completed".utf8)
                    )
                }
                if fromIdentity == payload.expectedObject, toIdentity == nil {
                    return .notPerformed(evidence: Data("rename-inspection:not-performed".utf8))
                }
            } else if let target = payload.target {
                guard let expectedParent = payload.expectedToParent else {
                    return ambiguousInspection(
                        intent,
                        diagnostic: "unlink lacks frozen parent identity"
                    )
                }
                guard let targetIdentity = try anchoredIdentityIfPresent(
                    at: target,
                    expectedParent: expectedParent
                ) else {
                    return ambiguousInspection(
                        intent,
                        diagnostic: "unlink target absence alone is not completion evidence"
                    )
                }
                if targetIdentity == payload.expectedObject {
                    return .notPerformed(evidence: Data("unlink-inspection:present".utf8))
                }
            }
            return .ambiguous(
                FileOperationFailure(
                    code: .recoveryRequired,
                    operationID: intent.operationID,
                    itemID: intent.itemID,
                    diagnostic: "filesystem identities do not uniquely resolve durable effect",
                    retryable: false
                ),
                evidence: Data("identity-inspection:ambiguous".utf8)
            )
        } catch {
            return .ambiguous(
                FileOperationFailure(
                    code: .recoveryRequired,
                    operationID: intent.operationID,
                    itemID: intent.itemID,
                    diagnostic: String(describing: error),
                    retryable: false
                ),
                evidence: Data(String(describing: error).utf8)
            )
        }
    }

    package func summaryReceipt(
        for phase: ExecutionPhase,
        completed records: [DurableEffectRecord],
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async -> OperationReceiptSummary? {
        guard records.allSatisfy({ $0.result?.status == .completed }) else {
            return nil
        }
        if phase == .commit {
            if let state = state(context) {
                guard committedDestinationMatchesFrozenEffect(
                    records: records,
                    destination: state.workspace.destination
                ) else {
                    return nil
                }
                guard let identity = try? NativePathInspector.identity(
                    at: state.workspace.destination
                ) else { return nil }
                return OperationReceiptSummary(
                    committedIdentityDigest: identity.digest,
                    backupURL: state.backupURL,
                    quarantineURL: state.quarantineURL,
                    sourceCleanupPending: plan.sourceDisposition == .cleanupRequired
                )
            }
            guard let commit = records.last(where: {
                [.stageCommit, .commitReplacement].contains($0.intent.kind)
            }),
            let payload = try? decoder.decode(
                NativeEffectPayload.self,
                from: commit.intent.expectedIdentity
            ),
            let destination = payload.to,
            committedDestinationMatchesFrozenEffect(
                records: records,
                destination: destination
            ),
            let identity = try? NativePathInspector.identity(at: destination)
            else { return nil }
            let backup = records.last(where: {
                $0.intent.kind == .backupDestination &&
                    $0.result?.status == .completed
            }).flatMap {
                try? decoder.decode(
                    NativeEffectPayload.self,
                    from: $0.intent.expectedIdentity
                ).to
            }
            let cleanupRequired = context.request.kind == .move && (
                payload.sourceRole == "staging" ||
                    (
                        payload.sourceRole == nil &&
                            payload.from?.resolvingSymlinksInPath().standardizedFileURL !=
                            context.source.resolvingSymlinksInPath().standardizedFileURL
                    )
            )
            return OperationReceiptSummary(
                committedIdentityDigest: identity.digest,
                backupURL: backup,
                quarantineURL: cleanupRequired
                    ? recoveryURL(
                        parent: context.source.deletingLastPathComponent(),
                        prefix: "quarantine",
                        context: context
                    )
                    : nil,
                sourceCleanupPending: cleanupRequired
            )
        }
        guard let state = state(context) else { return nil }
        guard phase == .sourceCleanup,
              !lstatExists(state.workspace.source),
              state.quarantineURL.map({ !lstatExists($0) }) ?? false,
              destinationMatchesManifest(state),
              let identity = try? NativePathInspector.identity(
                at: state.workspace.destination
              ) else { return nil }
        return OperationReceiptSummary(
            committedIdentityDigest: identity.digest,
            backupURL: state.backupURL,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
    }

    package func outcome(
        for phase: ExecutionPhase,
        completed records: [DurableEffectRecord],
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async -> ExecutionPhaseOutcome {
        guard let receipt = await summaryReceipt(
            for: phase,
            completed: records,
            context: context,
            plan: plan
        ) else {
            return .recoveryRequired(failure(
                context,
                code: .recoveryRequired,
                diagnostic: "durable effect chain lacks a unique receipt"
            ))
        }
        return phase == .sourceCleanup ? .sourceCleaned : .committed(receipt)
    }

    package func recover(
        _ effect: ExecutionRecoveryEffect,
        effectID: UUID,
        context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionRecoveryOutcome {
        _ = effect
        _ = effectID
        _ = context
        _ = receipt
        return .failedBeforeEffect(FileOperationFailure(
            code: .featureDisabled,
            diagnostic: "M3 recovery uses the durable effect executor seam",
            retryable: false
        ))
    }

    package func inspectRecoveryEffect(
        _ effect: ExecutionRecoveryEffect,
        effectID: UUID,
        context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionRecoveryInspection {
        _ = effect
        _ = effectID
        _ = context
        _ = receipt
        return .unknown(FileOperationFailure(
            code: .recoveryRequired,
            diagnostic: "legacy recovery effect cannot inspect M3 durable ledger",
            retryable: false
        ))
    }

    package func inspectCommit(
        _ context: ExecutionContext
    ) async -> ExecutionCommitInspection {
        guard let state = state(context) else {
            return .unknown(failure(
                context,
                code: .recoveryRequired,
                diagnostic: "transactional state is unavailable"
            ))
        }
        if let identity = try? NativePathInspector.identity(
            at: state.workspace.destination
        ) {
            return .committed(OperationReceiptSummary(
                committedIdentityDigest: identity.digest,
                backupURL: state.backupURL,
                quarantineURL: state.quarantineURL,
                sourceCleanupPending: state.quarantineURL != nil
            ))
        }
        return .notCommitted
    }

    package func inspectSourceBeforeCleanup(
        _ context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionSourceInspection {
        _ = receipt
        guard let state = state(context) else {
            return .unknown(failure(
                context,
                code: .recoveryRequired,
                diagnostic: "transactional state is unavailable"
            ))
        }
        do {
            guard let stable = try anchoredIdentityIfPresent(
                at: state.workspace.source,
                expectedParent: state.workspace.sourceParentIdentity
            ) else {
                return .unknown(failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "source is absent while cleanup remains pending"
                ))
            }
            _ = stable
            guard try NativePathInspector.identity(at: state.workspace.source) ==
                state.workspace.sourceIdentity else {
                return .sourceChanged(failure(
                    context,
                    code: .sourceChanged,
                    diagnostic: "source identity changed before quarantine"
                ))
            }
            return .sourcePresentMatching
        } catch let native as NativeFileError where native.systemCode == ENOENT {
            return .unknown(failure(
                context,
                code: .recoveryRequired,
                diagnostic: "source lookup became absent before cleanup"
            ))
        } catch {
            return .unknown(failure(
                context,
                code: .recoveryRequired,
                diagnostic: String(describing: error)
            ))
        }
    }

    package func inspectSourceForRetention(
        context: ExecutionContext,
        receipt: OperationReceiptSummary,
        records: [DurableEffectRecord],
        manifest: [DurableManifestNode]
    ) async -> ExecutionSourceInspection {
        _ = receipt
        guard let root = manifest.first(where: { $0.relativePath == "." }),
              let evidence = try? decoder.decode(
                  NativeManifestIdentityEvidence.self,
                  from: root.identity
              ),
              let sourceParent = evidence.sourceParent,
              let frozenDigest = records.last(where: {
                  [.stageCommit, .commitReplacement].contains($0.intent.kind) &&
                      $0.result?.status == .completed
              })?.intent.manifestDigest else {
            return .unknown(failure(
                context,
                code: .recoveryRequired,
                diagnostic: "durable source-retention proof is incomplete"
            ))
        }
        do {
            guard let currentIdentity = try anchoredIdentityIfPresent(
                at: context.source,
                expectedParent: sourceParent
            ) else {
                return .unknown(failure(
                    context,
                    code: .recoveryRequired,
                    diagnostic: "source is absent while cleanup remains pending"
                ))
            }
            guard currentIdentity == evidence.source else {
                return .sourceChanged(failure(
                    context,
                    code: .sourceChanged,
                    diagnostic: "durable source identity changed before retention"
                ))
            }
            let current = try NativeTreeManifest.capture(
                root: context.source,
                includeContentDigests: true
            )
            guard current.digest == frozenDigest else {
                return .sourceChanged(failure(
                    context,
                    code: .sourceChanged,
                    diagnostic: "durable source content or metadata changed before retention"
                ))
            }
            return .sourcePresentMatching
        } catch {
            return .unknown(failure(
                context,
                code: .recoveryRequired,
                diagnostic: String(describing: error)
            ))
        }
    }

    private func state(_ context: ExecutionContext) -> ItemState? {
        lock.withLock { states[key(context)] }
    }

    private func key(_ context: ExecutionContext) -> NativeCopyWorkspaceRegistry.Key {
        .init(operationID: context.operationID, itemID: context.itemID)
    }

    private func stagingURL(
        _ state: ItemState,
        context: ExecutionContext
    ) throws -> URL {
        guard let staging = workspace.copyRegistry.record(
            for: key(context)
        )?.staging else {
            throw failure(
                context,
                code: .recoveryRequired,
                diagnostic: "verified staging URL is unavailable"
            )
        }
        return staging
    }

    private func stagingEvidence(
        _ state: ItemState,
        context: ExecutionContext
    ) throws -> (
        url: URL,
        identity: NativeStableObjectIdentity,
        parentIdentity: NativeStableObjectIdentity
    ) {
        guard let record = workspace.copyRegistry.record(for: key(context)),
              let identity = record.ownedNodes["."] else {
            throw failure(
                context,
                code: .recoveryRequired,
                diagnostic: "verified staging identity evidence is unavailable"
            )
        }
        return (
            try stagingURL(state, context: context),
            identity,
            record.stagingParentIdentity
        )
    }

    private func renamePreparation(
        kind: DurableEffectKind,
        from: URL,
        to: URL,
        expectedObject: NativeStableObjectIdentity,
        expectedFromParent: NativeStableObjectIdentity,
        expectedToParent: NativeStableObjectIdentity,
        expectedRegistrationDestination: NativeStableObjectIdentity? = nil,
        registrationDestinationMayBeAbsent: Bool = false,
        sourceRole: String? = nil,
        manifestDigest: String?,
        embeddedManifest: [DurableManifestNode]? = nil
    ) throws -> DurableEffectPreparation {
        guard try NativePathInspector.stableIdentity(at: from) == expectedObject,
              try NativePathInspector.stableIdentity(
                at: from.deletingLastPathComponent()
              ) == expectedFromParent else {
            throw NativeFileError(
                code: .sourceChanged,
                systemCode: nil,
                message: "rename source or parent changed before effect registration"
            )
        }
        guard try NativePathInspector.stableIdentity(
            at: to.deletingLastPathComponent()
        ) == expectedToParent else {
            throw NativeFileError(
                code: .destinationChanged,
                systemCode: nil,
                message: "rename destination parent changed before effect registration"
            )
        }
        do {
            let current = try NativePathInspector.stableIdentity(at: to)
            guard current == expectedRegistrationDestination else {
                throw NativeFileError(
                    code: .destinationChanged,
                    systemCode: nil,
                    message: "rename destination changed before effect registration"
                )
            }
        } catch let native as NativeFileError where native.systemCode == ENOENT {
            guard expectedRegistrationDestination == nil ||
                    registrationDestinationMayBeAbsent else {
                throw NativeFileError(
                    code: .destinationChanged,
                    systemCode: ENOENT,
                    message: "rename destination disappeared before effect registration"
                )
            }
        }
        let payload = NativeEffectPayload(
            from: from,
            to: to,
            target: nil,
            expectedObject: expectedObject,
            expectedFromParent: expectedFromParent,
            expectedToParent: expectedToParent,
            embeddedManifest: embeddedManifest,
            sourceRole: sourceRole
        )
        return DurableEffectPreparation(
            kind: kind,
            expectedIdentity: try encoder.encode(payload),
            manifestDigest: manifestDigest
        )
    }

    private func purgePayload(
        target: URL,
        node: DurableManifestNode,
        manifest: [DurableManifestNode],
        rootParent: NativeStableObjectIdentity
    ) throws -> NativeEffectPayload {
        let expectedParent: NativeStableObjectIdentity
        if let parentNodeID = node.parentNodeID {
            guard let parent = manifest.first(where: { $0.nodeID == parentNodeID }) else {
                throw NativeFileError(
                    code: .invariantViolation,
                    systemCode: nil,
                    message: "purge manifest parent is missing"
                )
            }
            expectedParent = try sourceIdentity(from: parent.identity)
        } else {
            expectedParent = rootParent
        }
        return NativeEffectPayload(
            from: nil,
            to: nil,
            target: target,
            expectedObject: try sourceIdentity(from: node.identity),
            expectedFromParent: nil,
            expectedToParent: expectedParent
        )
    }

    private func sourceIdentity(from data: Data) throws -> NativeStableObjectIdentity {
        if let evidence = try? decoder.decode(
            NativeManifestIdentityEvidence.self,
            from: data
        ) {
            return evidence.source
        }
        return try decoder.decode(NativeStableObjectIdentity.self, from: data)
    }

    private func sourceParentIdentity(
        from data: Data
    ) throws -> NativeStableObjectIdentity {
        guard let evidence = try? decoder.decode(
            NativeManifestIdentityEvidence.self,
            from: data
        ), let sourceParent = evidence.sourceParent else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "durable manifest lacks source parent identity evidence"
            )
        }
        return sourceParent
    }

    private func stableIdentity(
        _ identity: NativeCompositeIdentity
    ) -> NativeStableObjectIdentity {
        NativeStableObjectIdentity(
            volumeUUID: identity.volumeUUID,
            device: identity.device,
            inode: identity.inode,
            nodeType: identity.mode & UInt32(S_IFMT)
        )
    }

    private func stagingIdentity(from data: Data) throws -> NativeStableObjectIdentity {
        guard let evidence = try? decoder.decode(
            NativeManifestIdentityEvidence.self,
            from: data
        ), let staging = evidence.staging else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "durable manifest lacks staging identity evidence"
            )
        }
        return staging
    }

    private func exclusiveRename(
        from: URL,
        to: URL,
        payload: NativeEffectPayload,
        intent: DurableEffectIntent
    ) throws {
        let fromEntry = try NativeAnchoredEntry.openParent(of: from)
        let toEntry = try NativeAnchoredEntry.openParent(of: to)
        let fromParent = try NativePathInspector.stableIdentity(
            fileDescriptor: fromEntry.parent.fileDescriptor,
            volumeUUID: try NativePathInspector.stableIdentity(
                at: from.deletingLastPathComponent()
            ).volumeUUID,
            diagnosticPath: from.deletingLastPathComponent().path
        )
        let toParent = try NativePathInspector.stableIdentity(
            fileDescriptor: toEntry.parent.fileDescriptor,
            volumeUUID: try NativePathInspector.stableIdentity(
                at: to.deletingLastPathComponent()
            ).volumeUUID,
            diagnosticPath: to.deletingLastPathComponent().path
        )
        guard fromParent == payload.expectedFromParent,
              toParent == payload.expectedToParent,
              try NativePathInspector.stableIdentity(
                parentFileDescriptor: fromEntry.parent.fileDescriptor,
                name: fromEntry.name,
                volumeUUID: fromParent.volumeUUID,
                diagnosticPath: from.path
              ) == payload.expectedObject else {
            throw NativeFileError(
                code: .sourceChanged,
                systemCode: nil,
                message: "rename identity changed before syscall"
            )
        }
        var targetInfo = stat()
        guard fstatat(
            toEntry.parent.fileDescriptor,
            toEntry.name,
            &targetInfo,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw NativeFileError(
                code: .destinationChanged,
                systemCode: errno,
                message: "exclusive rename destination is not absent"
            )
        }
        try recordCrashSyscallAttempt(intent)
        guard renameatx_np(
            fromEntry.parent.fileDescriptor,
            fromEntry.name,
            toEntry.parent.fileDescriptor,
            toEntry.name,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw NativeFileError.fromErrno(
                errno,
                path: "\(from.path) -> \(to.path)",
                operation: "exclusive transactional rename"
            )
        }
        let committed = try NativePathInspector.stableIdentity(
            parentFileDescriptor: toEntry.parent.fileDescriptor,
            name: toEntry.name,
            volumeUUID: toParent.volumeUUID,
            diagnosticPath: to.path
        )
        guard committed == payload.expectedObject else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "rename destination identity changed after syscall"
            )
        }
    }

    private func anchoredUnlink(
        target: URL,
        payload: NativeEffectPayload,
        intent: DurableEffectIntent
    ) throws {
        let entry = try NativeAnchoredEntry.openParent(of: target)
        let expected = payload.expectedObject
        guard let expectedParent = payload.expectedToParent else {
            throw NativeFileError(
                code: .invariantViolation,
                systemCode: nil,
                message: "purge payload lacks frozen parent identity"
            )
        }
        let actualParent = try NativePathInspector.stableIdentity(
            fileDescriptor: entry.parent.fileDescriptor,
            volumeUUID: expectedParent.volumeUUID,
            diagnosticPath: target.deletingLastPathComponent().path
        )
        guard actualParent == expectedParent else {
            throw NativeFileError(
                code: .sourceChanged,
                systemCode: nil,
                message: "purge parent identity changed before unlinkat"
            )
        }
        let actual = try NativePathInspector.stableIdentity(
            parentFileDescriptor: entry.parent.fileDescriptor,
            name: entry.name,
            volumeUUID: expected.volumeUUID,
            diagnosticPath: target.path
        )
        guard actual == expected else {
            throw NativeFileError(
                code: .sourceChanged,
                systemCode: nil,
                message: "purge node identity changed before unlinkat"
            )
        }
        let flags = expected.nodeType == UInt32(S_IFDIR) ? AT_REMOVEDIR : 0
        try recordCrashSyscallAttempt(intent)
        guard unlinkat(entry.parent.fileDescriptor, entry.name, flags) == 0 else {
            throw NativeFileError.fromErrno(
                errno,
                path: target.path,
                operation: "anchored quarantine purge"
            )
        }
    }

    private func registerPurgePreflight(
        context: ExecutionContext,
        quarantine: URL,
        nodes: [DurableManifestNode],
        rootParent: NativeStableObjectIdentity
    ) {
        lock.withLock {
            purgePreflights[key(context)] = PurgePreflightState(
                quarantineURL: quarantine,
                nodes: nodes,
                rootParentIdentity: rootParent,
                validated: false
            )
        }
    }

    /// A purge is authorized only after the complete remaining quarantine tree
    /// matches the frozen node set. Revalidation before every unlink prevents a
    /// newly introduced child from allowing further known nodes to be removed.
    private func validatePurgePreflightIfNeeded(
        _ intent: DurableEffectIntent
    ) throws {
        let key = NativeCopyWorkspaceRegistry.Key(
            operationID: intent.operationID,
            itemID: intent.itemID
        )
        guard let preflight = lock.withLock({ purgePreflights[key] }) else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "quarantine purge lacks a frozen-tree preflight"
            )
        }
        if preflight.validated { return }
        if preflight.nodes.isEmpty {
            guard !lstatExists(preflight.quarantineURL) else {
                throw NativeFileError(
                    code: .sourceChanged,
                    systemCode: nil,
                    message: "completed quarantine purge left an unexpected tree"
                )
            }
            lock.withLock {
                purgePreflights[key]?.validated = true
            }
            return
        }

        let current = try NativeTreeManifest.capture(
            root: preflight.quarantineURL,
            includeContentDigests: true
        )
        let expectedPaths = Set(preflight.nodes.map(\.relativePath))
        let actualPaths = Set(current.entries.map(\.relativePath))
        guard actualPaths == expectedPaths else {
            throw NativeFileError(
                code: .sourceChanged,
                systemCode: nil,
                message: "quarantine child set changed before purge"
            )
        }
        let expectedByID = Dictionary(
            uniqueKeysWithValues: preflight.nodes.map { ($0.nodeID, $0) }
        )
        let currentByPath = Dictionary(
            uniqueKeysWithValues: current.entries.map { ($0.relativePath, $0) }
        )
        for node in preflight.nodes {
            let url = node.relativePath == "."
                ? preflight.quarantineURL
                : preflight.quarantineURL.appendingPathComponent(
                    node.relativePath,
                    isDirectory: node.kind == .directory
                )
            let expectedIdentity = try sourceIdentity(from: node.identity)
            let expectedParent: NativeStableObjectIdentity
            if let parentNodeID = node.parentNodeID {
                guard let parent = expectedByID[parentNodeID] else {
                    throw NativeFileError(
                        code: .sourceChanged,
                        systemCode: nil,
                        message: "remaining quarantine node lost its frozen parent"
                    )
                }
                expectedParent = try sourceIdentity(from: parent.identity)
            } else {
                expectedParent = preflight.rootParentIdentity
            }
            guard let actualIdentity = try anchoredIdentityIfPresent(
                at: url,
                expectedParent: expectedParent
            ), actualIdentity == expectedIdentity,
                  let entry = currentByPath[node.relativePath],
                  entry.kind == node.kind,
                  node.digest == nil || entry.contentSHA256 == node.digest else {
                throw NativeFileError(
                    code: .sourceChanged,
                    systemCode: nil,
                    message: "quarantine identity, type, parent, or content changed before purge"
                )
            }
        }
        lock.withLock {
            purgePreflights[key]?.validated = true
        }
    }

    private func invalidatePurgePreflight(_ intent: DurableEffectIntent) {
        let key = NativeCopyWorkspaceRegistry.Key(
            operationID: intent.operationID,
            itemID: intent.itemID
        )
        lock.withLock {
            purgePreflights[key]?.validated = false
        }
    }

    private func advancePurgePreflight(_ intent: DurableEffectIntent) {
        let key = NativeCopyWorkspaceRegistry.Key(
            operationID: intent.operationID,
            itemID: intent.itemID
        )
        lock.withLock {
            guard var state = purgePreflights[key] else { return }
            if intent.kind == .purgeQuarantineRoot {
                state.nodes.removeAll()
            } else if let nodeID = intent.nodeID {
                state.nodes.removeAll { $0.nodeID == nodeID }
            }
            state.validated = false
            purgePreflights[key] = state
        }
    }

    private func anchoredIdentityIfPresent(
        at url: URL,
        expectedParent: NativeStableObjectIdentity
    ) throws -> NativeStableObjectIdentity? {
        let entry = try NativeAnchoredEntry.openParent(of: url)
        let actualParent = try NativePathInspector.stableIdentity(
            fileDescriptor: entry.parent.fileDescriptor,
            volumeUUID: expectedParent.volumeUUID,
            diagnosticPath: url.deletingLastPathComponent().path
        )
        guard actualParent == expectedParent else {
            throw NativeFileError(
                code: .sourceChanged,
                systemCode: nil,
                message: "frozen parent identity changed"
            )
        }
        do {
            return try NativePathInspector.stableIdentity(
                parentFileDescriptor: entry.parent.fileDescriptor,
                name: entry.name,
                volumeUUID: expectedParent.volumeUUID,
                diagnosticPath: url.path
            )
        } catch let native as NativeFileError where native.systemCode == ENOENT {
            return nil
        }
    }

    /// Test-only crash evidence. The URL is injected only by FileOpsCrashProbe;
    /// production composition roots pass nil. O_APPEND makes each one-line
    /// record attributable across the worker and all restarted owners.
    private func recordCrashSyscallAttempt(
        _ intent: DurableEffectIntent
    ) throws {
        guard let url = crashSyscallCounterURL else { return }
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NativeFileError.fromErrno(
                errno,
                path: url.path,
                operation: "open crash syscall counter"
            )
        }
        defer { close(descriptor) }
        let line = [
            intent.effectID.uuidString.lowercased(),
            intent.operationID.rawValue.uuidString.lowercased(),
            intent.itemID.rawValue.uuidString.lowercased(),
            intent.kind.rawValue,
            String(intent.effectOrdinal),
            intent.ownerEpoch.uuidString.lowercased(),
        ].joined(separator: "\t") + "\n"
        let bytes = Array(line.utf8)
        let count = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count == bytes.count, fsync(descriptor) == 0 else {
            throw NativeFileError.fromErrno(
                errno,
                path: url.path,
                operation: "append crash syscall counter"
            )
        }
    }

    private func ambiguousInspection(
        _ intent: DurableEffectIntent,
        diagnostic: String
    ) -> DurableEffectExecutionOutcome {
        .ambiguous(
            FileOperationFailure(
                code: .recoveryRequired,
                operationID: intent.operationID,
                itemID: intent.itemID,
                diagnostic: diagnostic,
                retryable: false
            ),
            evidence: Data("identity-inspection:ambiguous".utf8)
        )
    }

    private func committedDestinationMatchesFrozenEffect(
        records: [DurableEffectRecord],
        destination: URL
    ) -> Bool {
        guard let record = records.last(where: {
            [.stageCommit, .commitReplacement].contains($0.intent.kind)
        }), record.result?.status == .completed,
        let payload = try? decoder.decode(
            NativeEffectPayload.self,
            from: record.intent.expectedIdentity
        ), payload.to == destination,
        let expectedParent = payload.expectedToParent,
        let actual = try? anchoredIdentityIfPresent(
            at: destination,
            expectedParent: expectedParent
        ) else {
            return false
        }
        return actual == payload.expectedObject
    }

    private func destinationMatchesManifest(_ state: ItemState) -> Bool {
        guard let current = try? NativeTreeManifest.capture(
            root: state.workspace.destination,
            includeContentDigests: true
        ) else {
            return false
        }
        return state.manifest.firstMismatch(
            against: current,
            policy: .sha256
        ) == nil
    }

    private func makeManifestNodes(
        root: URL,
        manifest: NativeTreeManifest
    ) throws -> [DurableManifestNode] {
        let ordered = manifest.entries.sorted {
            let leftDepth = $0.relativePath == "."
                ? 0 : $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath == "."
                ? 0 : $1.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return Array($0.relativePath.utf8).lexicographicallyPrecedes(
                Array($1.relativePath.utf8)
            )
        }
        let nodeIDs = Dictionary(uniqueKeysWithValues: manifest.entries.map {
            ($0.relativePath, SHA256Provider.data(Data($0.relativePath.utf8)))
        })
        return try ordered.enumerated().map { offset, entry in
            let url = entry.relativePath == "."
                ? root
                : root.appendingPathComponent(entry.relativePath)
            let parentPath: String?
            if entry.relativePath == "." {
                parentPath = nil
            } else {
                let value = NSString(string: entry.relativePath)
                    .deletingLastPathComponent
                parentPath = value.isEmpty ? "." : value
            }
            return DurableManifestNode(
                nodeID: nodeIDs[entry.relativePath]!,
                parentNodeID: parentPath.flatMap { nodeIDs[$0] },
                relativePath: entry.relativePath,
                depth: entry.relativePath == "."
                    ? 0 : entry.relativePath.split(separator: "/").count,
                kind: entry.kind,
                identity: try encoder.encode(
                    NativePathInspector.stableIdentity(at: url)
                ),
                digest: entry.contentSHA256,
                purgeOrdinal: UInt64(offset + 1)
            )
        }
    }

    private func recoveryURL(
        parent: URL,
        prefix: String,
        context: ExecutionContext
    ) -> URL {
        parent.appendingPathComponent(
            ".rascal-\(prefix)-\(context.operationID.rawValue.uuidString.lowercased())-" +
                context.itemID.rawValue.uuidString.lowercased()
        )
    }

    private func commitPayloadManifestDigest(
        _ records: [DurableEffectRecord]
    ) -> String? {
        records.last(where: {
            [.commitReplacement, .stageCommit].contains($0.intent.kind)
        })?.intent.manifestDigest
    }

    private func required<T>(
        _ value: T?,
        _ context: ExecutionContext,
        _ label: String
    ) throws -> T {
        guard let value else {
            throw failure(
                context,
                code: .invariantViolation,
                diagnostic: "missing \(label)"
            )
        }
        return value
    }

    private func required<T>(
        _ value: T?,
        _ intent: DurableEffectIntent,
        _ label: String
    ) throws -> T {
        guard let value else {
            throw FileOperationFailure(
                code: .invariantViolation,
                operationID: intent.operationID,
                itemID: intent.itemID,
                diagnostic: "missing \(label)",
                retryable: false
            )
        }
        return value
    }

    private func failure(
        _ context: ExecutionContext,
        code: FileOperationErrorCode,
        diagnostic: String
    ) -> FileOperationFailure {
        FileOperationFailure(
            code: code,
            operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: diagnostic,
            retryable: false
        )
    }
}

private extension ExecutionContext {
    func replacingRequestForTransactionalCopy() -> ExecutionContext {
        let copyRequest = OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            metadataPolicy: metadataPolicy,
            verificationPolicy: verificationPolicy
        )
        return ExecutionContext(
            operationID: operationID,
            itemID: itemID,
            request: copyRequest,
            source: source,
            destination: destination,
            itemIndex: 0,
            metadataPolicy: metadataPolicy,
            verificationPolicy: verificationPolicy
        )
    }
}
