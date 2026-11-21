#!/usr/bin/env python3
"""Configure stable APK release signing. Never prints key material or passwords."""
import base64
import os
from pathlib import Path
import re
import sys

required = ['A2R_KEYSTORE_BASE64', 'A2R_STORE_PASSWORD', 'A2R_KEY_PASSWORD', 'A2R_KEY_ALIAS']
missing = [name for name in required if not os.environ.get(name)]
if missing:
    sys.exit('Release signing not configured. Missing repository secrets: ' + ', '.join(missing))
try:
    data = base64.b64decode(''.join(os.environ['A2R_KEYSTORE_BASE64'].split()), validate=True)
except Exception:
    sys.exit('A2R_KEYSTORE_BASE64 is not valid base64. No APK will be published.')
if len(data) < 100:
    sys.exit('Signing keystore is empty or invalid. No APK will be published.')
key = Path(os.environ['RUNNER_TEMP']) / 'a2r-release-signing.jks'
key.write_bytes(data)
key.chmod(0o600)
gradle = Path('android/app/build.gradle.kts')
source = gradle.read_text()
if 'signingConfigs.getByName("debug")' not in source:
    sys.exit('Expected generated signing template not found. Refusing unsafe signing changes.')
config = '''    signingConfigs {
        create("a2rRelease") {
            storeFile = file(System.getenv("A2R_KEYSTORE_PATH") ?: error("Missing release keystore path"))
            storePassword = System.getenv("A2R_STORE_PASSWORD") ?: error("Missing store password")
            keyAlias = System.getenv("A2R_KEY_ALIAS") ?: error("Missing key alias")
            keyPassword = System.getenv("A2R_KEY_PASSWORD") ?: error("Missing key password")
            enableV1Signing = true
            enableV2Signing = true
        }
    }

'''
if source.count('    buildTypes {') != 1:
    sys.exit('Unexpected Gradle buildTypes template. Refusing to continue.')
source = source.replace('    buildTypes {', config + '    buildTypes {')
source = source.replace('signingConfigs.getByName("debug")', 'signingConfigs.getByName("a2rRelease")')
# Use the actual supported minimum. Legacy Flutter 3.32.8 supports Android API 21+.
source, count = re.subn(r'(?m)^\s*minSdk\s*=.*$', '        minSdk = 21', source)
if count != 1:
    sys.exit('Expected exactly one minSdk field. No build will proceed.')
if 'signingConfigs.getByName("debug")' in source:
    sys.exit('Debug release signing remains. Refusing to continue.')
source, ndk_count = re.subn(r'(?m)^\s*ndkVersion\s*=.*$', '    ndkVersion = "27.0.12077973"', source)
if ndk_count != 1:
    sys.exit('Expected exactly one ndkVersion field. Refusing ambiguous build configuration.')
gradle.write_text(source)
with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as env:
    env.write(f'A2R_KEYSTORE_PATH={key}\n')
print('Release signing configured from repository secrets. Android minimum: API 21.')
