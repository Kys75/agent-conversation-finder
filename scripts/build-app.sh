#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release --product AgentConversationFinderApp
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/build/Agent Conversation Finder.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/AgentConversationFinderApp" "$app_dir/Contents/MacOS/AgentConversationFinder"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
