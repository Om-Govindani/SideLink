#!/bin/bash
set -e

# Change directory to the one containing this script
cd "$(dirname "$0")"

echo "=========================================="
echo "      SideLink macOS Host Build Script    "
echo "=========================================="

# Check if Xcode Command Line Tools are available
if ! command -v swiftc &> /dev/null; then
    echo "Error: Swift compiler (swiftc) not found."
    echo "Please install Xcode Command Line Tools by running: xcode-select --install"
    exit 1
fi

# Resolve the active macOS SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
echo "Resolved macOS SDK: $SDK_PATH"

echo "Compiling swift files..."
swiftc -sdk "$SDK_PATH" \
       -import-objc-header SideLinkHost/Display/CoreGraphicsBridge.h \
       SideLinkHost/SideLinkHostApp.swift \
       SideLinkHost/Display/VirtualDisplayManager.swift \
       SideLinkHost/Display/ScreenCaptureManager.swift \
       SideLinkHost/Display/VideoEncoder.swift \
       SideLinkHost/Network/NetworkManager.swift \
       SideLinkHost/Input/InputInjector.swift \
       -framework SwiftUI \
       -framework ScreenCaptureKit \
       -framework VideoToolbox \
       -framework CoreGraphics \
       -framework CoreImage \
       -framework Network \
       -o SideLinkHostApp

echo "Compilation successful!"
echo "Executable generated: ./SideLinkHostApp"
echo "Run it using: ./SideLinkHostApp"
echo "=========================================="
