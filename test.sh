#!/bin/zsh
# Runs the unit tests (Swift Testing) with the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
mkdir -p .build
ARGS=()
CLT_SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$CLT_SWIFT_INC/module.modulemap" && -f "$CLT_SWIFT_INC/bridging.modulemap" ]]; then
  : > .build/empty.modulemap
  cat > .build/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "file", "name": "$CLT_SWIFT_INC/module.modulemap",
    "external-contents": "$(pwd)/.build/empty.modulemap" } ] }
YAML
  ARGS=(-Xswiftc -vfsoverlay -Xswiftc "$(pwd)/.build/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$(pwd)/.build/overlay.yaml")
fi
swift test "${ARGS[@]}" "$@"
