#!/bin/bash
set -euo pipefail

# Keep local builds in the same location as the development app.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

exec xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug \
  -derivedDataPath "$repo_root/build/DerivedData" build
