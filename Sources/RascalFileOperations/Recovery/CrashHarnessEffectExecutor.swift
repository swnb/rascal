import Foundation
import Darwin

package struct CrashHarnessEffectSpec: Codable, Sendable {
    package let kind: DurableEffectKind
    package let from: URL?
    package let to: URL?
    package let target: URL?
    package let targetIsDirectory: Bool
    package let expectedIdentity: NativeStableObjectIdentity
    package let counterURL: URL

    package static func rename(
        kind: DurableEffectKind,
        from: URL,
        to: URL,
        counterURL: URL
    ) throws -> CrashHarnessEffectSpec {
        CrashHarnessEffectSpec(
            kind: kind,
            from: from,
            to: to,
            target: nil,
            targetIsDirectory: false,
            expectedIdentity: try NativePathInspector.stableIdentity(at: from),
            counterURL: counterURL
        )
    }

    package static func unlink(
        kind: DurableEffectKind,
        target: URL,
        targetIsDirectory: Bool,
        counterURL: URL
    ) throws -> CrashHarnessEffectSpec {
        CrashHarnessEffectSpec(
            kind: kind,
            from: nil,
            to: nil,
            target: target,
            targetIsDirectory: targetIsDirectory,
            expectedIdentity: try NativePathInspector.stableIdentity(at: target),
            counterURL: counterURL
        )
    }
}

