#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cache_dir="$project_dir/.build/cache"
mkdir -p "$cache_dir/module-cache"
CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache" swiftc -parse-as-library \
    -module-cache-path "$cache_dir/module-cache" \
    "$project_dir/Sources/AutoSent/DraftGuard.swift" \
    "$project_dir/Tests/DraftGuardTests.swift" \
    -o "$cache_dir/DraftGuardTests"
"$cache_dir/DraftGuardTests"
