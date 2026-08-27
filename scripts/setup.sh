#!/bin/bash

# WordSnap Setup & Build Script

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PROJECT_ROOT/app"
BUILD_DIR="$PROJECT_ROOT/build"

echo -e "${BLUE}==> WordSnap Build Setup${NC}"
echo ""

# Step 1: Check xcodegen
echo -e "${BLUE}[1/3] Checking xcodegen...${NC}"
if ! command -v xcodegen &> /dev/null; then
    echo -e "${RED}xcodegen not found. Installing...${NC}"
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo -e "${RED}Error: Homebrew not installed. Please install xcodegen manually.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}xcodegen ready${NC}"

# Step 2: Generate Xcode project
echo ""
echo -e "${BLUE}[2/3] Generating Xcode project...${NC}"
cd "$APP_DIR"
xcodegen generate
echo -e "${GREEN}Xcode project generated${NC}"

# Step 3: Build
echo ""
echo -e "${BLUE}[3/3] Building WordSnap...${NC}"
mkdir -p "$BUILD_DIR"
xcodebuild -project WordSnap.xcodeproj \
    -scheme WordSnap \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    build || exit 1

echo ""
echo -e "${GREEN}==> Build Complete!${NC}"
echo ""
echo "App location: $BUILD_DIR/DerivedData/Build/Products/Debug/WordSnap.app"
echo ""
echo "To run:"
echo "  open \"$BUILD_DIR/DerivedData/Build/Products/Debug/WordSnap.app\""
