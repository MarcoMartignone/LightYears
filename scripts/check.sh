#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc ${MODEL_SDK:+-sdk "$MODEL_SDK"} -module-cache-path .build/module-cache MemoryJourney/Memory.swift MemoryJourney/MediaDiskCache.swift Tests/main.swift -o .build/model-checks
.build/model-checks
swiftc -frontend -parse MemoryJourney/*.swift
plutil -lint MemoryJourney.xcodeproj/project.pbxproj
