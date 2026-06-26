#!/bin/bash
set -e

# Change directory to the one containing this script
cd "$(dirname "$0")"

echo "=========================================="
echo "    SideLink Android Client Build Script  "
echo "=========================================="

# Check if Java is installed
if ! command -v java &> /dev/null; then
    echo "Error: Java (JDK 17+) is required to run Gradle."
    echo "You can install it using Homebrew: brew install --cask temurin"
    exit 1
fi

# Force JAVA_HOME to JDK 21 since Gradle 8.5 does not support running on JDK 26.
if [ -d "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home" ]; then
    export JAVA_HOME="/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home"
    echo "Forcing JAVA_HOME to JDK 21: $JAVA_HOME"
fi

# Locate the Android SDK path and configure environment variable
if [ -z "$ANDROID_HOME" ]; then
    if [ -d "/opt/homebrew/share/android-commandlinetools" ]; then
        export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
    elif [ -d "/usr/local/share/android-commandlinetools" ]; then
        export ANDROID_HOME="/usr/local/share/android-commandlinetools"
    elif [ -d "$HOME/Library/Android/sdk" ]; then
        export ANDROID_HOME="$HOME/Library/Android/sdk"
    fi
fi

if [ -n "$ANDROID_HOME" ]; then
    echo "Using Android SDK at: $ANDROID_HOME"
else
    echo "Warning: ANDROID_HOME is not set. The build may fail if SDK tools are not in default system paths."
    echo "You can install the command-line tools using Homebrew: brew install --cask android-commandlinetools"
fi

# Determine build command
if [ -f "./gradlew" ]; then
    echo "Setting Gradle wrapper permissions..."
    chmod +x gradlew
    BUILD_CMD="./gradlew"
elif command -v gradle &> /dev/null; then
    echo "Gradle wrapper not found. Using global gradle installation..."
    BUILD_CMD="gradle"
else
    echo "Error: Neither local ./gradlew wrapper nor global 'gradle' command was found."
    echo "Please install Gradle using Homebrew:"
    echo "  brew install gradle"
    exit 1
fi

echo "Compiling APK via $BUILD_CMD..."
$BUILD_CMD assembleDebug

echo "=========================================="
echo "Compilation successful!"
echo "APK generated: app/build/outputs/apk/debug/app-debug.apk"
echo "=========================================="
