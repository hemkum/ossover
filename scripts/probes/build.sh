#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compiles scripts/probes/*.c into Windows x86_64 executables with mingw-w64
# (brew install mingw-w64). Run from anywhere; output lands beside the sources.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
for src in "$here"/*.c; do
    exe="${src%.c}.exe"
    x86_64-w64-mingw32-gcc -O1 -static-libgcc -o "$exe" "$src" -ld3d11 -ldxgi -lole32 -luser32
    echo "built $exe"
done
