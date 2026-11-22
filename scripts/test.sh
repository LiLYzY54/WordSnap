#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_BUILD_DIR="${WORDSNAP_TEST_BUILD_DIR:-$HOME/Library/Developer/Xcode/WordSnap/Tests}"

cd "$PROJECT_ROOT/app"
xcodegen generate
cd "$PROJECT_ROOT"
xcodebuild test -project app/WordSnap.xcodeproj -scheme WordSnap \
    -destination 'platform=macOS' -derivedDataPath "$TEST_BUILD_DIR"
node --test obsidian-plugin/tests/*.test.cjs
bash scripts/test_migrate_vocab.sh
