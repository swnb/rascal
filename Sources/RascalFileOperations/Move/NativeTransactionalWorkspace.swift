import Foundation

package final class NativeTransactionalWorkspace: @unchecked Sendable {
    package enum Mode: Sendable {
        case sameVolumeMove
        case crossVolumeMove
        case standaloneReplace
        case moveReplace
    }

    package struct Item: Sendable {
        package let mode: Mode
        package let source: URL
        package let destination: URL
        package let sourceIdentity: NativeCompositeIdentity
        package let sourceParentIdentity: NativeStableObjectIdentity
        package let destinationIdentity: NativeCompositeIdentity?
        package let destinationParentIdentity: NativeStableObjectIdentity
    }

    package let copyRegistry = NativeCopyWorkspaceRegistry()
    private let lock = NSLock()
    private var items: [NativeCopyWorkspaceRegistry.Key: Item] = [:]

    package init() {}

    package func store(
        _ item: Item,
        operationID: OperationID,
        itemID: OperationItemID
    ) throws {
        let key = NativeCopyWorkspaceRegistry.Key(
            operationID: operationID,
            itemID: itemID
        )
        try lock.withLock {
            if let existing = items[key],
               existing.source != item.source ||
                existing.destination != item.destination ||
                existing.mode != item.mode ||
                existing.sourceIdentity != item.sourceIdentity ||
                existing.sourceParentIdentity != item.sourceParentIdentity ||
                existing.destinationIdentity != item.destinationIdentity ||
                existing.destinationParentIdentity != item.destinationParentIdentity {
                throw NativeFileError(
                    code: .sourceChanged,
                    systemCode: nil,
                    message: "transactional workspace key or frozen identity was rebound"
                )
            }
            items[key] = item
        }
    }

    package func item(
        operationID: OperationID,
        itemID: OperationItemID
    ) -> Item? {
        lock.withLock {
            items[NativeCopyWorkspaceRegistry.Key(
                operationID: operationID,
                itemID: itemID
            )]
        }
    }
}

extension NativeTransactionalWorkspace.Mode: Equatable {}

