#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cache_dir="$project_dir/.build/cache"
app_dir="$project_dir/build/autoSent.app"
mkdir -p "$cache_dir/module-cache" "$app_dir/Contents/MacOS"

CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache" swiftc -O -parse-as-library \
    -module-cache-path "$cache_dir/module-cache" \
    -target arm64-apple-macosx13.0 \
    "$project_dir/Sources/AutoSent/AutoSent.swift" \
    "$project_dir/Sources/AutoSent/DraftGuard.swift" \
    -o "$cache_dir/autoSent"

cp "$cache_dir/autoSent" "$app_dir/Contents/MacOS/autoSent"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
print "Built $app_dir"
