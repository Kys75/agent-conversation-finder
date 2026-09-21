#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
target_dir="${ACF_INSTALL_DIR:-$HOME/Applications}"
app_dir="$target_dir/Agent Conversation Finder.app"
if [[ -e "$app_dir" ]]; then
    printf '%s\n' "An app already exists at $app_dir. Move that app aside before installing." >&2
    exit 1
fi
"$project_dir/scripts/build-app.sh"
mkdir -p "$target_dir"
ditto "$project_dir/build/Agent Conversation Finder.app" "$app_dir"
printf 'Installed: %s\n' "$app_dir"
