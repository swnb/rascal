import Foundation
import SQLite3

package final class SQLiteOperationJournal: @unchecked Sendable, DurableEffectJournal {
    private static let schemaVersion: Int64 = 1
    private static let terminalStates = [
        OperationState.completed.rawValue,
        OperationState.completedWithSkips.rawValue,
        OperationState.completedWithSourceRetained.rawValue,
        OperationState.cancelled.rawValue,
        OperationState.rolledBack.rawValue,
    ]

    private let lease: JournalOwnerLease
    private let connection: SQLiteConnection
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package let isWritable = true
    package var ownerEpoch: UUID? { lease.epoch }
    package var sqliteRuntimeVersion: String? { connection.runtimeVersion }

    package init(url: URL) throws {
        lease = try JournalOwnerLease(journalURL: url)
        guard lease.descriptorIsCloseOnExec() else {
            throw SQLiteJournalError(code: -1, message: "journal owner descriptor is not close-on-exec")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try Self.preflightRecoverySetReadOnly(url)
            try Self.preflightExistingJournalReadOnly(url)
        }
        connection = try SQLiteConnection(url: url)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder

        try configureConnection()
        try migrateIfNeeded()
        try verifyIntegrity()
        try verifyExpectedSchema()
        _ = try loadOperationsLocked()
        try verifyPersistedRowsLocked()
        try registerOwnerEpoch()
    }

    package func loadOperations() throws -> [JournalOperation] {
        try synchronized { try loadOperationsLocked() }
    }

    package func admit(_ snapshot: OperationSnapshot, at timestamp: Date) throws -> JournalAdmission {
        try synchronized {
            guard try operationBlob(id: snapshot.id) == nil else {
                throw failure(snapshot.id, "duplicate operation ID")
            }
            let ordinal = try nextSubmissionOrdinal()
            let sequence: EventSequence = 1
            let admitted = snapshot.replacingLatestSequenceForSQLite(sequence)
            let operation = JournalOperation(
                snapshot: admitted,
                submissionOrdinal: ordinal,
                latestDurableSequence: sequence,
                latestEmittedSequence: sequence,
                reservedThrough: sequence
            )
            let event = OperationEvent(
                operationID: snapshot.id,
                itemID: nil,
                sequence: sequence,
                timestamp: timestamp,
                durability: .durable,
                payload: .admitted(admitted)
            )
            try transaction {
                try persistOperation(operation, timestamp: timestamp)
                try insertEvent(event)
            }
            return JournalAdmission(operation: operation, event: event)
        }
    }

    package func reserveSequences(
        for id: OperationID,
        count: UInt64
    ) throws -> ClosedRange<EventSequence> {
        try synchronized {
            guard count > 0, var operation = try operation(id: id) else {
                throw failure(id, "cannot reserve sequence")
            }
            let (start, startOverflow) = operation.reservedThrough.addingReportingOverflow(1)
            let (end, endOverflow) = start.addingReportingOverflow(count - 1)
            guard !startOverflow, !endOverflow, Int64(exactly: end) != nil else {
                throw failure(id, "event sequence space exhausted")
            }
            operation.reservedThrough = end
            try transaction {
                try persistOperation(
                    operation,
                    timestamp: Date(),
                    claimOwnerAndPersistRecoveryActions: false
                )
            }
            return start...end
        }
    }

    package func commit(_ operation: JournalOperation, event: OperationEvent) throws {
        try synchronized {
            guard let stored = try self.operation(id: event.operationID),
                  event.sequence <= operation.reservedThrough,
                  event.sequence > stored.latestDurableSequence,
                  event.operationID == operation.snapshot.id,
                  operation.submissionOrdinal == stored.submissionOrdinal,
                  operation.reservedThrough >= stored.reservedThrough,
                  operation.latestDurableSequence == event.sequence,
                  operation.latestEmittedSequence >= event.sequence else {
                throw failure(event.operationID, "non-monotonic, unreserved, or foreign event")
            }
            var allowedReceipt: (OperationItemID, OperationReceiptSummary)?
            if case let .receiptRecorded(receipt) = event.payload {
                guard let itemID = event.itemID,
                      operation.snapshot.items.first(where: {
                          $0.id == itemID
                      })?.receipt == receipt,
                      operation.committedEffects[itemID] == receipt,
                      let existing = try receiptSummary(
                          operationID: event.operationID,
                          itemID: itemID
                      ) else {
                    throw failure(
                        event.operationID,
                        "receipt event is not backed by an existing durable receipt"
                    )
                }
                let identical = existing == receipt
                let retainedSourceConvergence =
                    existing.committedIdentityDigest == receipt.committedIdentityDigest &&
                    existing.backupURL == receipt.backupURL &&
                    existing.sourceCleanupPending &&
                    !receipt.sourceCleanupPending &&
                    existing.quarantineURL != nil &&
                    receipt.quarantineURL == nil
                guard identical || retainedSourceConvergence else {
                    throw failure(
                        event.operationID,
                        "receipt event attempted a non-monotonic projection"
                    )
                }
                allowedReceipt = (itemID, receipt)
            }
            try validateReceiptProjection(operation, allowing: allowedReceipt)
            try transaction {
                try persistOperation(operation, timestamp: event.timestamp)
                if let allowedReceipt {
                    try persistReceipt(
                        allowedReceipt.1,
                        operationID: event.operationID,
                        itemID: allowedReceipt.0,
                        sequence: event.sequence
                    )
                }
                try insertEvent(event)
            }
        }
    }

    package func checkpoint(_ operation: JournalOperation) throws {
        try synchronized {
            _ = try validateCheckpointBase(
                operation,
                context: "checkpoint"
            )
            try validateReceiptProjection(operation, allowing: nil)
            try transaction {
                try persistOperation(operation, timestamp: Date())
            }
        }
    }

    package func replay(
        operationID: OperationID,
        after sequence: EventSequence,
        through watermark: EventSequence,
        limit: Int
    ) throws -> [OperationEvent] {
        try synchronized {
            let query = try connection.statement(
                """
                SELECT payload_blob
                FROM operation_events
                WHERE operation_id = ? AND sequence > ? AND sequence <= ?
                ORDER BY sequence ASC
                LIMIT ?
                """
            )
            try query.bind(operationID.sqliteText, at: 1)
            try query.bind(try sqliteInteger(sequence), at: 2)
            try query.bind(try sqliteInteger(watermark), at: 3)
            try query.bind(Int64(max(1, limit)), at: 4)
            var events: [OperationEvent] = []
            while try query.step() == SQLITE_ROW {
                guard let blob = query.data(at: 0) else {
                    throw failure(operationID, "event payload is NULL")
                }
                let event = try decoder.decode(OperationEvent.self, from: blob)
                guard event.operationID == operationID,
                      event.sequence > sequence,
                      event.sequence <= watermark else {
                    throw failure(operationID, "event row/payload identity mismatch")
                }
                events.append(event)
            }
            return events
        }
    }

    package func appendEffectIntent(
        _ intent: DurableEffectIntent,
        checkpoint operation: JournalOperation
    ) throws {
        try synchronized {
            try validate(intent)
            let blob = try encoder.encode(intent)
            guard operation.snapshot.id == intent.operationID else {
                throw failure(intent.operationID, "effect intent belongs to a foreign operation")
            }
            let stored = try validateCheckpointBase(
                operation,
                context: "effect intent checkpoint"
            )
            try validateReceiptProjection(operation, allowing: nil)
            try transaction {
                if let existing = try effectIntentBlob(intent) {
                    guard existing == blob else {
                        throw failure(intent.operationID, "effect ID reused with different intent")
                    }
                } else {
                    let maxOrdinal = try maximumEffectValue(
                        operationID: intent.operationID,
                        itemID: intent.itemID,
                        column: "effect_ordinal"
                    )
                    let maxSequence = try maximumEffectValue(
                        operationID: intent.operationID,
                        itemID: intent.itemID,
                        column: "intent_sequence"
                    )
                    guard intent.effectOrdinal == maxOrdinal + 1,
                          intent.intentSequence > maxSequence,
                          intent.intentSequence > stored.latestDurableSequence,
                          intent.intentSequence <= stored.reservedThrough else {
                        throw failure(intent.operationID, "effect ordinal or intent sequence is non-monotonic")
                    }
                    try registerAttemptIfNeeded(intent)
                    let statement = try connection.statement(
                        """
                        INSERT INTO operation_effects(
                          operation_id,item_id,effect_id,attempt_id,action_id,effect_ordinal,
                          kind,node_id,relative_path,owner_epoch,intent_blob,intent_sequence,created_ms
                        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """
                    )
                    try statement.bind(intent.operationID.sqliteText, at: 1)
                    try statement.bind(intent.itemID.sqliteText, at: 2)
                    try statement.bind(intent.effectID.sqliteText, at: 3)
                    try bind(intent.attemptID?.sqliteText, to: statement, at: 4)
                    try bind(intent.actionID?.sqliteText, to: statement, at: 5)
                    try statement.bind(try sqliteInteger(intent.effectOrdinal), at: 6)
                    try statement.bind(intent.kind.rawValue, at: 7)
                    try bind(intent.nodeID, to: statement, at: 8)
                    try bind(intent.relativePath, to: statement, at: 9)
                    try statement.bind(intent.ownerEpoch.sqliteText, at: 10)
                    try statement.bind(blob, at: 11)
                    try statement.bind(try sqliteInteger(intent.intentSequence), at: 12)
                    try statement.bind(milliseconds(Date()), at: 13)
                    guard try statement.step() == SQLITE_DONE else {
                        throw failure(intent.operationID, "effect intent did not complete")
                    }
                }
                try persistOperation(
                    operation,
                    timestamp: Date(),
                    claimOwnerAndPersistRecoveryActions: false
                )
            }
            guard try effectIntentBlob(intent) == blob else {
                throw failure(intent.operationID, "effect intent read-back mismatch")
            }
        }
    }

    package func registerEffectPreparations(
        operationID: OperationID,
        itemID: OperationItemID,
        preparations: [DurableEffectPreparation],
        manifest nodes: [DurableManifestNode],
        checkpoint operation: JournalOperation
    ) throws -> DurableEffectRegistration {
        try synchronized {
            guard !preparations.isEmpty,
                  operation.snapshot.id == operationID else {
                throw failure(operationID, "effect registration is empty or foreign")
            }
            try validateManifest(nodes, operationID: operationID)
            let stored = try validateCheckpointBase(
                operation,
                context: "effect registration checkpoint"
            )
            try validateReceiptProjection(operation, allowing: nil)

            let existingManifest = try manifestLocked(
                operationID: operationID,
                itemID: itemID
            )
            guard existingManifest.isEmpty || existingManifest == nodes else {
                throw failure(operationID, "frozen manifest cannot be replaced")
            }
            let existingRecords = try effectRecordsLocked(operationID: operationID)
                .filter { $0.intent.itemID == itemID }
            if !existingRecords.isEmpty {
                let existing = existingRecords.map(\.intent)
                guard existing.count == preparations.count,
                      zip(existing, preparations).allSatisfy({
                          $0.kind == $1.kind &&
                              $0.nodeID == $1.nodeID &&
                              $0.relativePath == $1.relativePath &&
                              $0.expectedIdentity == $1.expectedIdentity &&
                              $0.manifestDigest == $1.manifestDigest
                      }) else {
                    throw failure(
                        operationID,
                        "registered mutation inventory differs from durable intents"
                    )
                }
                return DurableEffectRegistration(
                    intents: existing,
                    operation: operation
                )
            }

            let count = UInt64(preparations.count)
            let (firstSequence, firstOverflow) =
                stored.reservedThrough.addingReportingOverflow(1)
            let (lastSequence, lastOverflow) =
                firstSequence.addingReportingOverflow(count - 1)
            guard !firstOverflow, !lastOverflow,
                  Int64(exactly: lastSequence) != nil,
                  let ownerEpoch else {
                throw failure(operationID, "effect registration sequence space exhausted")
            }
            var checkpoint = operation
            checkpoint.reservedThrough = lastSequence
            var intents: [DurableEffectIntent] = []
            intents.reserveCapacity(preparations.count)
            for (index, preparation) in preparations.enumerated() {
                intents.append(DurableEffectIntent(
                    effectID: UUID(),
                    operationID: operationID,
                    itemID: itemID,
                    ownerEpoch: ownerEpoch,
                    effectOrdinal: UInt64(index + 1),
                    kind: preparation.kind,
                    nodeID: preparation.nodeID,
                    relativePath: preparation.relativePath,
                    expectedIdentity: preparation.expectedIdentity,
                    manifestDigest: preparation.manifestDigest,
                    intentSequence: firstSequence + UInt64(index)
                ))
            }

            try transaction {
                if existingManifest.isEmpty {
                    try insertManifestLocked(
                        operationID: operationID,
                        itemID: itemID,
                        nodes: nodes
                    )
                }
                for intent in intents {
                    try insertEffectIntentLocked(intent)
                }
                try persistOperation(
                    checkpoint,
                    timestamp: Date(),
                    claimOwnerAndPersistRecoveryActions: false
                )
            }
            return DurableEffectRegistration(
                intents: intents,
                operation: checkpoint
            )
        }
    }

    package func appendEffectResult(
        _ result: DurableEffectResultRecord,
        checkpoint operation: JournalOperation,
        summaryReceipt: OperationReceiptSummary?
    ) throws {
        try synchronized {
            guard operation.snapshot.id == result.operationID else {
                throw failure(result.operationID, "effect result belongs to a foreign operation")
            }
            let stored = try validateCheckpointBase(
                operation,
                context: "effect result checkpoint"
            )
            if let summaryReceipt {
                guard operation.committedEffects[result.itemID] == summaryReceipt,
                      operation.snapshot.items.first(where: {
                          $0.id == result.itemID
                      })?.receipt == summaryReceipt,
                      result.status == .completed,
                      result.resultIdentity != nil else {
                    throw failure(
                        result.operationID,
                        "effect summary receipt is not in the atomic operation checkpoint"
                    )
                }
            }
            try validateReceiptProjection(operation, allowing: summaryReceipt.map {
                (result.itemID, $0)
            })
            let blob = try encoder.encode(result)
            try transaction {
                guard let intentBlob = try effectIntentBlob(
                    operationID: result.operationID,
                    itemID: result.itemID,
                    effectID: result.effectID
                ) else {
                    throw failure(result.operationID, "effect result has no durable intent")
                }
                let intent = try decoder.decode(DurableEffectIntent.self, from: intentBlob)
                if let existing = try effectResultBlob(result) {
                    guard existing == blob else {
                        throw failure(result.operationID, "effect result is not immutable")
                    }
                } else {
                    let maxResultSequence = try maximumResultSequence(
                        operationID: result.operationID,
                        itemID: result.itemID
                    )
                    guard result.resultSequence > intent.intentSequence,
                          result.resultSequence > maxResultSequence,
                          result.resultSequence <= stored.reservedThrough,
                          result.status != .completed || result.resultIdentity != nil else {
                        throw failure(result.operationID, "effect result sequence or identity is invalid")
                    }
                    if summaryReceipt != nil {
                        try validateCompletedEffectChain(through: intent)
                    }
                    let statement = try connection.statement(
                        """
                        INSERT INTO operation_effect_results(
                          operation_id,item_id,effect_id,status,result_identity_blob,system_code,
                          result_blob,result_sequence,created_ms
                        ) VALUES(?,?,?,?,?,?,?,?,?)
                        """
                    )
                    try statement.bind(result.operationID.sqliteText, at: 1)
                    try statement.bind(result.itemID.sqliteText, at: 2)
                    try statement.bind(result.effectID.sqliteText, at: 3)
                    try statement.bind(result.status.rawValue, at: 4)
                    try bind(result.resultIdentity, to: statement, at: 5)
                    if let code = result.systemCode {
                        try statement.bind(Int64(code), at: 6)
                    } else {
                        try statement.bindNull(6)
                    }
                    try statement.bind(blob, at: 7)
                    try statement.bind(try sqliteInteger(result.resultSequence), at: 8)
                    try statement.bind(milliseconds(Date()), at: 9)
                    guard try statement.step() == SQLITE_DONE else {
                        throw failure(result.operationID, "effect result did not complete")
                    }
                }
                try persistOperation(
                    operation,
                    timestamp: Date(),
                    claimOwnerAndPersistRecoveryActions: false
                )
                if let summaryReceipt {
                    try persistReceipt(
                        summaryReceipt,
                        operationID: result.operationID,
                        itemID: result.itemID,
                        sequence: result.resultSequence
                    )
                }
            }
            guard try effectResultBlob(result) == blob else {
                throw failure(result.operationID, "effect result read-back mismatch")
            }
            try verifyPersistedRowsLocked()
        }
    }

    package func effectRecords(operationID: OperationID) throws -> [DurableEffectRecord] {
        try synchronized {
            try effectRecordsLocked(operationID: operationID)
        }
    }

    package func replaceManifest(
        operationID: OperationID,
        itemID: OperationItemID,
        nodes: [DurableManifestNode]
    ) throws {
        try synchronized {
            try validateManifest(nodes, operationID: operationID)
            let existing = try manifestLocked(operationID: operationID, itemID: itemID)
            if !existing.isEmpty {
                guard existing == nodes else {
                    throw failure(operationID, "frozen manifest cannot be replaced")
                }
                return
            }
            try transaction {
                try insertManifestLocked(
                    operationID: operationID,
                    itemID: itemID,
                    nodes: nodes
                )
            }
        }
    }

    package func manifest(
        operationID: OperationID,
        itemID: OperationItemID
    ) throws -> [DurableManifestNode] {
        try synchronized {
            try manifestLocked(operationID: operationID, itemID: itemID)
        }
    }

    package func recoveryActionIsAuthorized(
        operationID: OperationID,
        action: RecoveryAction
    ) throws -> Bool {
        try synchronized {
            let query = try connection.statement(
                """
                SELECT a.owner_epoch,a.expected_sequence,a.action_blob,a.state,o.latest_durable
                FROM recovery_action_records a
                JOIN operations o ON o.operation_id=a.operation_id
                WHERE a.operation_id=? AND a.action_id=?
                """
            )
            try query.bind(operationID.sqliteText, at: 1)
            try query.bind(action.command.actionID.sqliteText, at: 2)
            let expectedBlob = try encoder.encode(action)
            guard try query.step() == SQLITE_ROW,
                  query.text(at: 0) == lease.epoch.sqliteText,
                  UInt64(query.int64(at: 1)) == action.command.expectedSequence,
                  query.int64(at: 1) <= query.int64(at: 4),
                  query.data(at: 2) == expectedBlob,
                  let state = query.text(at: 3),
                  state == "offered" || state == "selected" else {
                return false
            }
            return true
        }
    }

    package func applyRetention(now: Date) throws -> JournalRetentionResult {
        try synchronized {
            let safe = try safeTerminalRows()
            let threshold = milliseconds(now) - 30 * 24 * 60 * 60 * 1_000
            var candidates = Set<OperationID>()
            for (index, row) in safe.enumerated() {
                if row.updatedMilliseconds < threshold || index >= 100 {
                    candidates.insert(row.id)
                }
            }
            return try deleteSafeTerminals(candidates, now: now)
        }
    }

    package func clearSafeTerminalOperations(now: Date) throws -> JournalRetentionResult {
        try synchronized {
            try deleteSafeTerminals(Set(try safeTerminalRows().map(\.id)), now: now)
        }
    }

    // MARK: - Opening and schema

    private static func preflightRecoverySetReadOnly(_ url: URL) throws {
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        let hasWAL = FileManager.default.fileExists(atPath: walURL.path)
        let hasSHM = FileManager.default.fileExists(atPath: shmURL.path)
        guard hasWAL == hasSHM else {
            throw SQLiteJournalError(
                code: -1,
                message: "journal WAL recovery set is incomplete"
            )
        }
        guard hasWAL else { return }

        let wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
        // SQLite may leave a zero-length WAL placeholder after a clean
        // checkpoint/close. It carries no recovery frames and is not a
        // recovery set that needs replay validation.
        if wal.isEmpty { return }
        guard wal.count >= 32 else {
            throw SQLiteJournalError(code: -1, message: "journal WAL header is truncated")
        }
        let magic = readBigEndianUInt32(wal, offset: 0)
        guard magic == 0x377f_0682 || magic == 0x377f_0683,
              readBigEndianUInt32(wal, offset: 4) == 3_007_000 else {
            throw SQLiteJournalError(code: -1, message: "journal WAL header is invalid")
        }
        let encodedPageSize = readBigEndianUInt32(wal, offset: 8)
        let pageSize = encodedPageSize == 1 ? 65_536 : Int(encodedPageSize)
        guard pageSize >= 512, pageSize <= 65_536,
              pageSize.nonzeroBitCount == 1,
              (wal.count - 32) % (pageSize + 24) == 0 else {
            throw SQLiteJournalError(code: -1, message: "journal WAL frame layout is invalid")
        }
        let salt1 = readBigEndianUInt32(wal, offset: 16)
        let salt2 = readBigEndianUInt32(wal, offset: 20)
        var offset = 32
        while offset < wal.count {
            guard readBigEndianUInt32(wal, offset: offset) > 0,
                  readBigEndianUInt32(wal, offset: offset + 8) == salt1,
                  readBigEndianUInt32(wal, offset: offset + 12) == salt2 else {
                throw SQLiteJournalError(
                    code: -1,
                    message: "journal WAL frame header or salt is invalid"
                )
            }
            offset += pageSize + 24
        }

        let shm = try Data(contentsOf: shmURL, options: .mappedIfSafe)
        guard shm.count >= 96,
              shm[0..<48] == shm[48..<96],
              shm[0..<48].contains(where: { $0 != 0 }) else {
            throw SQLiteJournalError(
                code: -1,
                message: "journal SHM duplicated header is invalid"
            )
        }
    }

    private static func readBigEndianUInt32(
        _ data: Data,
        offset: Int
    ) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func preflightExistingJournalReadOnly(_ url: URL) throws {
        let connection = try SQLiteConnection(url: url, readOnly: true)
        let versionQuery = try connection.statement("PRAGMA user_version")
        guard try versionQuery.step() == SQLITE_ROW else {
            throw SQLiteJournalError(code: -1, message: "read-only user_version returned no row")
        }
        let version = versionQuery.int64(at: 0)
        guard version >= 0, version <= schemaVersion else {
            throw SQLiteJournalError(code: -1, message: "unsupported future journal schema")
        }

        let tables = try schemaObjectNames(connection, type: "table")
        if version == 0 {
            guard tables.isEmpty else {
                throw SQLiteJournalError(
                    code: -1,
                    message: "unversioned journal contains unknown tables"
                )
            }
            return
        }
        guard tables == expectedTables else {
            throw SQLiteJournalError(code: -1, message: "journal schema table set mismatch")
        }

        let indexes = try schemaObjectNames(connection, type: "index")
        guard indexes == expectedIndexes else {
            throw SQLiteJournalError(code: -1, message: "journal schema index set mismatch")
        }
        try verifyCanonicalSchema(connection)
        try verifyPersistedRowsReadOnly(connection)
    }

    private static func schemaObjectNames(
        _ connection: SQLiteConnection,
        type: String
    ) throws -> Set<String> {
        let query = try connection.statement(
            """
            SELECT name FROM sqlite_master
            WHERE type=? AND name NOT LIKE 'sqlite_%'
            """
        )
        try query.bind(type, at: 1)
        var names = Set<String>()
        while try query.step() == SQLITE_ROW {
            guard let name = query.text(at: 0) else {
                throw SQLiteJournalError(code: -1, message: "schema object name is NULL")
            }
            names.insert(name)
        }
        return names
    }

    private static func verifyCanonicalSchema(_ connection: SQLiteConnection) throws {
        let query = try connection.statement(
            """
            SELECT type,name,sql FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%' AND type IN ('table','index','view','trigger')
            """
        )
        var actual: [String: String] = [:]
        while try query.step() == SQLITE_ROW {
            guard let type = query.text(at: 0),
                  let name = query.text(at: 1),
                  let sql = query.text(at: 2) else {
                throw SQLiteJournalError(code: -1, message: "schema object DDL is NULL")
            }
            actual["\(type):\(name)"] = canonicalDDL(sql)
        }
        guard actual == expectedCanonicalSchema else {
            let mismatched = Set(actual.keys).union(expectedCanonicalSchema.keys).filter {
                actual[$0] != expectedCanonicalSchema[$0]
            }.sorted()
            throw SQLiteJournalError(
                code: -1,
                message: "journal canonical DDL mismatch: \(mismatched.joined(separator: ","))"
            )
        }
    }

    private static var expectedCanonicalSchema: [String: String] {
        var result: [String: String] = [:]
        for fragment in schemaSQL.split(separator: ";") {
            let sql = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = sql.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3, words[0].uppercased() == "CREATE" else { continue }
            let type = words[1].lowercased()
            guard type == "table" || type == "index" else { continue }
            let rawName = String(words[2]).split(separator: "(", maxSplits: 1)[0]
            let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]"))
            result["\(type):\(name)"] = canonicalDDL(sql)
        }
        return result
    }

    private static func canonicalDDL(_ sql: String) -> String {
        sql.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != ";" }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func verifyPersistedRowsReadOnly(_ connection: SQLiteConnection) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970

        let operationsQuery = try connection.statement(
            """
            SELECT operation_id,envelope_version,kind,state,request_blob,snapshot_blob,
                   submission_ordinal,latest_durable,latest_emitted,reserved_through,partial_flags
            FROM operations
            """
        )
        var operations: [String: JournalOperation] = [:]
        while try operationsQuery.step() == SQLITE_ROW {
            guard let id = operationsQuery.text(at: 0),
                  let requestBlob = operationsQuery.data(at: 4),
                  let snapshotBlob = operationsQuery.data(at: 5) else {
                throw SQLiteJournalError(code: -1, message: "operation normalized row is incomplete")
            }
            let operation = try decoder.decode(JournalOperation.self, from: snapshotBlob)
            guard operation.snapshot.id.sqliteText == id,
                  operationsQuery.int64(at: 1) == 1,
                  operation.snapshot.kind.rawValue == operationsQuery.text(at: 2),
                  operation.snapshot.state.rawValue == operationsQuery.text(at: 3),
                  try encoder.encode(operation.snapshot.request) == requestBlob,
                  Int64(exactly: operation.submissionOrdinal) == operationsQuery.int64(at: 6),
                  Int64(exactly: operation.latestDurableSequence) == operationsQuery.int64(at: 7),
                  Int64(exactly: operation.latestEmittedSequence) == operationsQuery.int64(at: 8),
                  Int64(exactly: operation.reservedThrough) == operationsQuery.int64(at: 9),
                  (operation.snapshot.hasPartialCommit ? 1 : 0) == operationsQuery.int64(at: 10),
                  operation.snapshot.schemaVersion == 1,
                  operation.snapshot.request.schemaVersion == 1,
                  operation.latestDurableSequence <= operation.latestEmittedSequence,
                  operation.latestEmittedSequence <= operation.reservedThrough,
                  operations[id] == nil else {
                throw SQLiteJournalError(code: -1, message: "operation row/blob mismatch")
            }
            operations[id] = operation
        }

        let itemsQuery = try connection.statement(
            """
            SELECT operation_id,item_id,item_ordinal,source_url,destination_url,state,
                   quarantine_url,progress_blob,verification_blob,failure_blob
            FROM operation_items
            """
        )
        while try itemsQuery.step() == SQLITE_ROW {
            guard let operationID = itemsQuery.text(at: 0),
                  let itemID = itemsQuery.text(at: 1),
                  let operation = operations[operationID],
                  itemsQuery.int64(at: 2) >= 0,
                  Int(itemsQuery.int64(at: 2)) < operation.snapshot.items.count,
                  let progressBlob = itemsQuery.data(at: 7) else {
                throw SQLiteJournalError(code: -1, message: "operation item row is incomplete")
            }
            let item = operation.snapshot.items[Int(itemsQuery.int64(at: 2))]
            guard item.id.sqliteText == itemID,
                  item.source.absoluteString == itemsQuery.text(at: 3),
                  item.destination?.absoluteString == itemsQuery.text(at: 4),
                  item.state.rawValue == itemsQuery.text(at: 5),
                  item.receipt?.quarantineURL?.absoluteString == itemsQuery.text(at: 6),
                  try encoder.encode(item.progress) == progressBlob,
                  try item.verification.map(encoder.encode) == itemsQuery.data(at: 8),
                  try item.failure.map(encoder.encode) == itemsQuery.data(at: 9) else {
                throw SQLiteJournalError(code: -1, message: "operation item row/blob mismatch")
            }
        }

        let receiptsQuery = try connection.statement(
            """
            SELECT operation_id,item_id,summary_blob,committed_identity_blob,backup_url,
                   quarantine_url,source_cleanup_state,receipt_sequence
            FROM operation_receipts
            """
        )
        while try receiptsQuery.step() == SQLITE_ROW {
            guard let operationID = receiptsQuery.text(at: 0),
                  let itemID = receiptsQuery.text(at: 1),
                  let blob = receiptsQuery.data(at: 2),
                  let identity = receiptsQuery.data(at: 3),
                  receiptsQuery.int64(at: 7) >= 0 else {
                throw SQLiteJournalError(code: -1, message: "receipt normalized row is incomplete")
            }
            let receipt = try decoder.decode(OperationReceiptSummary.self, from: blob)
            guard identity == Data(receipt.committedIdentityDigest.utf8),
                  receipt.backupURL?.absoluteString == receiptsQuery.text(at: 4),
                  receipt.quarantineURL?.absoluteString == receiptsQuery.text(at: 5),
                  (receipt.sourceCleanupPending ? "pending" : "complete") == receiptsQuery.text(at: 6),
                  operations[operationID]?.snapshot.items.contains(where: {
                      $0.id.sqliteText == itemID && $0.receipt == receipt
                  }) == true,
                  operations[operationID]?.committedEffects.first(where: {
                      $0.key.sqliteText == itemID
                  })?.value == receipt else {
                throw SQLiteJournalError(code: -1, message: "receipt row/blob/projection mismatch")
            }
        }

        try verifyEffectRows(connection, decoder: decoder)
        try verifyActionRows(connection, decoder: decoder)
        try verifyEventRows(connection, decoder: decoder)
    }

    private static func verifyEffectRows(
        _ connection: SQLiteConnection,
        decoder: JSONDecoder
    ) throws {
        let intents = try connection.statement(
            """
            SELECT operation_id,item_id,effect_id,attempt_id,action_id,effect_ordinal,kind,
                   node_id,relative_path,owner_epoch,intent_blob,intent_sequence
            FROM operation_effects
            """
        )
        while try intents.step() == SQLITE_ROW {
            guard let blob = intents.data(at: 10) else {
                throw SQLiteJournalError(code: -1, message: "effect intent blob is NULL")
            }
            let intent = try decoder.decode(DurableEffectIntent.self, from: blob)
            guard intent.operationID.sqliteText == intents.text(at: 0),
                  intent.itemID.sqliteText == intents.text(at: 1),
                  intent.effectID.sqliteText == intents.text(at: 2),
                  intent.attemptID?.sqliteText == intents.text(at: 3),
                  intent.actionID?.sqliteText == intents.text(at: 4),
                  Int64(exactly: intent.effectOrdinal) == intents.int64(at: 5),
                  intent.kind.rawValue == intents.text(at: 6),
                  intent.nodeID == intents.text(at: 7),
                  intent.relativePath == intents.text(at: 8),
                  intent.ownerEpoch.sqliteText == intents.text(at: 9),
                  Int64(exactly: intent.intentSequence) == intents.int64(at: 11) else {
                throw SQLiteJournalError(code: -1, message: "effect intent row/blob mismatch")
            }
        }

        let results = try connection.statement(
            """
            SELECT operation_id,item_id,effect_id,status,result_identity_blob,system_code,
                   result_blob,result_sequence
            FROM operation_effect_results
            """
        )
        while try results.step() == SQLITE_ROW {
            guard let blob = results.data(at: 6) else {
                throw SQLiteJournalError(code: -1, message: "effect result blob is NULL")
            }
            let result = try decoder.decode(DurableEffectResultRecord.self, from: blob)
            let code: Int32? = results.isNull(at: 5)
                ? nil
                : Int32(exactly: results.int64(at: 5))
            guard result.operationID.sqliteText == results.text(at: 0),
                  result.itemID.sqliteText == results.text(at: 1),
                  result.effectID.sqliteText == results.text(at: 2),
                  result.status.rawValue == results.text(at: 3),
                  result.resultIdentity == results.data(at: 4),
                  result.systemCode == code,
                  Int64(exactly: result.resultSequence) == results.int64(at: 7) else {
                throw SQLiteJournalError(code: -1, message: "effect result row/blob mismatch")
            }
        }
    }

    private static func verifyActionRows(
        _ connection: SQLiteConnection,
        decoder: JSONDecoder
    ) throws {
        let query = try connection.statement(
            """
            SELECT operation_id,action_id,owner_epoch,expected_sequence,action_blob,state
            FROM recovery_action_records
            """
        )
        while try query.step() == SQLITE_ROW {
            guard let blob = query.data(at: 4) else {
                throw SQLiteJournalError(code: -1, message: "recovery action blob is NULL")
            }
            let action = try decoder.decode(RecoveryAction.self, from: blob)
            guard action.command.actionID.sqliteText == query.text(at: 1),
                  Int64(exactly: action.command.expectedSequence) == query.int64(at: 3),
                  query.text(at: 0) != nil,
                  query.text(at: 2) != nil,
                  ["offered", "selected", "completed", "rejected"].contains(query.text(at: 5) ?? "")
            else {
                throw SQLiteJournalError(code: -1, message: "recovery action row/blob mismatch")
            }
        }
    }

    private static func verifyEventRows(
        _ connection: SQLiteConnection,
        decoder: JSONDecoder
    ) throws {
        let query = try connection.statement(
            """
            SELECT operation_id,sequence,item_id,envelope_version,payload_blob
            FROM operation_events
            """
        )
        while try query.step() == SQLITE_ROW {
            guard let blob = query.data(at: 4) else {
                throw SQLiteJournalError(code: -1, message: "operation event blob is NULL")
            }
            let event = try decoder.decode(OperationEvent.self, from: blob)
            guard event.operationID.sqliteText == query.text(at: 0),
                  Int64(exactly: event.sequence) == query.int64(at: 1),
                  event.itemID?.sqliteText == query.text(at: 2),
                  query.int64(at: 3) == 1 else {
                throw SQLiteJournalError(code: -1, message: "operation event row/blob mismatch")
            }
        }
    }

    private func verifyPersistedRowsLocked() throws {
        try Self.verifyPersistedRowsReadOnly(connection)
    }

    private func configureConnection() throws {
        let mode = try scalarText("PRAGMA journal_mode=WAL")
        guard mode?.lowercased() == "wal" else {
            throw SQLiteJournalError(code: -1, message: "journal_mode is not WAL")
        }
        try connection.execute("PRAGMA foreign_keys=ON")
        guard try scalarInt("PRAGMA foreign_keys") == 1 else {
            throw SQLiteJournalError(code: -1, message: "foreign_keys is not enabled")
        }
        try connection.execute("PRAGMA synchronous=FULL")
        guard try scalarInt("PRAGMA synchronous") == 2 else {
            throw SQLiteJournalError(code: -1, message: "synchronous is not FULL")
        }
    }

    private func migrateIfNeeded() throws {
        guard let version = try scalarInt("PRAGMA user_version") else {
            throw SQLiteJournalError(code: -1, message: "user_version returned no row")
        }
        guard version >= 0, version <= Self.schemaVersion else {
            throw SQLiteJournalError(code: -1, message: "unsupported future journal schema")
        }
        guard version == 0 else { return }
        let existing = try scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%'
            """
        ) ?? 0
        guard existing == 0 else {
            throw SQLiteJournalError(code: -1, message: "unversioned journal contains unknown tables")
        }
        try transaction {
            try connection.execute(Self.schemaSQL)
            let sqliteVersion = try connection.statement(
                "INSERT INTO journal_meta(key,value) VALUES('sqlite_version',?)"
            )
            try sqliteVersion.bind(connection.runtimeVersion, at: 1)
            guard try sqliteVersion.step() == SQLITE_DONE else {
                throw SQLiteJournalError(
                    code: -1,
                    message: "SQLite creation version was not recorded"
                )
            }
            try connection.execute("PRAGMA user_version=1")
        }
    }

    private func verifyIntegrity() throws {
        let integrity = try connection.statement("PRAGMA integrity_check")
        var rows: [String] = []
        while try integrity.step() == SQLITE_ROW {
            rows.append(integrity.text(at: 0) ?? "")
        }
        guard rows == ["ok"] else {
            throw SQLiteJournalError(code: -1, message: "integrity_check failed: \(rows.joined(separator: ";"))")
        }

        let foreignKeys = try connection.statement("PRAGMA foreign_key_check")
        guard try foreignKeys.step() == SQLITE_DONE else {
            throw SQLiteJournalError(code: -1, message: "foreign_key_check found violations")
        }
    }

    private func verifyExpectedSchema() throws {
        let names = try Self.schemaObjectNames(connection, type: "table")
        guard names == Self.expectedTables else {
            throw SQLiteJournalError(code: -1, message: "journal schema table set mismatch")
        }
        let indexNames = try Self.schemaObjectNames(connection, type: "index")
        guard indexNames == Self.expectedIndexes else {
            throw SQLiteJournalError(code: -1, message: "journal schema index set mismatch")
        }
        guard try scalarText(
            "SELECT CAST(value AS TEXT) FROM journal_meta WHERE key='schema_version'"
        ) == "1",
            try scalarText(
                "SELECT CAST(value AS TEXT) FROM journal_meta WHERE key='sqlite_version'"
            ) != nil else {
            throw SQLiteJournalError(code: -1, message: "journal metadata is incomplete")
        }
        try Self.verifyCanonicalSchema(connection)
    }

    private func registerOwnerEpoch() throws {
        try transaction {
            let statement = try connection.statement(
                """
                INSERT INTO owner_epochs(epoch,pid,started_ms,sqlite_version)
                VALUES(?,?,?,?)
                """
            )
            try statement.bind(lease.epoch.sqliteText, at: 1)
            try statement.bind(Int64(ProcessInfo.processInfo.processIdentifier), at: 2)
            try statement.bind(milliseconds(Date()), at: 3)
            try statement.bind(connection.runtimeVersion, at: 4)
            guard try statement.step() == SQLITE_DONE else {
                throw SQLiteJournalError(code: -1, message: "owner epoch insert did not complete")
            }
        }
    }

    // MARK: - Persistence

    private func effectRecordsLocked(
        operationID: OperationID
    ) throws -> [DurableEffectRecord] {
        let query = try connection.statement(
            """
            SELECT e.intent_blob, r.result_blob
            FROM operation_effects e
            LEFT JOIN operation_effect_results r
              ON r.operation_id=e.operation_id
             AND r.item_id=e.item_id
             AND r.effect_id=e.effect_id
            WHERE e.operation_id=?
            ORDER BY e.item_id,e.effect_ordinal
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        var records: [DurableEffectRecord] = []
        while try query.step() == SQLITE_ROW {
            guard let intentBlob = query.data(at: 0) else {
                throw failure(operationID, "effect intent payload is NULL")
            }
            let intent = try decoder.decode(DurableEffectIntent.self, from: intentBlob)
            let result = try query.data(at: 1).map {
                try decoder.decode(DurableEffectResultRecord.self, from: $0)
            }
            records.append(DurableEffectRecord(intent: intent, result: result))
        }
        return records
    }

    private func insertEffectIntentLocked(_ intent: DurableEffectIntent) throws {
        try validate(intent)
        try registerAttemptIfNeeded(intent)
        let statement = try connection.statement(
            """
            INSERT INTO operation_effects(
              operation_id,item_id,effect_id,attempt_id,action_id,effect_ordinal,
              kind,node_id,relative_path,owner_epoch,intent_blob,intent_sequence,created_ms
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
        try statement.bind(intent.operationID.sqliteText, at: 1)
        try statement.bind(intent.itemID.sqliteText, at: 2)
        try statement.bind(intent.effectID.sqliteText, at: 3)
        try bind(intent.attemptID?.sqliteText, to: statement, at: 4)
        try bind(intent.actionID?.sqliteText, to: statement, at: 5)
        try statement.bind(try sqliteInteger(intent.effectOrdinal), at: 6)
        try statement.bind(intent.kind.rawValue, at: 7)
        try bind(intent.nodeID, to: statement, at: 8)
        try bind(intent.relativePath, to: statement, at: 9)
        try statement.bind(intent.ownerEpoch.sqliteText, at: 10)
        try statement.bind(try encoder.encode(intent), at: 11)
        try statement.bind(try sqliteInteger(intent.intentSequence), at: 12)
        try statement.bind(milliseconds(Date()), at: 13)
        guard try statement.step() == SQLITE_DONE else {
            throw failure(intent.operationID, "effect intent did not complete")
        }
    }

    private func insertManifestLocked(
        operationID: OperationID,
        itemID: OperationItemID,
        nodes: [DurableManifestNode]
    ) throws {
        let insert = try connection.statement(
            """
            INSERT INTO manifest_nodes(
              operation_id,item_id,node_id,parent_node_id,relative_path,
              depth,kind,identity_blob,digest,purge_ordinal
            ) VALUES(?,?,?,?,?,?,?,?,?,?)
            """
        )
        for node in nodes {
            try insert.bind(operationID.sqliteText, at: 1)
            try insert.bind(itemID.sqliteText, at: 2)
            try insert.bind(node.nodeID, at: 3)
            try bind(node.parentNodeID, to: insert, at: 4)
            try insert.bind(node.relativePath, at: 5)
            try insert.bind(Int64(node.depth), at: 6)
            try insert.bind(node.kind.rawValue, at: 7)
            try insert.bind(node.identity, at: 8)
            try bind(node.digest, to: insert, at: 9)
            try insert.bind(try sqliteInteger(node.purgeOrdinal), at: 10)
            guard try insert.step() == SQLITE_DONE else {
                throw failure(operationID, "manifest node insert did not complete")
            }
            try insert.reset()
        }
    }

    private func loadOperationsLocked() throws -> [JournalOperation] {
        let query = try connection.statement(
            "SELECT snapshot_blob FROM operations ORDER BY submission_ordinal ASC"
        )
        var operations: [JournalOperation] = []
        var ids = Set<OperationID>()
        while try query.step() == SQLITE_ROW {
            guard let blob = query.data(at: 0) else {
                throw SQLiteJournalError(code: -1, message: "operation snapshot is NULL")
            }
            let operation = try decoder.decode(JournalOperation.self, from: blob)
            try validate(operation)
            guard ids.insert(operation.snapshot.id).inserted else {
                throw failure(operation.snapshot.id, "duplicate decoded operation")
            }
            operations.append(operation)
        }
        return operations
    }

    private func persistOperation(
        _ operation: JournalOperation,
        timestamp: Date,
        claimOwnerAndPersistRecoveryActions: Bool = true
    ) throws {
        try validate(operation)
        let snapshotBlob = try encoder.encode(operation)
        let requestBlob = try encoder.encode(operation.snapshot.request)
        let errorBlob = try operation.snapshot.terminalFailure.map(encoder.encode)
        let persistedOwnerEpoch: String
        if claimOwnerAndPersistRecoveryActions {
            persistedOwnerEpoch = lease.epoch.sqliteText
        } else {
            let ownerQuery = try connection.statement(
                "SELECT owner_epoch FROM operations WHERE operation_id=?"
            )
            try ownerQuery.bind(operation.snapshot.id.sqliteText, at: 1)
            guard try ownerQuery.step() == SQLITE_ROW,
                  let existingOwnerEpoch = ownerQuery.text(at: 0) else {
                throw failure(
                    operation.snapshot.id,
                    "owner-preserving checkpoint references an unknown operation"
                )
            }
            persistedOwnerEpoch = existingOwnerEpoch
        }
        let statement = try connection.statement(
            """
            INSERT INTO operations(
              operation_id,envelope_version,kind,state,request_blob,snapshot_blob,
              submission_ordinal,latest_durable,latest_emitted,reserved_through,
              owner_epoch,created_ms,updated_ms,terminal_error_blob,partial_flags
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(operation_id) DO UPDATE SET
              envelope_version=excluded.envelope_version,
              kind=excluded.kind,state=excluded.state,request_blob=excluded.request_blob,
              snapshot_blob=excluded.snapshot_blob,submission_ordinal=excluded.submission_ordinal,
              latest_durable=excluded.latest_durable,latest_emitted=excluded.latest_emitted,
              reserved_through=excluded.reserved_through,owner_epoch=excluded.owner_epoch,
              updated_ms=CASE
                WHEN operations.state IN (
                  'completed','completedWithSkips','completedWithSourceRetained',
                  'cancelled','rolledBack'
                ) AND excluded.state=operations.state
                THEN operations.updated_ms ELSE excluded.updated_ms END,
              terminal_error_blob=excluded.terminal_error_blob,
              partial_flags=excluded.partial_flags
            """
        )
        try statement.bind(operation.snapshot.id.sqliteText, at: 1)
        try statement.bind(1, at: 2)
        try statement.bind(operation.snapshot.kind.rawValue, at: 3)
        try statement.bind(operation.snapshot.state.rawValue, at: 4)
        try statement.bind(requestBlob, at: 5)
        try statement.bind(snapshotBlob, at: 6)
        try statement.bind(try sqliteInteger(operation.submissionOrdinal), at: 7)
        try statement.bind(try sqliteInteger(operation.latestDurableSequence), at: 8)
        try statement.bind(try sqliteInteger(operation.latestEmittedSequence), at: 9)
        try statement.bind(try sqliteInteger(operation.reservedThrough), at: 10)
        try statement.bind(persistedOwnerEpoch, at: 11)
        try statement.bind(milliseconds(timestamp), at: 12)
        try statement.bind(milliseconds(timestamp), at: 13)
        try bind(errorBlob, to: statement, at: 14)
        try statement.bind(operation.snapshot.hasPartialCommit ? 1 : 0, at: 15)
        guard try statement.step() == SQLITE_DONE else {
            throw failure(operation.snapshot.id, "operation upsert did not complete")
        }

        for (ordinal, item) in operation.snapshot.items.enumerated() {
            try persistItem(item, operationID: operation.snapshot.id, ordinal: ordinal)
        }
        if claimOwnerAndPersistRecoveryActions {
            try persistRecoveryActions(operation)
        }
    }

    private func persistItem(
        _ item: OperationItemSnapshot,
        operationID: OperationID,
        ordinal: Int
    ) throws {
        let progress = try encoder.encode(item.progress)
        let verification = try item.verification.map(encoder.encode)
        let failureBlob = try item.failure.map(encoder.encode)
        let quarantine = item.receipt?.quarantineURL?.absoluteString
        let statement = try connection.statement(
            """
            INSERT INTO operation_items(
              operation_id,item_id,item_ordinal,source_url,destination_url,identity_blob,
              state,staging_url,quarantine_url,progress_blob,verification_blob,failure_blob
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(operation_id,item_id) DO UPDATE SET
              item_ordinal=excluded.item_ordinal,source_url=excluded.source_url,
              destination_url=excluded.destination_url,state=excluded.state,
              quarantine_url=excluded.quarantine_url,progress_blob=excluded.progress_blob,
              verification_blob=excluded.verification_blob,failure_blob=excluded.failure_blob
            """
        )
        try statement.bind(operationID.sqliteText, at: 1)
        try statement.bind(item.id.sqliteText, at: 2)
        try statement.bind(Int64(ordinal), at: 3)
        try statement.bind(item.source.absoluteString, at: 4)
        try bind(item.destination?.absoluteString, to: statement, at: 5)
        try statement.bindNull(6)
        try statement.bind(item.state.rawValue, at: 7)
        try statement.bindNull(8)
        try bind(quarantine, to: statement, at: 9)
        try statement.bind(progress, at: 10)
        try bind(verification, to: statement, at: 11)
        try bind(failureBlob, to: statement, at: 12)
        guard try statement.step() == SQLITE_DONE else {
            throw failure(operationID, "item upsert did not complete")
        }
    }

    private func persistReceipt(
        _ receipt: OperationReceiptSummary,
        operationID: OperationID,
        itemID: OperationItemID,
        sequence: EventSequence
    ) throws {
        let blob = try encoder.encode(receipt)
        let existingQuery = try connection.statement(
            """
            SELECT summary_blob,receipt_sequence
            FROM operation_receipts
            WHERE operation_id=? AND item_id=?
            """
        )
        try existingQuery.bind(operationID.sqliteText, at: 1)
        try existingQuery.bind(itemID.sqliteText, at: 2)
        if try existingQuery.step() == SQLITE_ROW {
            guard let existingBlob = existingQuery.data(at: 0) else {
                throw failure(operationID, "existing receipt summary is NULL")
            }
            let existing = try decoder.decode(
                OperationReceiptSummary.self,
                from: existingBlob
            )
            let identical = existing == receipt
            let cleanupConvergence =
                existing.committedIdentityDigest == receipt.committedIdentityDigest &&
                existing.backupURL == receipt.backupURL &&
                existing.sourceCleanupPending &&
                !receipt.sourceCleanupPending &&
                existing.quarantineURL != nil &&
                receipt.quarantineURL == nil
            let existingSequence = UInt64(existingQuery.int64(at: 1))
            if identical, sequence < existingSequence {
                return
            }
            guard (identical || cleanupConvergence),
                  sequence >= existingSequence else {
                throw failure(
                    operationID,
                    "receipt attempted a non-monotonic identity or cleanup update"
                )
            }
        }
        let statement = try connection.statement(
            """
            INSERT INTO operation_receipts(
              operation_id,item_id,summary_blob,committed_identity_blob,
              backup_url,quarantine_url,manifest_digest,source_cleanup_state,
              receipt_sequence,created_ms
            ) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(operation_id,item_id) DO UPDATE SET
              summary_blob=excluded.summary_blob,
              committed_identity_blob=excluded.committed_identity_blob,
              backup_url=excluded.backup_url,
              quarantine_url=excluded.quarantine_url,
              source_cleanup_state=excluded.source_cleanup_state,
              receipt_sequence=excluded.receipt_sequence
            """
        )
        try statement.bind(operationID.sqliteText, at: 1)
        try statement.bind(itemID.sqliteText, at: 2)
        try statement.bind(blob, at: 3)
        try statement.bind(Data(receipt.committedIdentityDigest.utf8), at: 4)
        try bind(receipt.backupURL?.absoluteString, to: statement, at: 5)
        try bind(receipt.quarantineURL?.absoluteString, to: statement, at: 6)
        try statement.bindNull(7)
        try statement.bind(receipt.sourceCleanupPending ? "pending" : "complete", at: 8)
        try statement.bind(try sqliteInteger(sequence), at: 9)
        try statement.bind(milliseconds(Date()), at: 10)
        guard try statement.step() == SQLITE_DONE else {
            throw failure(operationID, "receipt upsert did not complete")
        }
    }

    private func insertEvent(_ event: OperationEvent) throws {
        let blob = try encoder.encode(event)
        let statement = try connection.statement(
            """
            INSERT INTO operation_events(
              operation_id,sequence,item_id,envelope_version,payload_blob,created_ms
            ) VALUES(?,?,?,?,?,?)
            """
        )
        try statement.bind(event.operationID.sqliteText, at: 1)
        try statement.bind(try sqliteInteger(event.sequence), at: 2)
        try bind(event.itemID?.sqliteText, to: statement, at: 3)
        try statement.bind(1, at: 4)
        try statement.bind(blob, at: 5)
        try statement.bind(milliseconds(event.timestamp), at: 6)
        guard try statement.step() == SQLITE_DONE else {
            throw failure(event.operationID, "event insert did not complete")
        }
    }

    private func persistRecoveryActions(_ operation: JournalOperation) throws {
        let operationID = operation.snapshot.id
        let actions = operation.snapshot.availableActions
        let currentIDs = Set(actions.map(\.command.actionID.sqliteText))
        let rejectStaleOwner = try connection.statement(
            """
            UPDATE recovery_action_records
            SET state='rejected',updated_ms=?
            WHERE operation_id=? AND owner_epoch<>?
              AND state IN ('offered','selected')
            """
        )
        try rejectStaleOwner.bind(milliseconds(Date()), at: 1)
        try rejectStaleOwner.bind(operationID.sqliteText, at: 2)
        try rejectStaleOwner.bind(lease.epoch.sqliteText, at: 3)
        guard try rejectStaleOwner.step() == SQLITE_DONE else {
            throw failure(operationID, "stale owner recovery action revocation did not complete")
        }
        let offered = try connection.statement(
            """
            SELECT action_id FROM recovery_action_records
            WHERE operation_id=? AND owner_epoch=? AND state='offered'
            """
        )
        try offered.bind(operationID.sqliteText, at: 1)
        try offered.bind(lease.epoch.sqliteText, at: 2)
        var revokedIDs: [String] = []
        while try offered.step() == SQLITE_ROW {
            if let actionID = offered.text(at: 0), !currentIDs.contains(actionID) {
                revokedIDs.append(actionID)
            }
        }
        let reject = try connection.statement(
            """
            UPDATE recovery_action_records
            SET state='rejected',updated_ms=?
            WHERE operation_id=? AND action_id=? AND owner_epoch=? AND state='offered'
            """
        )
        for actionID in revokedIDs {
            try reject.bind(milliseconds(Date()), at: 1)
            try reject.bind(operationID.sqliteText, at: 2)
            try reject.bind(actionID, at: 3)
            try reject.bind(lease.epoch.sqliteText, at: 4)
            guard try reject.step() == SQLITE_DONE else {
                throw failure(operationID, "recovery action revocation did not complete")
            }
            try reject.reset()
        }

        for action in actions {
            let command = action.command
            let state = operation.inProgressRecoveryActions.contains(command.actionID)
                ? "selected" : "offered"
            try persistRecoveryAction(
                operationID: operationID,
                action: action,
                state: state
            )
        }
        for actionID in operation.completedRecoveryActions {
            let update = try connection.statement(
                """
                UPDATE recovery_action_records
                SET state='completed',updated_ms=?
                WHERE operation_id=? AND action_id=? AND owner_epoch=?
                """
            )
            try update.bind(milliseconds(Date()), at: 1)
            try update.bind(operationID.sqliteText, at: 2)
            try update.bind(actionID.sqliteText, at: 3)
            try update.bind(lease.epoch.sqliteText, at: 4)
            guard try update.step() == SQLITE_DONE else {
                throw failure(operationID, "recovery action completion did not complete")
            }
        }
    }

    private func persistRecoveryAction(
        operationID: OperationID,
        action: RecoveryAction,
        state: String
    ) throws {
        let command = action.command
        guard let operation = try self.operation(id: operationID) else {
            throw failure(operationID, "recovery action references an unknown operation")
        }
        let blob = try encoder.encode(action)
        let query = try connection.statement(
            """
            SELECT owner_epoch,expected_sequence,action_blob,state
            FROM recovery_action_records
            WHERE operation_id=? AND action_id=?
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        try query.bind(command.actionID.sqliteText, at: 2)
        if try query.step() == SQLITE_ROW {
            let recordedOwnerEpoch = query.text(at: 0)
            guard recordedOwnerEpoch == lease.epoch.sqliteText,
                  UInt64(query.int64(at: 1)) == command.expectedSequence,
                  query.data(at: 2) == blob else {
                throw failure(
                    operationID,
                    "recovery action \(command.actionID) cannot be rebound from owner " +
                        "\(recordedOwnerEpoch ?? "<missing>") to \(lease.epoch)"
                )
            }
            let existingState = query.text(at: 3) ?? ""
            guard existingState == state ||
                    (existingState == "offered" && state == "selected") ||
                    (existingState == "selected" && state == "completed") else {
                throw failure(operationID, "illegal recovery action state transition")
            }
            let update = try connection.statement(
                """
                UPDATE recovery_action_records
                SET state=?,updated_ms=?
                WHERE operation_id=? AND action_id=? AND owner_epoch=?
                """
            )
            try update.bind(state, at: 1)
            try update.bind(milliseconds(Date()), at: 2)
            try update.bind(operationID.sqliteText, at: 3)
            try update.bind(command.actionID.sqliteText, at: 4)
            try update.bind(lease.epoch.sqliteText, at: 5)
            guard try update.step() == SQLITE_DONE else {
                throw failure(operationID, "recovery action update did not complete")
            }
            return
        }

        guard command.expectedSequence == operation.latestDurableSequence else {
            throw failure(operationID, "new recovery action expected sequence is stale")
        }

        let insert = try connection.statement(
            """
            INSERT INTO recovery_action_records(
              operation_id,action_id,owner_epoch,expected_sequence,action_blob,
              state,created_ms,updated_ms
            ) VALUES(?,?,?,?,?,?,?,?)
            """
        )
        let now = milliseconds(Date())
        try insert.bind(operationID.sqliteText, at: 1)
        try insert.bind(command.actionID.sqliteText, at: 2)
        try insert.bind(lease.epoch.sqliteText, at: 3)
        try insert.bind(try sqliteInteger(command.expectedSequence), at: 4)
        try insert.bind(blob, at: 5)
        try insert.bind(state, at: 6)
        try insert.bind(now, at: 7)
        try insert.bind(now, at: 8)
        guard try insert.step() == SQLITE_DONE else {
            throw failure(operationID, "recovery action insert did not complete")
        }
    }

    // MARK: - Retention

    private struct TerminalRow {
        let id: OperationID
        let updatedMilliseconds: Int64
    }

    private func safeTerminalRows() throws -> [TerminalRow] {
        let placeholders = Self.terminalStates.map { _ in "?" }.joined(separator: ",")
        let query = try connection.statement(
            """
            SELECT o.operation_id,o.updated_ms
            FROM operations o
            WHERE o.state IN (\(placeholders))
              AND NOT EXISTS (
                SELECT 1 FROM operation_effects e
                LEFT JOIN operation_effect_results r
                  ON r.operation_id=e.operation_id
                 AND r.item_id=e.item_id
                 AND r.effect_id=e.effect_id
                WHERE e.operation_id=o.operation_id
                  AND (r.effect_id IS NULL OR r.status<>'completed'
                       OR r.result_identity_blob IS NULL)
              )
              AND NOT EXISTS (
                SELECT 1 FROM recovery_action_records a
                WHERE a.operation_id=o.operation_id
                  AND a.state IN ('offered','selected')
              )
              AND NOT EXISTS (
                SELECT 1 FROM operation_receipts p
                WHERE p.operation_id=o.operation_id
                  AND (p.source_cleanup_state='pending'
                       OR (p.backup_url IS NOT NULL AND NOT EXISTS (
                         SELECT 1 FROM operation_effects pe
                         JOIN operation_effect_results pr
                           ON pr.operation_id=pe.operation_id
                          AND pr.item_id=pe.item_id
                          AND pr.effect_id=pe.effect_id
                         WHERE pe.operation_id=p.operation_id
                           AND pe.item_id=p.item_id
                           AND pe.kind='purgeBackup'
                           AND pr.status='completed'
                           AND pr.result_identity_blob IS NOT NULL
                       ))
                       OR p.quarantine_url IS NOT NULL)
              )
            ORDER BY o.updated_ms DESC,o.operation_id DESC
            """
        )
        for (index, state) in Self.terminalStates.enumerated() {
            try query.bind(state, at: Int32(index + 1))
        }
        var rows: [TerminalRow] = []
        while try query.step() == SQLITE_ROW {
            guard let idText = query.text(at: 0), let id = OperationID(sqliteText: idText) else {
                throw SQLiteJournalError(code: -1, message: "invalid operation ID in retention query")
            }
            rows.append(TerminalRow(id: id, updatedMilliseconds: query.int64(at: 1)))
        }
        return rows
    }

    private func deleteSafeTerminals(
        _ candidates: Set<OperationID>,
        now: Date
    ) throws -> JournalRetentionResult {
        guard !candidates.isEmpty else {
            return JournalRetentionResult(deletedOperationIDs: [])
        }
        let ordered = candidates.sorted { $0.sqliteText < $1.sqliteText }
        try transaction {
            let currentlySafe = Set(try safeTerminalRows().map(\.id))
            guard candidates.isSubset(of: currentlySafe) else {
                throw SQLiteJournalError(code: -1, message: "retention candidate changed before delete")
            }
            let delete = try connection.statement("DELETE FROM operations WHERE operation_id=?")
            for id in ordered {
                try delete.bind(id.sqliteText, at: 1)
                guard try delete.step() == SQLITE_DONE else {
                    throw failure(id, "retention delete did not complete")
                }
                try delete.reset()
            }
            _ = now
        }
        return JournalRetentionResult(deletedOperationIDs: ordered)
    }

    // MARK: - Helpers

    private func operation(id: OperationID) throws -> JournalOperation? {
        guard let blob = try operationBlob(id: id) else { return nil }
        let operation = try decoder.decode(JournalOperation.self, from: blob)
        try validate(operation)
        return operation
    }

    private func operationBlob(id: OperationID) throws -> Data? {
        let query = try connection.statement(
            "SELECT snapshot_blob FROM operations WHERE operation_id=?"
        )
        try query.bind(id.sqliteText, at: 1)
        guard try query.step() == SQLITE_ROW else { return nil }
        return query.data(at: 0)
    }

    private func nextSubmissionOrdinal() throws -> UInt64 {
        let value = try scalarInt("SELECT COALESCE(MAX(submission_ordinal),0)+1 FROM operations") ?? 1
        guard value > 0 else {
            throw SQLiteJournalError(code: -1, message: "submission ordinal exhausted")
        }
        return UInt64(value)
    }

    private func validate(_ operation: JournalOperation) throws {
        guard operation.snapshot.schemaVersion == 1,
              operation.snapshot.request.schemaVersion == 1,
              operation.latestDurableSequence <= operation.latestEmittedSequence,
              operation.latestEmittedSequence <= operation.reservedThrough,
              Int64(exactly: operation.submissionOrdinal) != nil,
              Int64(exactly: operation.reservedThrough) != nil else {
            throw failure(operation.snapshot.id, "invalid or unsupported operation envelope")
        }
    }

    private func validate(_ intent: DurableEffectIntent) throws {
        guard intent.ownerEpoch == lease.epoch else {
            throw failure(intent.operationID, "stale owner epoch effect intent")
        }
        if let relativePath = intent.relativePath {
            let components = NSString(string: relativePath).pathComponents
            guard !relativePath.hasPrefix("/"),
                  !components.contains("..") else {
                throw failure(intent.operationID, "unsafe effect relative path")
            }
        }
        let hasNodeIdentity = intent.nodeID != nil && intent.relativePath != nil
        let nodeFieldsAreValid: Bool
        switch intent.kind {
        case .purgeQuarantineNode:
            nodeFieldsAreValid = hasNodeIdentity
        case .discardStaging, .purgeBackup:
            // The legacy single-file harness has no node fields; a real
            // directory discard/backup purge freezes one effect per manifest
            // node.
            nodeFieldsAreValid = hasNodeIdentity ||
                (intent.nodeID == nil && intent.relativePath == nil)
        default:
            nodeFieldsAreValid =
                intent.nodeID == nil && intent.relativePath == nil
        }
        guard nodeFieldsAreValid else {
            throw failure(intent.operationID, "node effect identity fields do not match kind")
        }
    }

    private func validateManifest(
        _ nodes: [DurableManifestNode],
        operationID: OperationID
    ) throws {
        var nodeIDs = Set<String>()
        var ordinals = Set<UInt64>()
        for node in nodes {
            let components = NSString(string: node.relativePath).pathComponents
            guard !node.nodeID.isEmpty,
                  node.depth >= 0,
                  node.purgeOrdinal > 0,
                  !node.relativePath.hasPrefix("/"),
                  !components.contains(".."),
                  nodeIDs.insert(node.nodeID).inserted,
                  ordinals.insert(node.purgeOrdinal).inserted else {
                throw failure(operationID, "invalid or duplicate manifest node")
            }
        }
        let known = nodeIDs
        guard nodes.allSatisfy({ $0.parentNodeID.map(known.contains) ?? true }) else {
            throw failure(operationID, "manifest parent node is missing")
        }
    }

    private func manifestLocked(
        operationID: OperationID,
        itemID: OperationItemID
    ) throws -> [DurableManifestNode] {
        let query = try connection.statement(
            """
            SELECT node_id,parent_node_id,relative_path,depth,kind,
                   identity_blob,digest,purge_ordinal
            FROM manifest_nodes
            WHERE operation_id=? AND item_id=?
            ORDER BY purge_ordinal ASC
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        try query.bind(itemID.sqliteText, at: 2)
        var nodes: [DurableManifestNode] = []
        while try query.step() == SQLITE_ROW {
            guard let nodeID = query.text(at: 0),
                  let relativePath = query.text(at: 2),
                  let kindText = query.text(at: 4),
                  let kind = NativeNodeKind(rawValue: kindText),
                  let identity = query.data(at: 5),
                  query.int64(at: 3) >= 0,
                  query.int64(at: 7) > 0 else {
                throw failure(operationID, "manifest row cannot be decoded")
            }
            nodes.append(DurableManifestNode(
                nodeID: nodeID,
                parentNodeID: query.text(at: 1),
                relativePath: relativePath,
                depth: Int(query.int64(at: 3)),
                kind: kind,
                identity: identity,
                digest: query.text(at: 6),
                purgeOrdinal: UInt64(query.int64(at: 7))
            ))
        }
        try validateManifest(nodes, operationID: operationID)
        return nodes
    }

    private func effectIntentBlob(_ intent: DurableEffectIntent) throws -> Data? {
        try effectIntentBlob(
            operationID: intent.operationID,
            itemID: intent.itemID,
            effectID: intent.effectID
        )
    }

    private func effectIntentBlob(
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID
    ) throws -> Data? {
        let query = try connection.statement(
            """
            SELECT intent_blob FROM operation_effects
            WHERE operation_id=? AND item_id=? AND effect_id=?
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        try query.bind(itemID.sqliteText, at: 2)
        try query.bind(effectID.sqliteText, at: 3)
        guard try query.step() == SQLITE_ROW else { return nil }
        return query.data(at: 0)
    }

    private func effectResultBlob(_ result: DurableEffectResultRecord) throws -> Data? {
        let query = try connection.statement(
            """
            SELECT result_blob FROM operation_effect_results
            WHERE operation_id=? AND item_id=? AND effect_id=?
            """
        )
        try query.bind(result.operationID.sqliteText, at: 1)
        try query.bind(result.itemID.sqliteText, at: 2)
        try query.bind(result.effectID.sqliteText, at: 3)
        guard try query.step() == SQLITE_ROW else { return nil }
        return query.data(at: 0)
    }

    private func maximumEffectValue(
        operationID: OperationID,
        itemID: OperationItemID,
        column: String
    ) throws -> UInt64 {
        guard column == "effect_ordinal" || column == "intent_sequence" else {
            throw failure(operationID, "unsupported effect monotonic column")
        }
        let query = try connection.statement(
            """
            SELECT COALESCE(MAX(\(column)),0) FROM operation_effects
            WHERE operation_id=? AND item_id=?
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        try query.bind(itemID.sqliteText, at: 2)
        guard try query.step() == SQLITE_ROW, query.int64(at: 0) >= 0 else {
            throw failure(operationID, "effect monotonic maximum is invalid")
        }
        return UInt64(query.int64(at: 0))
    }

    private func maximumResultSequence(
        operationID: OperationID,
        itemID: OperationItemID
    ) throws -> UInt64 {
        let query = try connection.statement(
            """
            SELECT COALESCE(MAX(r.result_sequence),0)
            FROM operation_effect_results r
            WHERE r.operation_id=? AND r.item_id=?
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        try query.bind(itemID.sqliteText, at: 2)
        guard try query.step() == SQLITE_ROW, query.int64(at: 0) >= 0 else {
            throw failure(operationID, "effect result sequence maximum is invalid")
        }
        return UInt64(query.int64(at: 0))
    }

    private func registerAttemptIfNeeded(_ intent: DurableEffectIntent) throws {
        guard let attemptID = intent.attemptID else { return }
        let existing = try connection.statement(
            """
            SELECT owner_epoch FROM operation_attempts
            WHERE operation_id=? AND attempt_id=?
            """
        )
        try existing.bind(intent.operationID.sqliteText, at: 1)
        try existing.bind(attemptID.sqliteText, at: 2)
        if try existing.step() == SQLITE_ROW {
            guard existing.text(at: 0) == lease.epoch.sqliteText else {
                throw failure(intent.operationID, "attempt cannot cross owner epochs")
            }
            return
        }
        let ordinalQuery = try connection.statement(
            """
            SELECT COALESCE(MAX(attempt_ordinal),0)+1 FROM operation_attempts
            WHERE operation_id=?
            """
        )
        try ordinalQuery.bind(intent.operationID.sqliteText, at: 1)
        guard try ordinalQuery.step() == SQLITE_ROW, ordinalQuery.int64(at: 0) > 0 else {
            throw failure(intent.operationID, "attempt ordinal exhausted")
        }
        let now = milliseconds(Date())
        let insert = try connection.statement(
            """
            INSERT INTO operation_attempts(
              operation_id,attempt_id,owner_epoch,attempt_ordinal,state,created_ms,updated_ms
            ) VALUES(?,?,?,?,?,?,?)
            """
        )
        try insert.bind(intent.operationID.sqliteText, at: 1)
        try insert.bind(attemptID.sqliteText, at: 2)
        try insert.bind(lease.epoch.sqliteText, at: 3)
        try insert.bind(ordinalQuery.int64(at: 0), at: 4)
        try insert.bind("active", at: 5)
        try insert.bind(now, at: 6)
        try insert.bind(now, at: 7)
        guard try insert.step() == SQLITE_DONE else {
            throw failure(intent.operationID, "attempt insert did not complete")
        }
    }

    private func validateCompletedEffectChain(through intent: DurableEffectIntent) throws {
        let records = try effectRecordsLocked(operationID: intent.operationID)
            .filter {
                $0.intent.itemID == intent.itemID &&
                    $0.intent.effectOrdinal < intent.effectOrdinal
            }
        for record in records where record.result?.status != .completed {
            // A read-only restart inspection may durably prove an earlier
            // attempt not-performed. The current owner may then append a new
            // effect ID for the exact same frozen preparation. Such a
            // superseded negative attempt is historical evidence, not an
            // incomplete commit chain. Ambiguous or unresolved attempts must
            // never be hidden by a later receipt.
            guard record.result?.status == .notPerformed else {
                throw failure(
                    intent.operationID,
                    "summary receipt has an unresolved effect chain"
                )
            }
            let successorCompleted = records.contains {
                $0.intent.effectOrdinal > record.intent.effectOrdinal &&
                    sameFrozenPreparation($0.intent, record.intent) &&
                    $0.result?.status == .completed
            }
            let currentCompletesPreparation =
                sameFrozenPreparation(intent, record.intent)
            guard successorCompleted || currentCompletesPreparation else {
                throw failure(
                    intent.operationID,
                    "summary receipt has an incomplete effect chain"
                )
            }
        }
    }

    private func sameFrozenPreparation(
        _ lhs: DurableEffectIntent,
        _ rhs: DurableEffectIntent
    ) -> Bool {
        lhs.kind == rhs.kind &&
            lhs.nodeID == rhs.nodeID &&
            lhs.relativePath == rhs.relativePath &&
            lhs.expectedIdentity == rhs.expectedIdentity &&
            lhs.manifestDigest == rhs.manifestDigest
    }

    private func validateReceiptProjection(
        _ operation: JournalOperation,
        allowing allowed: (OperationItemID, OperationReceiptSummary)?
    ) throws {
        for item in operation.snapshot.items {
            let projected = operation.committedEffects[item.id]
            guard item.receipt == projected else {
                throw failure(operation.snapshot.id, "item and committed receipt projections diverged")
            }
            let query = try connection.statement(
                """
                SELECT summary_blob FROM operation_receipts
                WHERE operation_id=? AND item_id=?
                """
            )
            try query.bind(operation.snapshot.id.sqliteText, at: 1)
            try query.bind(item.id.sqliteText, at: 2)
            let existing: OperationReceiptSummary?
            if try query.step() == SQLITE_ROW {
                guard let blob = query.data(at: 0) else {
                    throw failure(operation.snapshot.id, "receipt summary blob is NULL")
                }
                existing = try decoder.decode(OperationReceiptSummary.self, from: blob)
            } else {
                existing = nil
            }
            if let allowed, allowed.0 == item.id {
                guard projected == allowed.1 else {
                    throw failure(operation.snapshot.id, "allowed receipt projection changed")
                }
            } else if projected != existing {
                throw failure(operation.snapshot.id, "ordinary checkpoint attempted receipt injection")
            }
        }
    }

    private func receiptSummary(
        operationID: OperationID,
        itemID: OperationItemID
    ) throws -> OperationReceiptSummary? {
        let query = try connection.statement(
            """
            SELECT summary_blob
            FROM operation_receipts
            WHERE operation_id=? AND item_id=?
            """
        )
        try query.bind(operationID.sqliteText, at: 1)
        try query.bind(itemID.sqliteText, at: 2)
        guard try query.step() == SQLITE_ROW else { return nil }
        guard let blob = query.data(at: 0) else {
            throw failure(operationID, "receipt summary blob is NULL")
        }
        return try decoder.decode(OperationReceiptSummary.self, from: blob)
    }

    /// Volatile progress events may advance the emitted watermark inside an
    /// already reserved range. Checkpoints persist that forward movement, but
    /// can never roll back a durable/emitted/reserved watermark.
    private func validateCheckpointBase(
        _ operation: JournalOperation,
        context: String
    ) throws -> JournalOperation {
        let id = operation.snapshot.id
        guard let stored = try self.operation(id: id) else {
            throw failure(id, "\(context) references an unknown operation")
        }
        guard operation.submissionOrdinal == stored.submissionOrdinal else {
            throw failure(id, "\(context) submission ordinal mismatch")
        }
        guard operation.latestDurableSequence >= stored.latestDurableSequence else {
            throw failure(id, "\(context) attempted durable sequence rollback")
        }
        guard operation.latestEmittedSequence >= stored.latestEmittedSequence else {
            throw failure(id, "\(context) attempted emitted sequence rollback")
        }
        guard operation.reservedThrough >= stored.reservedThrough else {
            throw failure(id, "\(context) attempted reservation rollback")
        }
        guard operation.latestDurableSequence <= operation.latestEmittedSequence,
              operation.latestEmittedSequence <= operation.reservedThrough,
              operation.snapshot.latestSequence == operation.latestEmittedSequence else {
            throw failure(id, "\(context) sequence watermarks are inconsistent")
        }
        return stored
    }

    private func scalarInt(_ sql: String) throws -> Int64? {
        let query = try connection.statement(sql)
        guard try query.step() == SQLITE_ROW else { return nil }
        return query.int64(at: 0)
    }

    private func scalarText(_ sql: String) throws -> String? {
        let query = try connection.statement(sql)
        guard try query.step() == SQLITE_ROW else { return nil }
        return query.text(at: 0)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try connection.execute("COMMIT")
            return value
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func bind(
        _ value: String?,
        to statement: SQLiteStatement,
        at index: Int32
    ) throws {
        if let value {
            try statement.bind(value, at: index)
        } else {
            try statement.bindNull(index)
        }
    }

    private func bind(
        _ value: Data?,
        to statement: SQLiteStatement,
        at index: Int32
    ) throws {
        if let value {
            try statement.bind(value, at: index)
        } else {
            try statement.bindNull(index)
        }
    }

    private func sqliteInteger(_ value: UInt64) throws -> Int64 {
        guard let converted = Int64(exactly: value) else {
            throw SQLiteJournalError(code: -1, message: "UInt64 exceeds SQLite INTEGER range")
        }
        return converted
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private func failure(_ id: OperationID?, _ diagnostic: String) -> FileOperationFailure {
        FileOperationFailure(
            code: .journalFailure,
            operationID: id,
            diagnostic: diagnostic,
            retryable: false
        )
    }

    private static let expectedTables: Set<String> = [
        "journal_meta", "owner_epochs", "operations", "operation_items",
        "operation_receipts", "operation_effects", "operation_effect_results",
        "operation_events", "operation_attempts", "recovery_action_records",
        "manifest_nodes",
    ]
    private static let expectedIndexes: Set<String> = [
        "operations_terminal_updated",
        "operation_items_order",
        "operation_effects_order",
        "operation_events_sequence",
        "recovery_actions_state",
        "manifest_nodes_purge",
    ]

    private static let schemaSQL = """
    CREATE TABLE journal_meta(
      key TEXT PRIMARY KEY,
      value BLOB NOT NULL
    );
    INSERT INTO journal_meta(key,value) VALUES('schema_version','1');

    CREATE TABLE owner_epochs(
      epoch TEXT PRIMARY KEY,
      pid INTEGER NOT NULL,
      started_ms INTEGER NOT NULL,
      sqlite_version TEXT NOT NULL
    );

    CREATE TABLE operations(
      operation_id TEXT PRIMARY KEY,
      envelope_version INTEGER NOT NULL CHECK(envelope_version=1),
      kind TEXT NOT NULL,
      state TEXT NOT NULL,
      request_blob BLOB NOT NULL,
      snapshot_blob BLOB NOT NULL,
      submission_ordinal INTEGER NOT NULL UNIQUE CHECK(submission_ordinal>0),
      latest_durable INTEGER NOT NULL CHECK(latest_durable>=0),
      latest_emitted INTEGER NOT NULL CHECK(latest_emitted>=latest_durable),
      reserved_through INTEGER NOT NULL CHECK(reserved_through>=latest_emitted),
      owner_epoch TEXT NOT NULL REFERENCES owner_epochs(epoch),
      created_ms INTEGER NOT NULL,
      updated_ms INTEGER NOT NULL,
      terminal_error_blob BLOB,
      partial_flags INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE operation_items(
      operation_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
      source_url TEXT NOT NULL,
      destination_url TEXT,
      identity_blob BLOB,
      state TEXT NOT NULL,
      staging_url TEXT,
      quarantine_url TEXT,
      progress_blob BLOB NOT NULL,
      verification_blob BLOB,
      failure_blob BLOB,
      PRIMARY KEY(operation_id,item_id),
      UNIQUE(operation_id,item_ordinal),
      FOREIGN KEY(operation_id) REFERENCES operations(operation_id) ON DELETE CASCADE
    );

    CREATE TABLE operation_receipts(
      operation_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      summary_blob BLOB NOT NULL,
      committed_identity_blob BLOB NOT NULL,
      backup_url TEXT,
      quarantine_url TEXT,
      manifest_digest TEXT,
      source_cleanup_state TEXT NOT NULL CHECK(source_cleanup_state IN ('pending','complete')),
      receipt_sequence INTEGER NOT NULL CHECK(receipt_sequence>=0),
      created_ms INTEGER NOT NULL,
      PRIMARY KEY(operation_id,item_id),
      FOREIGN KEY(operation_id,item_id)
        REFERENCES operation_items(operation_id,item_id) ON DELETE CASCADE
    );

    CREATE TABLE operation_attempts(
      operation_id TEXT NOT NULL,
      attempt_id TEXT NOT NULL,
      owner_epoch TEXT NOT NULL,
      attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
      state TEXT NOT NULL,
      created_ms INTEGER NOT NULL,
      updated_ms INTEGER NOT NULL,
      PRIMARY KEY(operation_id,attempt_id),
      UNIQUE(operation_id,attempt_ordinal),
      FOREIGN KEY(operation_id) REFERENCES operations(operation_id) ON DELETE CASCADE,
      FOREIGN KEY(owner_epoch) REFERENCES owner_epochs(epoch)
    );

    CREATE TABLE recovery_action_records(
      operation_id TEXT NOT NULL,
      action_id TEXT NOT NULL,
      owner_epoch TEXT NOT NULL,
      expected_sequence INTEGER NOT NULL CHECK(expected_sequence>=0),
      action_blob BLOB NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('offered','selected','completed','rejected')),
      created_ms INTEGER NOT NULL,
      updated_ms INTEGER NOT NULL,
      PRIMARY KEY(operation_id,action_id),
      FOREIGN KEY(operation_id) REFERENCES operations(operation_id) ON DELETE CASCADE,
      FOREIGN KEY(owner_epoch) REFERENCES owner_epochs(epoch)
    );

    CREATE TABLE operation_effects(
      operation_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      effect_id TEXT NOT NULL,
      attempt_id TEXT,
      action_id TEXT,
      effect_ordinal INTEGER NOT NULL CHECK(effect_ordinal>0),
      kind TEXT NOT NULL,
      node_id TEXT,
      relative_path TEXT,
      owner_epoch TEXT NOT NULL,
      intent_blob BLOB NOT NULL,
      intent_sequence INTEGER NOT NULL CHECK(intent_sequence>=0),
      created_ms INTEGER NOT NULL,
      PRIMARY KEY(operation_id,item_id,effect_id),
      UNIQUE(operation_id,item_id,effect_ordinal),
      FOREIGN KEY(operation_id,item_id)
        REFERENCES operation_items(operation_id,item_id) ON DELETE CASCADE,
      FOREIGN KEY(owner_epoch) REFERENCES owner_epochs(epoch)
    );

    CREATE TABLE operation_effect_results(
      operation_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      effect_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('completed','notPerformed','ambiguous')),
      result_identity_blob BLOB,
      system_code INTEGER,
      result_blob BLOB NOT NULL,
      result_sequence INTEGER NOT NULL CHECK(result_sequence>=0),
      created_ms INTEGER NOT NULL,
      PRIMARY KEY(operation_id,item_id,effect_id),
      FOREIGN KEY(operation_id,item_id,effect_id)
        REFERENCES operation_effects(operation_id,item_id,effect_id) ON DELETE CASCADE
    );

    CREATE TABLE operation_events(
      operation_id TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK(sequence>0),
      item_id TEXT,
      envelope_version INTEGER NOT NULL CHECK(envelope_version=1),
      payload_blob BLOB NOT NULL,
      created_ms INTEGER NOT NULL,
      PRIMARY KEY(operation_id,sequence),
      FOREIGN KEY(operation_id) REFERENCES operations(operation_id) ON DELETE CASCADE
    );

    CREATE TABLE manifest_nodes(
      operation_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      node_id TEXT NOT NULL,
      parent_node_id TEXT,
      relative_path TEXT NOT NULL,
      depth INTEGER NOT NULL CHECK(depth>=0),
      kind TEXT NOT NULL,
      identity_blob BLOB NOT NULL,
      digest TEXT,
      purge_ordinal INTEGER NOT NULL CHECK(purge_ordinal>0),
      PRIMARY KEY(operation_id,item_id,node_id),
      UNIQUE(operation_id,item_id,purge_ordinal),
      FOREIGN KEY(operation_id,item_id)
        REFERENCES operation_items(operation_id,item_id) ON DELETE CASCADE
    );

    CREATE INDEX operations_terminal_updated
      ON operations(state,updated_ms DESC,operation_id DESC);
    CREATE INDEX operation_items_order
      ON operation_items(operation_id,item_ordinal);
    CREATE INDEX operation_effects_order
      ON operation_effects(operation_id,item_id,effect_ordinal);
    CREATE INDEX operation_events_sequence
      ON operation_events(operation_id,sequence);
    CREATE INDEX recovery_actions_state
      ON recovery_action_records(operation_id,state);
    CREATE INDEX manifest_nodes_purge
      ON manifest_nodes(operation_id,item_id,purge_ordinal);
    """
}

private extension UUID {
    var sqliteText: String { uuidString.lowercased() }
}

private extension OperationID {
    var sqliteText: String { rawValue.sqliteText }

    init?(sqliteText: String) {
        guard let value = UUID(uuidString: sqliteText) else { return nil }
        self.init(rawValue: value)
    }
}

private extension OperationItemID {
    var sqliteText: String { rawValue.sqliteText }
}

private extension OperationSnapshot {
    func replacingLatestSequenceForSQLite(_ sequence: EventSequence) -> OperationSnapshot {
        OperationSnapshot(
            schemaVersion: schemaVersion,
            id: id,
            kind: kind,
            state: state,
            latestSequence: sequence,
            request: request,
            effectiveMetadataPolicy: effectiveMetadataPolicy,
            effectiveVerificationPolicy: effectiveVerificationPolicy,
            progress: progress,
            items: items,
            pendingDecision: pendingDecision,
            terminalFailure: terminalFailure,
            availableActions: availableActions,
            hasPartialCommit: hasPartialCommit,
            sourceRetained: sourceRetained
        )
    }
}
