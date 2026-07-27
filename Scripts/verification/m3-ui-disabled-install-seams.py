#!/usr/bin/python3
"""Install M3 UI probe seams into a temporary FinderTwo source copy only."""

from pathlib import Path
import sys


root = Path(sys.argv[1])
app_delegate = root / "Sources/FinderTwo/AppDelegate.swift"
text = app_delegate.read_text()
needle = """        if ProcessInfo.processInfo.environment["FT_M2_RELEASE_PROBE"] == "1" {
"""
insertion = """        if ProcessInfo.processInfo.environment["FT_M3_UI_DISABLED_PROBE"] == "1" {
            DispatchQueue.main.async {
                M3UIDisabledProbe.run(appDelegate: self)
            }
            return
        }
"""
if text.count(needle) != 1:
    raise SystemExit("AppDelegate M3 probe insertion point is not unique")
app_delegate.write_text(text.replace(needle, insertion + needle, 1))

main = root / "Sources/FinderTwo/main.swift"
main_text = main.read_text()
main_needle = "app.run()\n"
main_replacement = """if ProcessInfo.processInfo.environment["FT_M3_UI_DISABLED_PROBE"] == "1" {
    // A package executable has no registered app bundle, so macOS does not
    // emit didFinishLaunching. Enter the production delegate explicitly in
    // this temporary probe build, then let AppKit drain its queued probe.
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )
}
app.run()
"""
if main_text.count(main_needle) != 1:
    raise SystemExit("FinderTwo main probe insertion point is not unique")
main.write_text(main_text.replace(main_needle, main_replacement, 1))

seams = (
    root.parent.parent
    / "Scripts/verification/m3-ui-disabled-owner-seams.swift"
)
if not seams.exists():
    # The installed script is executed from the repository, while root is the
    # copied package. Resolve the authoritative seam source from argv[0].
    seams = Path(__file__).with_name("m3-ui-disabled-owner-seams.swift")
payload = seams.read_text()

file_list_marker = "// FILE: Sources/FinderTwo/UI/FileListController.swift"
pane_marker = "// FILE: Sources/FinderTwo/UI/PaneController.swift"
drop_stack_marker = "// FILE: Sources/FinderTwo/UI/DropStackController.swift"
file_list_payload = payload.split(file_list_marker, 1)[1].split(pane_marker, 1)[0]
pane_payload = payload.split(pane_marker, 1)[1].split(drop_stack_marker, 1)[0]
drop_stack_payload = payload.split(drop_stack_marker, 1)[1]

for relative, extra in (
    ("Sources/FinderTwo/UI/FileListController.swift", file_list_payload),
    ("Sources/FinderTwo/UI/PaneController.swift", pane_payload),
    ("Sources/FinderTwo/UI/DropStackController.swift", drop_stack_payload),
):
    path = root / relative
    path.write_text(path.read_text() + "\n" + extra.strip() + "\n")
