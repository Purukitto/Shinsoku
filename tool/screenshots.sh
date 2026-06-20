#!/usr/bin/env bash
# Launch the screenshot harness: the real Shinsoku window with deterministic
# mock data. Navigate, then press F1-F6 to write docs/screenshots/<name>.png.
#
#   ./tool/screenshots.sh [-d windows|linux]
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
shot_dir="$repo/docs/screenshots"
device="${1:-windows}"
# allow `screenshots.sh -d linux`
if [[ "$device" == "-d" ]]; then device="${2:-windows}"; fi

mkdir -p "$shot_dir"
echo "Screenshots -> $shot_dir"
echo 'Keys: F1 hero  F2 active  F3 detail  F4 add  F5 settings  F6 completed'

cd "$repo/app"
flutter run -t lib/main_screenshots.dart -d "$device" --release \
    --dart-define="SHOT_DIR=$shot_dir"
