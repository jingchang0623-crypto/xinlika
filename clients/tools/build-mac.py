#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build an isolated local app bundle; does not connect to a recorder or launch it."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--connection', type=Path, default=root / 'private-config/connection-mac.json')
args = parser.parse_args()
if not args.connection.exists(): parser.error('Create your private workspace connection first')
subprocess.run(['swift', 'build', '--package-path', str(root / 'clients'), '--scratch-path', str(root / '.build/swift'), '--product', 'XinlikaMac'], check=True)
binary_dir = subprocess.check_output(['swift', 'build', '--package-path', str(root / 'clients'), '--scratch-path', str(root / '.build/swift'), '--show-bin-path'], text=True).strip()
bundle = root / '.build/XinlikaOpenSource.app'
(bundle / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
shutil.copy2(Path(binary_dir) / 'XinlikaMac', bundle / 'Contents/MacOS/XinlikaMac')
info = {'CFBundleIdentifier': 'org.xinlika.mac', 'CFBundleName': '心力卡 · 开源版', 'CFBundleDisplayName': '心力卡 · 开源版',
        'CFBundleExecutable': 'XinlikaMac', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.3.10',
        'NSBluetoothAlwaysUsageDescription': '连接你选择的录音卡。', 'NSLocalNetworkUsageDescription': '连接你配置的心力卡处理服务。',
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}, 'LSMinimumSystemVersion': '14.0',
        'HeartballSharedRuntimePath': str(args.connection.resolve()),
        'HeartballRuntimePath': str(root / '.build/local-capture/runtime.json')}
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
resources = bundle / 'Contents/Resources'; resources.mkdir(exist_ok=True)
shutil.copy2(root / 'clients/LICENSE', resources / 'LICENSE-GPL-3.0.txt')
shutil.copy2(root / 'clients/PROVENANCE.md', resources / 'PROVENANCE.md')
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
print(str(bundle))
