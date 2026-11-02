"""Give a generated Android scaffold an independent development identity.

Run after prepare_android.sh, from mobile/device_scanner. Keep the original
launcher bitmap as the base and add a spanner badge using Android resources.
"""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path('android/app')
gradle = root / 'build.gradle'
text = gradle.read_text()
text, count = re.subn(r'applicationId\s*=\s*"[^"]+"',
                      'applicationId = "com.casavino.bubble.dev"', text)
if count != 1:
    raise RuntimeError('Expected exactly one applicationId in the scaffold')
gradle.write_text(text)

manifest = root / 'src/main/AndroidManifest.xml'
android = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', android)
tree = ET.parse(manifest)
app = tree.getroot().find('application')
if app is None:
    raise RuntimeError('Missing Android application')
app.set(f'{{{android}}}label', 'Bubble Dev')
app.set(f'{{{android}}}icon', '@drawable/bubble_dev_icon')
app.set(f'{{{android}}}roundIcon', '@drawable/bubble_dev_icon')
# Activity class remains in the shared namespace, independent of applicationId.
for activity in app.findall('activity'):
    if activity.get(f'{{{android}}}name') == '.MainActivity':
        activity.set(f'{{{android}}}name', 'com.casavino.bubble.MainActivity')
tree.write(manifest, encoding='unicode')

resources = root / 'src/main/res/drawable'
resources.mkdir(parents=True, exist_ok=True)
for name in ('bubble_dev_icon.xml', 'bubble_dev_badge.xml'):
    (resources / name).write_text((Path('android_overlay/dev') / name).read_text())
print('Prepared Bubble Dev: com.casavino.bubble.dev, spanner badge, separate app data')