package struct NativeTransactionalFileSystemAdapter: FileSystemAdapter {
    package let workspace: NativeTransactionalWorkspace

    package init(workspace: NativeTransactionalWorkspace) {
        self.workspace = workspace
    }

    package func preflight(
        operationID: OperationID,
        itemID: OperationItemID,
        request: OperationRequest,
        itemIndex: Int,
        priorDecision: ResolvedOperationDecision?,
        controls: ExecutionControls
    ) async throws -> PreflightDisposition {
        guard [.move, .rename, .replace].contains(request.kind),
              request.sources.indices.contains(itemIndex),
              let projected = RequestValidator.projectedDestinations(request)[itemIndex] else {
            return .failure(FileOperationFailure(
                code: .featureDisabled,
                operationID: operationID,
                itemID: itemID,
                diagnostic: "M3 transactional adapter accepts move, rename, and replace only",
                retryable: false
            ))
        }
        await controls.checkpoint()
        if await controls.isCancelled() { return .skip }

        let source = request.sources[itemIndex].standardizedFileURL
        let destination = projected.standardizedFileURL
        do {
            let sourceIdentity = try NativePathInspector.identity(at: source)
            let sourceParentIdentity = try NativePathInspector.stableIdentity(
                at: source.deletingLastPathComponent()
            )
            let destinationParent = destination.deletingLastPathComponent()
            let parentIdentity = try NativePathInspector.stableIdentity(at: destinationParent)
            let safety = NativePathInspector.safetyCapabilities(
                source: source,
                destinationParent: destinationParent
            )
            if let reason = safety.firstBlockingReason {
                return .failure(FileOperationFailure(
                    code: .serviceSafeMode,
                    operationID: operationID,
                    itemID: itemID,
                    diagnostic: reason,
                    retryable: false
                ))
            }
            let fidelity = NativePathInspector.fidelityCapabilities(
                source: source,
                destinationParent: destinationParent
            )
            guard fidelity.unavailableFields.isEmpty else {
                return .failure(FileOperationFailure(
                    code: .unsupportedMetadata,
                    operationID: operationID,
                    itemID: itemID,
                    diagnostic: "move/replace metadata fidelity cannot be downgraded",
                    retryable: false
                ))
            }

            let destinationIdentity = try? NativePathInspector.identity(at: destination)
            let sameVolume = sourceIdentity.volumeUUID == parentIdentity.volumeUUID
            let mode: NativeTransactionalWorkspace.Mode
            switch request.kind {
            case .rename:
                guard sameVolume,
                      source.deletingLastPathComponent() ==
                        destination.deletingLastPathComponent(),
                      destinationIdentity == nil else {
                    return .failure(FileOperationFailure(
                        code: .destinationChanged,
                        operationID: operationID,
                        itemID: itemID,
                        diagnostic: "rename requires an absent destination in the same directory",
                        retryable: true
                    ))
                }
                mode = .sameVolumeMove
            case .replace:
                guard destinationIdentity != nil else {
                    return .failure(FileOperationFailure(
                        code: .destinationChanged,
                        operationID: operationID,
                        itemID: itemID,
                        diagnostic: "replace requires an existing destination",
                        retryable: true
                    ))
                }
                mode = .standaloneReplace
            case .move:
                if let destinationIdentity {
                    let digest = sourceIdentity.digest + "|" + destinationIdentity.digest
                    guard priorDecision?.identityDigest == nil ||
                            priorDecision?.identityDigest == digest else {
                        return .failure(FileOperationFailure(
                            code: .decisionExpired,
                            operationID: operationID,
                            itemID: itemID,
                            diagnostic: "move conflict identity changed",
                            retryable: true
                        ))
                    }
                    switch priorDecision?.decision {
                    case let .replace(scope)
                        where scope == .item || scope == .remainingItems:
                        mode = .moveReplace
                    case .stop:
                        return .failure(FileOperationFailure(
                            code: .destinationChanged,
                            operationID: operationID,
                            itemID: itemID,
                            diagnostic: "move stopped because destination exists",
                            retryable: true
                        ))
                    case .cancel:
                        return .skip
                    default:
                        return .decision(PreflightDecision(
                            allowed: [
                                .replace(scope: .item),
                                .stop,
                                .cancel,
                            ],
                            identityDigest: digest
                        ))
                    }
                } else {
                    mode = sameVolume ? .sameVolumeMove : .crossVolumeMove
                }
            default:
                fatalError("validated transactional kind")
            }

            let treeIdentity = try NativeTreeIdentitySnapshot.capture(root: source)
            try workspace.store(.init(
                mode: mode,
                source: source,
                destination: destination,
                sourceIdentity: sourceIdentity,
                sourceParentIdentity: sourceParentIdentity,
                destinationIdentity: destinationIdentity,
                destinationParentIdentity: parentIdentity
            ), operationID: operationID, itemID: itemID)
            if mode != .sameVolumeMove {
                try workspace.copyRegistry.storePreflightReceipt(.init(
                    source: source,
                    destination: destination,
                    sourceIdentity: sourceIdentity,
                    sourceTreeIdentity: treeIdentity,
                    destinationParentIdentity: parentIdentity,
                    safety: safety,
                    fidelityLosses: []
                ), for: .init(operationID: operationID, itemID: itemID))
            }
            return .ready(
                destinations: RequestValidator.projectedDestinations(request),
                moveTopology: sameVolume ? .sameVolume : .crossVolume
            )
        } catch let native as NativeFileError {
            return .failure(native.failure(operationID: operationID, itemID: itemID))
        } catch let failure as FileOperationFailure {
            return .failure(failure)
        } catch {
            return .failure(FileOperationFailure(
                code: .invariantViolation,
                operationID: operationID,
                itemID: itemID,
                diagnostic: String(describing: error),
                retryable: false
            ))
        }
    }

    package func recoverOwnedStaging(
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID
    ) async -> ExecutionRecoveryOutcome {
        await NativeCopyFileSystemAdapter(registry: workspace.copyRegistry)
            .recoverOwnedStaging(
                operationID: operationID,
                itemID: itemID,
                effectID: effectID
            )
    }

    package func inspectOwnedStaging(
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID
    ) async -> ExecutionRecoveryInspection {
        await NativeCopyFileSystemAdapter(registry: workspace.copyRegistry)
            .inspectOwnedStaging(
                operationID: operationID,
                itemID: itemID,
                effectID: effectID
            )
    }
}
