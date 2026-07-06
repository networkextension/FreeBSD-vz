#!/bin/sh
# Build and ad-hoc-sign the FreeBSDVZ launcher.
# Requires macOS 13+ and the Xcode command line tools.
set -e
cd "$(dirname "$0")"

swiftc -O -target arm64-apple-macos14.0 -o FreeBSDVZ main.swift

# The com.apple.security.virtualization entitlement is required for the VM to
# start.  It is not a restricted entitlement, so ad-hoc signing (-s -) works.
codesign --force --sign - --entitlements FreeBSDVZ.entitlements FreeBSDVZ

echo "Built ./FreeBSDVZ"
echo "Run: ./FreeBSDVZ <disk-image> [seed-image]"
