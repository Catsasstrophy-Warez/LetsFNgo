#!/bin/bash
# Prepares a Claude Code on the web session: Swift 6.2 toolchain, SQLite
# headers, and a warm build so `swift test` starts fast.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SWIFT_DIR=/opt/swift-6.2-RELEASE-ubuntu24.04
SWIFT_URL=https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz

if [ ! -x "$SWIFT_DIR/usr/bin/swift" ]; then
  curl -sSfL "$SWIFT_URL" | tar xz -C /opt
fi

if [ ! -f /usr/include/sqlite3.h ]; then
  apt-get update -qq && apt-get install -y -qq libsqlite3-dev pkg-config
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=$SWIFT_DIR/usr/bin:\$PATH" >> "$CLAUDE_ENV_FILE"
fi
export PATH="$SWIFT_DIR/usr/bin:$PATH"

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"
swift build --build-tests
