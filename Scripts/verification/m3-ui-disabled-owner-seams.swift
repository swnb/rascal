
// Appended to the corresponding production files only in the lane's temporary
// source copy. Same-file extensions can enter the existing private owner
// funnels without widening the shipping FinderTwo API.

// FILE: Sources/FinderTwo/UI/FileListController.swift
extension FileListController {
    func m3ProbeSubmitListMove(_ sources: [URL], into destination: URL) {
        submitDrop(urls: sources, target: destination, isCopy: false)
    }
}

// FILE: Sources/FinderTwo/UI/PaneController.swift
extension PaneController {
    func m3ProbeSubmitPasteMove(_ sources: [URL]) {
        // The unbundled verification executable has no functional pasteboard
        // service. Enter the same production transfer funnel selected by
        // pasteMoveHere after its URL-only pasteboard decode.
        FileOps.transfer(
            sources,
            into: currentURL,
            move: true,
            from: view.window,
            fileOperationBridge: fileOperationBridge,
            refresh: { [weak self] in self?.reload() }
        )
    }

    func m3ProbeSubmitIconMove(_ sources: [URL], into destination: URL) {
        submitIconDrop(urls: sources, target: destination, isCopy: false)
    }
}

// FILE: Sources/FinderTwo/UI/DropStackController.swift
extension DropStackController {
    func m3ProbeInvokeMoveAllHere() {
        moveAllHere()
    }
}
