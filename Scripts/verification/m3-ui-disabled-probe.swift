import AppKit
import Darwin

/// Compiled only in the verification lane's temporary source copy. The probe
/// drives the production FinderTwo owners while the repository source remains
/// untouched, so M3 cannot accidentally acquire an application routing path.
@MainActor
enum M3UIDisabledProbe {
    static func run(appDelegate: AppDelegate) {
        progress("started")
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "Rascal-M3-UI-Probe-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            DropStack.clear()
            try? fileManager.removeItem(at: root)
        }

        guard let bridge = appDelegate.testFileOperationBridge else {
            fail("missing application composition bridge")
            return
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            let journalURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Rascal/Operations/operations.sqlite")
            let journalRowsBefore = try operationRowCount(journalURL)
            progress("journal-before=\(journalRowsBefore)")
            let traceBefore = bridge.submissionTrace.count
            let legacyBefore = TransferQueue.shared.snapshot.count
            let paste = try makeFixture("paste", under: root)
            let list = try makeFixture("list-drag", under: root)
            let icon = try makeFixture("icon-drag", under: root)
            let pane = try makeFixture("pane-move", under: root)
            let stack = try makeFixture("drop-stack", under: root)
            let replace = try makeFixture("replace-conflict", under: root)
            try Data("existing".utf8).write(
                to: replace.destination.appendingPathComponent(
                    replace.source.lastPathComponent
                )
            )
            let fixtureBefore = try fixtureSnapshot(root)
            progress("fixtures-ready")
            var denials: [LegacyWriteCapability] = []
            let observer = NotificationCenter.default.addObserver(
                forName: .legacyWriteDenied,
                object: nil,
                queue: .main
            ) { note in
                if let denial = note.object as? LegacyWriteDenial {
                    denials.append(denial.capability)
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let pastePane = PaneController(
                url: paste.destination,
                fileOperationBridge: bridge
            )
            pastePane.m3ProbeSubmitPasteMove([paste.source])
            try requireDenials(denials, count: 1, entry: "ENTRY-PASTE")
            progress("paste")

            let listPane = PaneController(
                url: list.destination,
                fileOperationBridge: bridge
            )
            listPane.fileList.m3ProbeSubmitListMove(
                [list.source],
                into: list.destination
            )
            try requireDenials(denials, count: 2, entry: "ENTRY-LIST-DRAG")
            progress("list-drag")

            let iconPane = PaneController(
                url: icon.destination,
                fileOperationBridge: bridge
            )
            iconPane.m3ProbeSubmitIconMove(
                [icon.source],
                into: icon.destination
            )
            try requireDenials(denials, count: 3, entry: "ENTRY-ICON-DRAG")
            progress("icon-drag")

            let panes = PanesContainerController(
                initialURL: pane.destination,
                fileOperationBridge: bridge
            )
            _ = panes.view
            panes.toggleExtraPane()
            guard let active = panes.activePane else {
                throw ProbeError("pane-to-pane owner has no active pane")
            }
            active.navigate(to: pane.source.deletingLastPathComponent())
            active.testReloadSync()
            guard let selected = active.testCurrentItems.first(where: {
                $0.url.standardizedFileURL == pane.source.standardizedFileURL
            }) else {
                throw ProbeError("pane-to-pane source was not visible")
            }
            active.testSelectItem(selected)
            panes.transferSelectionToOtherPane(move: true)
            try requireDenials(denials, count: 4, entry: "ENTRY-PANE-MOVE")
            progress("pane-move")

            let browser = BrowserWindowController(
                rootURL: stack.destination,
                autosaveFrame: false,
                fileOperationBridge: bridge
            )
            browser.showWindow(nil)
            browser.window?.makeKeyAndOrderFront(nil)
            browser.window?.orderFrontRegardless()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            guard BrowserWindowController.frontmost === browser else {
                throw ProbeError("Drop Stack production owner has no frontmost browser")
            }
            DropStack.clear()
            _ = DropStack.add([stack.source])
            let stackController = DropStackController(fileOperationBridge: bridge)
            stackController.reload()
            stackController.m3ProbeInvokeMoveAllHere()
            try requireDenials(denials, count: 5, entry: "ENTRY-DROP-STACK")
            progress("drop-stack")

            FileOps.transfer(
                [replace.source],
                into: replace.destination,
                move: true,
                fileOperationBridge: bridge,
                route: .paste
            )
            try requireDenials(denials, count: 6, entry: "ENTRY-REPLACE-CONFLICT")
            progress("replace-conflict")

            let fixtureAfter = try fixtureSnapshot(root)
            let journalRowsAfter = try operationRowCount(journalURL)
            let expectedDenials: [LegacyWriteCapability] = Array(
                repeating: .transferMove,
                count: 6
            )
            let passed =
                !bridge.nativeCopyEnabled &&
                bridge.submissionTrace.count == traceBefore &&
                TransferQueue.shared.snapshot.count == legacyBefore &&
                journalRowsBefore == journalRowsAfter &&
                journalRowsAfter == 0 &&
                fixtureAfter == fixtureBefore &&
                denials == expectedDenials
            let result = passed
                ? "M3_UI_DISABLED_PROBE PASS entries=6 native=0 legacy=0 " +
                    "journal_rows=0 fixture=unchanged denials=6\n"
                : "M3_UI_DISABLED_PROBE FAIL enabled=\(bridge.nativeCopyEnabled) " +
                    "native=\(bridge.submissionTrace.count - traceBefore) " +
                    "legacy=\(TransferQueue.shared.snapshot.count - legacyBefore) " +
                    "journal_before=\(journalRowsBefore) journal_after=\(journalRowsAfter) " +
                    "fixture_changed=\(fixtureAfter != fixtureBefore) " +
                    "denials=\(denials)\n"
            FileHandle.standardOutput.write(Data(result.utf8))
            NSApp.terminate(passed ? nil : ProbeTermination.failure)
        } catch {
            fail(String(describing: error))
        }
    }

    private static func makeFixture(
        _ name: String,
        under root: URL
    ) throws -> (source: URL, destination: URL) {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let source = sourceDirectory.appendingPathComponent("\(name).txt")
        try Data("source-\(name)".utf8).write(to: source)
        return (source, destination)
    }

    private static func fixtureSnapshot(_ root: URL) throws -> [String] {
        let fileManager = FileManager.default
        var result: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            throw ProbeError("fixture enumeration failed")
        }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw ProbeError("lstat failed for \(url.path)")
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let payload: String
            if info.st_mode & S_IFMT == S_IFREG {
                payload = try Data(contentsOf: url).base64EncodedString()
            } else if info.st_mode & S_IFMT == S_IFLNK {
                payload = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            } else {
                payload = "-"
            }
            result.append([
                relative,
                String(info.st_mode & S_IFMT),
                String(info.st_size),
                payload,
            ].joined(separator: "\t"))
        }
        return result.sorted()
    }

    private static func operationRowCount(_ journalURL: URL) throws -> Int {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            journalURL.path,
            "SELECT count(*) FROM operations;",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let value = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let value, let count = Int(value) else {
            throw ProbeError("journal row query failed: \(value ?? "no output")")
        }
        return count
    }

    private static func requireDenials(
        _ denials: [LegacyWriteCapability],
        count: Int,
        entry: String
    ) throws {
        guard denials.count == count, denials.last == .transferMove else {
            throw ProbeError(
                "\(entry) did not reach the transferMove fail-closed boundary; " +
                    "denials=\(denials)"
            )
        }
    }

    private static func fail(_ diagnostic: String) {
        FileHandle.standardError.write(
            Data("M3_UI_DISABLED_PROBE FAIL \(diagnostic)\n".utf8)
        )
        NSApp.terminate(ProbeTermination.failure)
    }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(
            Data("M3_UI_DISABLED_PROBE progress \(message)\n".utf8)
        )
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class ProbeTermination: NSObject {
    static let failure = ProbeTermination()
}