package final class CrashHarnessEffectExecutor: @unchecked Sendable, DurableEffectExecutor {
    private let spec: CrashHarnessEffectSpec
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    package init(spec: CrashHarnessEffectSpec) {
        self.spec = spec
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    package func plan(
        _ context: ExecutionContext,
        controls: ExecutionControls
    ) async throws -> ExecutionPlan {
        _ = context
        _ = controls
        return ExecutionPlan(sourceDisposition: .noCleanup)
    }

    package func perform(
        _ phase: ExecutionPhase,
        context: ExecutionContext,
        plan: ExecutionPlan,
        controls: ExecutionControls,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async -> ExecutionPhaseOutcome {
        _ = phase
        _ = context
        _ = plan
        _ = controls
        _ = progress
        return .failed(FileOperationFailure(
            code: .invariantViolation,
            diagnostic: "crash harness destructive effects require durable orchestration",
            retryable: false
        ))
    }

    package func manifestNodes(
        for context: ExecutionContext
    ) async throws -> [DurableManifestNode] {
        _ = context
        return []
    }

    package func prepareEffects(
        for phase: ExecutionPhase,
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async throws -> [DurableEffectPreparation] {
        _ = phase
        _ = context
        _ = plan
        return [DurableEffectPreparation(
            kind: spec.kind,
            nodeID: spec.kind == .purgeQuarantineNode ? "crash-harness-node" : nil,
            relativePath: spec.kind == .purgeQuarantineNode ? "target" : nil,
            expectedIdentity: try encoder.encode(spec)
        )]
    }

    package func perform(
        _ intent: DurableEffectIntent
    ) async -> DurableEffectExecutionOutcome {
        do {
            let decoded = try decoder.decode(
                CrashHarnessEffectSpec.self,
                from: intent.expectedIdentity
            )
            if let from = decoded.from, let to = decoded.to {
                try exclusiveRename(from: from, to: to, expected: decoded.expectedIdentity)
            } else if let target = decoded.target {
                try anchoredUnlink(
                    target: target,
                    isDirectory: decoded.targetIsDirectory,
                    expected: decoded.expectedIdentity
                )
            } else {
                throw FileOperationFailure(
                    code: .invariantViolation,
                    diagnostic: "crash harness effect has no filesystem target",
                    retryable: false
                )
            }
            try appendCounter(decoded.counterURL)
            return .completed(
                identity: Data("completed".utf8),
                evidence: Data("real-syscall".utf8)
            )
        } catch let failure as FileOperationFailure {
            return .ambiguous(failure, evidence: Data(failure.diagnostic.utf8))
        } catch {
            return .ambiguous(
                FileOperationFailure(
                    code: .recoveryRequired,
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
            let decoded = try decoder.decode(
                CrashHarnessEffectSpec.self,
                from: intent.expectedIdentity
            )
            if let from = decoded.from, let to = decoded.to {
                let source = try? NativePathInspector.stableIdentity(at: from)
                let destination = try? NativePathInspector.stableIdentity(at: to)
                if source == nil, destination == decoded.expectedIdentity {
                    return .completed(
                        identity: Data("completed".utf8),
                        evidence: Data("inspect-rename-completed".utf8)
                    )
                }
                if source == decoded.expectedIdentity, destination == nil {
                    return .notPerformed(evidence: Data("inspect-rename-not-performed".utf8))
                }
            } else if let target = decoded.target {
                if !lstatExists(target) {
                    return .completed(
                        identity: Data("completed".utf8),
                        evidence: Data("inspect-unlink-completed".utf8)
                    )
                }
                if try NativePathInspector.stableIdentity(at: target) ==
                    decoded.expectedIdentity {
                    return .notPerformed(evidence: Data("inspect-unlink-not-performed".utf8))
                }
            }
            return .ambiguous(
                FileOperationFailure(
                    code: .recoveryRequired,
                    operationID: intent.operationID,
                    itemID: intent.itemID,
                    diagnostic: "crash harness filesystem predicate is ambiguous",
                    retryable: false
                ),
                evidence: Data("ambiguous".utf8)
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
        _ = phase
        _ = records
        _ = context
        _ = plan
        return nil
    }

    package func outcome(
        for phase: ExecutionPhase,
        completed records: [DurableEffectRecord],
        context: ExecutionContext,
        plan: ExecutionPlan
    ) async -> ExecutionPhaseOutcome {
        _ = phase
        _ = records
        _ = context
        _ = plan
        return .sourceCleaned
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
            diagnostic: "crash harness uses durable effects only",
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
            code: .featureDisabled,
            diagnostic: "crash harness uses durable effects only",
            retryable: false
        ))
    }

    package func inspectCommit(
        _ context: ExecutionContext
    ) async -> ExecutionCommitInspection {
        _ = context
        return .notCommitted
    }

    package func inspectSourceBeforeCleanup(
        _ context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionSourceInspection {
        _ = context
        _ = receipt
        return .sourcePresentMatching
    }

    private func exclusiveRename(
        from: URL,
        to: URL,
        expected: NativeStableObjectIdentity
    ) throws {
        let source = try NativeAnchoredEntry.openParent(of: from)
        let destination = try NativeAnchoredEntry.openParent(of: to)
        guard try NativePathInspector.stableIdentity(
            parentFileDescriptor: source.parent.fileDescriptor,
            name: source.name,
            volumeUUID: expected.volumeUUID,
            diagnosticPath: from.path
        ) == expected else {
            throw FileOperationFailure(
                code: .sourceChanged,
                diagnostic: "crash harness rename source changed",
                retryable: false
            )
        }
        var info = stat()
        guard fstatat(
            destination.parent.fileDescriptor,
            destination.name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw FileOperationFailure(
                code: .destinationChanged,
                systemCode: errno,
                diagnostic: "crash harness rename destination exists",
                retryable: false
            )
        }
        guard renameatx_np(
            source.parent.fileDescriptor,
            source.name,
            destination.parent.fileDescriptor,
            destination.name,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw FileOperationFailure(
                code: .recoveryRequired,
                systemCode: errno,
                diagnostic: "crash harness renameatx_np failed",
                retryable: false
            )
        }
    }

    private func anchoredUnlink(
        target: URL,
        isDirectory: Bool,
        expected: NativeStableObjectIdentity
    ) throws {
        let entry = try NativeAnchoredEntry.openParent(of: target)
        guard try NativePathInspector.stableIdentity(
            parentFileDescriptor: entry.parent.fileDescriptor,
            name: entry.name,
            volumeUUID: expected.volumeUUID,
            diagnosticPath: target.path
        ) == expected else {
            throw FileOperationFailure(
                code: .sourceChanged,
                diagnostic: "crash harness unlink target changed",
                retryable: false
            )
        }
        guard unlinkat(
            entry.parent.fileDescriptor,
            entry.name,
            isDirectory ? AT_REMOVEDIR : 0
        ) == 0 else {
            throw FileOperationFailure(
                code: .recoveryRequired,
                systemCode: errno,
                diagnostic: "crash harness unlinkat failed",
                retryable: false
            )
        }
    }

    private func appendCounter(_ url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw FileOperationFailure(
                code: .invariantViolation,
                systemCode: errno,
                diagnostic: "crash harness counter open failed",
                retryable: false
            )
        }
        defer { close(descriptor) }
        let byte = [UInt8(ascii: "1"), UInt8(ascii: "\n")]
        let count = byte.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        guard count == byte.count, fsync(descriptor) == 0 else {
            throw FileOperationFailure(
                code: .invariantViolation,
                systemCode: errno,
                diagnostic: "crash harness counter write failed",
                retryable: false
            )
        }
    }
}
