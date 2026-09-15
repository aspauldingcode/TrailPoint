#!/bin/zsh
set -euo pipefail

swift build -c release
mkdir -p TrailPoint.app/Contents/MacOS
cp .build/release/TrailPoint TrailPoint.app/Contents/MacOS/TrailPoint
cp AppInfo.plist TrailPoint.app/Contents/Info.plist
codesign --force --sign - TrailPoint.app
echo "Built TrailPoint.app"
