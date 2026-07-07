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
tools/branding/generate_toytalk_icons.py
"

for path in $required_paths; do
  if [ ! -e "$path" ]; then
    echo "missing required product path: $path" >&2
    exit 1
  fi
done

grep -q 'ToyTalk Hub.app' packaging/macos/package.sh
grep -q 'apps/macos/station_app/AppShell.swift' packaging/macos/package.sh
grep -q 'apps/macos/client_app/AppShell.swift' packaging/macos/package.sh
grep -q 'Contents/Resources/ToyTalk.app' packaging/macos/package.sh
grep -q 'CLIENT_APP_BUILD' packaging/macos/package.sh
grep -q 'Use ToyTalk on this Mac' apps/macos/station_app/AppShell.swift
grep -q 'Bundle.main.resourceURL?.appendingPathComponent("ToyTalk.app"' apps/macos/station_app/AppShell.swift
grep -q 'ToyTalkHubBackgroundView' apps/macos/station_app/AppShell.swift
grep -q 'ToyTalkLogoView' apps/macos/station_app/AppShell.swift
grep -q 'NSSpeechRecognitionUsageDescription' packaging/macos/StationInfo.plist.in
grep -q 'NSSpeechRecognitionUsageDescription' packaging/macos/ClientInfo.plist.in
grep -q 'NSMicrophoneUsageDescription' packaging/macos/StationInfo.plist.in
grep -q 'NSMicrophoneUsageDescription' packaging/macos/ClientInfo.plist.in
grep -q 'HostLaunchContext' apps/macos/station_app/AppShell.swift
grep -q 'prepareHostLaunchContext' apps/macos/station_app/AppShell.swift
grep -q 'DispatchGroup' apps/macos/station_app/AppShell.swift
grep -q 'NSScrollView' apps/macos/station_app/AppShell.swift
grep -q 'hasVerticalScroller = true' apps/macos/station_app/AppShell.swift
grep -q 'Theme: ' apps/macos/station_app/AppShell.swift
grep -q 'ToyTalkTeddyPainter' apps/android/flutter_app/lib/src/app.dart
grep -q 'IOS_ICONSET' tools/branding/generate_toytalk_icons.py
grep -q 'STATION_WEB_ICONS' tools/branding/generate_toytalk_icons.py

sh -n packaging/macos/package.sh
swiftc -typecheck -framework AppKit -framework WebKit apps/macos/client_app/AppShell.swift
swiftc -typecheck -framework AppKit -framework CoreImage -framework Security -framework WebKit apps/macos/station_app/AppShell.swift

echo "product layout OK"
