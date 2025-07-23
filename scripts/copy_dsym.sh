#!/bin/bash

# Script to copy missing dSYM files for external frameworks
# This fixes "Upload Symbols Failed" warnings in App Store Connect

set -e

echo "🔧 Copying dSYM files for external frameworks..."

# Define the dSYM directory in the archive
DSYM_DIR="${DWARF_DSYM_FOLDER_PATH}"

if [ -z "$DSYM_DIR" ]; then
    echo "⚠️  DWARF_DSYM_FOLDER_PATH not set, using default"
    DSYM_DIR="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}.dSYM"
fi

echo "📁 dSYM directory: $DSYM_DIR"

# Function to copy dSYM if it exists
copy_dsym_if_exists() {
    local framework_name="$1"
    local framework_path="${BUILT_PRODUCTS_DIR}/${framework_name}.framework"
    local dsym_path="${framework_path}.dSYM"
    
    if [ -d "$dsym_path" ]; then
        echo "✅ Found dSYM for $framework_name, copying..."
        cp -R "$dsym_path" "${DSYM_DIR}/"
    else
        echo "⚠️  dSYM not found for $framework_name at $dsym_path"
        
        # Try to find in SourcePackages
        local sourcepackages_dsym=$(find "${PROJECT_DIR}" -name "${framework_name}.framework.dSYM" -type d 2>/dev/null | head -1)
        if [ -n "$sourcepackages_dsym" ]; then
            echo "✅ Found dSYM for $framework_name in SourcePackages, copying..."
            cp -R "$sourcepackages_dsym" "${DSYM_DIR}/"
        else
            echo "❌ Could not find dSYM for $framework_name anywhere"
        fi
    fi
}

# Create dSYM directory if it doesn't exist
mkdir -p "$DSYM_DIR"

# Copy dSYM files for problematic frameworks
copy_dsym_if_exists "LiveKitWebRTC"
copy_dsym_if_exists "Sentry" 
copy_dsym_if_exists "YbridOgg"
copy_dsym_if_exists "YbridOpus"

echo "✅ dSYM copy script completed"