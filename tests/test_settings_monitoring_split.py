"""Run with python3 tests/test_settings_monitoring_split.py (requires Swift/macOS)."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'DynamicIsland/components/Settings/SettingsView.swift').read_text()
navigation = source.split('private enum SettingsTabGroup:', 1)[1]
navigation = 'private enum SettingsTabGroup:' + navigation.split('final class SettingsHighlightCoordinator:', 1)[0]

with tempfile.TemporaryDirectory() as directory:
    main = Path(directory) / 'main.swift'
    main.write_text('import SwiftUI\n' + navigation + '''
assert(SettingsTab.stats.group == .system)
assert(SettingsTab.llmAgents.group == .developer)
private let expected: [(SettingsTab, [String])] = [
    (.stats, ["Enable system stats monitoring", "Stop monitoring after closing the notch",
              "CPU Usage", "Temperature unit", "Memory Usage", "GPU Usage", "Network Activity", "Disk I/O"]),
    (.llmAgents, ["Enable LLM Usage Monitor", "Claude Provider", "Codex Provider", "Cursor Provider",
                  "Antigravity Provider", "New API Provider", "New API Accounts"])
]
for (tab, titles) in expected {
    for title in titles {
        let matches = SettingsSearchIndex.entries.filter {
            $0.title == title && ($0.tab == .stats || $0.tab == .llmAgents)
        }
        assert(matches.count == 1, title)
        assert(matches[0].tab == tab, title)
        assert(matches[0].highlightID == tab.highlightID(for: title), title)
    }
}
print("Monitoring and LLM settings navigation checks passed.")
''')
    subprocess.run(['swift', str(main)], check=True)
