#!/bin/bash

# Скрипт диагностики проблем с Recovery Key Setup

echo "🔍 RECOVERY KEY SETUP DIAGNOSTICS"
echo "=================================="

# 1. Проверяем текущие настройки keychain
echo ""
echo "📱 KEYCHAIN STATUS:"
security dump-keychain -d login.keychain 2>/dev/null | grep -i "matrix\|element\|recovery" | head -10 || echo "No Matrix/Element entries found in keychain"

# 2. Проверяем логи приложения
echo ""
echo "📜 RECENT APP LOGS (Recovery related):"
log show --predicate 'subsystem CONTAINS "ElementX" AND message CONTAINS "recovery"' --last 1h --style compact | tail -20

# 3. Проверяем состояние backup через Matrix
echo ""
echo "🔐 MATRIX BACKUP STATUS:"
echo "Run this in app developer console or check Settings->Developer Options"

# 4. Проверяем доступность keychain после логина
echo ""
echo "🗝️ KEYCHAIN ACCESSIBILITY TEST:"
echo "Checking if keychain is accessible after login..."

# Проверяем доступность biometric/passcode
security show-keychain-info login.keychain 2>/dev/null || echo "Login keychain not accessible"

echo ""
echo "⚠️ COMMON ISSUES TO CHECK:"
echo "1. Device passcode enabled (required for secure keychain)"
echo "2. App background refresh enabled"
echo "3. No concurrent recovery operations"
echo "4. Stable network connection"
echo "5. Matrix server accessibility"

echo ""
echo "🩺 NEXT STEPS:"
echo "1. Check app logs: Settings -> Developer Options -> Export Logs"
echo "2. Clear recovery keys: Settings -> Developer Options -> Clear All Recovery Keys"
echo "3. Try manual setup: Settings -> Encryption -> Recovery Key"
echo "4. Check server backup status"

echo ""
echo "📊 To run detailed diagnostics in app:"
echo "Settings -> Developer Options -> Comprehensive Push Diagnostics"