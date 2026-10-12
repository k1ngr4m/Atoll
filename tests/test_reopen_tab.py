"""Run with python3 tests/test_reopen_tab.py (requires the Swift compiler)."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    main = Path(directory) / "main.swift"
    main.write_text('''
let tabs = ["system-home", "system-notes", "system-terminal", "extension-one", "extension-two"]
func resolve(_ preference: String, _ last: String?, _ target: String? = nil,
             available: [String] = tabs) -> String? {
    ReopenTabSelection.resolve(preference: preference, lastPage: last,
                              available: available, explicitTarget: target)
}
assert(resolve(ReopenTabSelection.lastPage, "system-notes") == "system-notes")
assert(resolve("system-terminal", "system-notes") == "system-terminal")
assert(resolve("system-disabled", "system-notes") == "system-notes")
assert(resolve("system-disabled", "system-disabled") == "system-home")
assert(resolve(ReopenTabSelection.lastPage, nil) == "system-home")
assert(resolve("extension-two", "extension-one") == "extension-two")
assert(resolve(ReopenTabSelection.lastPage, "extension-one") == "extension-one")
assert(resolve("system-home", "system-notes", "system-terminal") == "system-terminal")
assert(resolve("extension-two", "system-notes", available: ["system-home", "system-notes"]) == "system-notes")
assert(resolve("extension-two", "system-notes") == "extension-two")
assert(resolve("system-terminal", "system-notes", "system-terminal", available: ["system-home"]) == "system-home")
assert(resolve("system-terminal", nil, available: []) == nil)
print("Reopen tab regression checks passed")
''')
    executable = Path(directory) / "reopen-tab-tests"
    subprocess.run(["swiftc", str(root / "DynamicIsland/models/ReopenTabSelection.swift"),
                    str(main), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
