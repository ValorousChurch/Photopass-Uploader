#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BIN="$BUILD_DIR/Photopass Uploader"

mkdir -p "$BUILD_DIR"

/usr/bin/env swiftc -parse-as-library "$SCRIPT_DIR/photo_pass_gui.swift" -o "$APP_BIN"

exec "$APP_BIN"
