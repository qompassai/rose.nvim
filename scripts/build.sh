#!/usr/bin/env bash
# /qompassai/rose.nvim/scripts/build.sh
# Qompass AI Rose.nvim Build Script
# Copyright (C) 2025 Qompass AI, All rights reserved
#####################################################

set -e
REPO_OWNER="qompassai"
REPO_NAME="rose.nvim"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TARGET_DIR="${SCRIPT_DIR}/build"
case "$(uname -s)" in
Linux*)
    PLATFORM="linux"
    ;;
Darwin*)
    PLATFORM="darwin"
    ;;
CYGWIN* | MINGW* | MSYS*)
    PLATFORM="windows"
    ;;
*)
    echo "Unsupported platform"
    exit 1
    ;;
esac
case "$(uname -m)" in
x86_64)
    ARCH="x86_64"
    ;;
aarch64)
    ARCH="aarch64"
    ;;
arm64)
    ARCH="aarch64"
    ;;
*)
    echo "Unsupported architecture"
    exit 1
    ;;
esac
LUA_VERSION="${LUA_VERSION:-luajit}"
ARTIFACT_NAME_PATTERN="rose_lib-$PLATFORM-$ARCH-$LUA_VERSION"
ARTIFACT_URL=$(curl -s "https://api.github.com/repos/qompassai/rose.nvim/releases/latest" | grep "browser_download_url" | cut -d '"' -f 4 | grep $ARTIFACT_NAME_PATTERN)
set -x
mkdir -p "$TARGET_DIR"
curl -L "$ARTIFACT_URL" | tar -zxv -C "$TARGET_DIR"
