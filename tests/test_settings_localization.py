"""Run with python3 tests/test_settings_localization.py."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
catalog = json.loads((root / 'DynamicIsland/Localizable.xcstrings').read_text())['strings']
settings = root / 'DynamicIsland/components/Settings'
files = list(settings.rglob('*.swift')) + list((root / 'DynamicIsland/enums').glob('*.swift'))
files.append(root / 'DynamicIsland/components/Tabs/TabSelectionView.swift')
files += [root / 'DynamicIsland' / name for name in (
    'models/Constants.swift', 'models/UpdateChannel.swift', 'models/MusicControlButton.swift',
    'managers/SpotifyAuthManager.swift', 'managers/IdleAnimationManager.swift',
    'managers/TerminalManager.swift', 'managers/LLMUsage/NewAPIUsage.swift',
    'components/Notch/CodexUsageDetailView.swift', 'components/Notch/NotchLLMUsageView.swift',
    'managers/LLMUsage/CodexUsageDetails.swift')]
source = '\n'.join(path.read_text() for path in files)

literal = r'"(?:[^"\\]|\\.)*"'
ui_literals = set(re.findall(r'(?:Text|Button|Label|Picker|Toggle|TextField|SecureField|String\(localized:|title:|subtitle:|label:|\.help|\.alert)\s*\(?\s*(' + literal + ')', source))
keys = set()
for match in re.finditer(literal, source):
    try:
        key = json.loads(match.group())
    except ValueError:  # Swift interpolations are checked below using catalog keys.
        continue
    is_ui = match.group() in ui_literals
    if key and not key.isdigit() and (key in catalog or is_ui):
        keys.add(key)
# These UI options use persisted raw values rather than literal Text keys.
for path, start, end in (
    ('DynamicIsland/models/Constants.swift', 'enum AnimationLoopMode:', 'enum AnimationSource:'),
    ('DynamicIsland/components/OSD/CustomOSDView.swift', 'enum OSDMaterial:', '#endif'),
):
    options = (root / path).read_text().split(start)[1].split(end)[0]
    keys.update(re.findall(r'= "([^"\n]+)"', options))
keys.update(('Pending', 'Authorized', 'Denied', 'Revoked'))

# Optional compiler output covers interpolated strings as well as static ones.
# Example: python3 tests/test_settings_localization.py /path/to/Objects-normal/arm64
import sys
if len(sys.argv) > 1:
    stems = {path.stem for path in files}
    for path in Path(sys.argv[1]).glob('*.stringsdata'):
        if path.stem in stems:
            data = json.loads(path.read_text())
            keys.update(item['key'] for item in data['tables'].get('Localizable', []) if item['key'])

placeholders = r'%(?:\d+\$)?(?:\.\d+)?(?:lld|ld|d|f|@)'
errors = []
for key in sorted(keys):
    for language in ('zh-Hans', 'zh-Hant'):
        value = catalog.get(key, {}).get('localizations', {}).get(language, {}).get('stringUnit', {}).get('value')
        if not value:
            errors.append(f'{language}: missing translation for {key!r}')
            continue
        normalize = lambda text: sorted(re.sub(r'%\d+\$', '%', token) for token in re.findall(placeholders, text))
        if normalize(key) != normalize(value):
            errors.append(f'{language}: placeholder mismatch for {key!r}')
assert not errors, '\n'.join(errors)
print(f'Validated Simplified and Traditional Chinese for {len(keys)} settings strings.')
