#!/bin/bash

echo "🧹 FORCE CLEAN BUILD - FIXING ENTITLEMENTS ISSUE"
echo "================================================="

# 1. Проверяем что entitlements исправлены
echo ""
echo "🔍 CHECKING ENTITLEMENTS FILES:"
echo "--------------------------------"

if grep -q "application-identifier" /Users/sergeysh/Dev/KDB_MESSENDGER_IOS/ElementX/SupportingFiles/ElementX.entitlements; then
    echo "✅ Debug entitlements fixed"
else
    echo "❌ Debug entitlements NOT fixed"
    exit 1
fi

if grep -q "application-identifier" /Users/sergeysh/Dev/KDB_MESSENDGER_IOS/ElementX/ElementXRelease.entitlements; then
    echo "✅ Release entitlements fixed"
else
    echo "❌ Release entitlements NOT fixed"
    exit 1
fi

# 2. Удаляем все кэши и производные данные
echo ""
echo "🗑️ CLEANING BUILD CACHES:"
echo "-------------------------"

echo "Cleaning Xcode DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/ElementX-*
echo "✅ DerivedData cleared"

echo "Cleaning project build directory..."
cd /Users/sergeysh/Dev/KDB_MESSENDGER_IOS
xcodebuild clean -project ElementX.xcodeproj -scheme ElementX
echo "✅ Project cleaned"

# 3. Очищаем Module Cache
echo "Cleaning Module Cache..."
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/*
echo "✅ Module Cache cleared"

# 4. Выбор устройства
echo ""
echo "📱 AVAILABLE DEVICES:"
echo "--------------------"
xcrun xctrace list devices

echo ""
echo "🏗️ FORCE REBUILD:"
echo "-----------------"

# Проверяем подключенные реальные устройства
REAL_DEVICE=$(xcrun xctrace list devices | grep -E "iPhone.*\([0-9A-F-]{36}\)" | head -1 | sed 's/.*(\([0-9A-F-]*\)).*/\1/')

if [ ! -z "$REAL_DEVICE" ]; then
    echo "📱 Found real iPhone device: $REAL_DEVICE"
    echo "Building and installing on real device..."
    
    # Сборка и установка на реальное устройство
    xcodebuild -project ElementX.xcodeproj -scheme ElementX -destination "platform=iOS,id=$REAL_DEVICE" -configuration Debug archive -archivePath ./build/ElementX.xcarchive
    
    if [ $? -eq 0 ]; then
        echo "✅ Archive created successfully"
        
        # Создаем .ipa файл для установки
        xcodebuild -exportArchive -archivePath ./build/ElementX.xcarchive -exportPath ./build -exportOptionsPlist ./export_options.plist
        
        # Устанавливаем на устройство через xcrun
        echo "Installing on device..."
        xcrun devicectl device install app --device "$REAL_DEVICE" ./build/ElementX.ipa
    fi
else
    echo "📱 No real device found. Building for simulator..."
    xcodebuild -project ElementX.xcodeproj -scheme ElementX -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ BUILD SUCCESSFUL!"
    echo ""
    echo "📋 NEXT STEPS:"
    echo "1. Run the app from Xcode"
    echo "2. Go to Settings -> Developer Options -> 🩺 Diagnose Recovery Keys"
    echo "3. Check that entitlements errors are gone"
    echo "4. Test recovery key setup"
    echo ""
else
    echo ""
    echo "❌ BUILD FAILED!"
    echo "Check the error messages above"
fi