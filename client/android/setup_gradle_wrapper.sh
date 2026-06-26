#!/bin/bash
set -e

# Change directory to the one containing this script
cd "$(dirname "$0")"

echo "=========================================="
echo "      SideLink Gradle Wrapper Setup       "
echo "=========================================="

echo "Creating gradle wrapper directories..."
mkdir -p gradle/wrapper

echo "Downloading gradlew shell script..."
curl -Lo gradlew https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew

echo "Downloading gradle-wrapper.jar..."
curl -Lo gradle/wrapper/gradle-wrapper.jar https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradle/wrapper/gradle-wrapper.jar

echo "Writing gradle-wrapper.properties..."
cat <<EOT > gradle/wrapper/gradle-wrapper.properties
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.5-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOT

echo "Setting execute permissions on gradlew..."
chmod +x gradlew

echo "=========================================="
echo "Setup complete!"
echo "You can now compile the app by running:"
echo "  ./build.sh"
echo "=========================================="
