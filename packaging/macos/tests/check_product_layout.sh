#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$ROOT"

required_paths="
apps/android/flutter_app
apps/web/README.md
apps/station/macstation_host/src/lib.rs
apps/macos/station_app/AppShell.swift
apps/macos/client_app/AppShell.swift
packaging/macos/package.sh
packaging/macos/StationInfo.plist.in
packaging/macos/ClientInfo.plist.in
"

for path in $required_paths; do
  if [ ! -e "$path" ]; then
    echo "missing required product path: $path" >&2
    exit 1
  fi
done

grep -q 'PlushBuddy Station.app' packaging/macos/package.sh
grep -q 'PlushBuddy.app' packaging/macos/package.sh
grep -q 'apps/macos/station_app/AppShell.swift' packaging/macos/package.sh
grep -q 'apps/macos/client_app/AppShell.swift' packaging/macos/package.sh
grep -q 'Contents/Resources/PlushBuddy.app' packaging/macos/package.sh

sh -n packaging/macos/package.sh
swiftc -typecheck -framework AppKit -framework WebKit apps/macos/client_app/AppShell.swift
swiftc -typecheck -framework AppKit -framework CoreImage -framework Security -framework WebKit apps/macos/station_app/AppShell.swift

echo "product layout OK"
