#!/bin/bash

# Скрипт для проверки pushers конкретного пользователя
# Использование: ./check_user_pushers.sh @username:aibots.kz

if [ $# -eq 0 ]; then
    echo "❌ Укажите имя пользователя!"
    echo "Использование: $0 @username:aibots.kz"
    exit 1
fi

USERNAME="$1"
echo "🔍 Проверка pushers для пользователя: $USERNAME"
echo "=============================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << ENDSSH

echo "📱 Pushers для пользователя $USERNAME:"
echo "-----------------------------------"

PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb << ENDSQL

-- Все pushers пользователя
SELECT 
    user_name,
    app_id,
    pushkey,
    kind,
    app_display_name,
    device_display_name,
    profile_tag,
    to_timestamp(ts/1000) as registered_at,
    (EXTRACT(EPOCH FROM NOW()) * 1000 - ts)/1000/3600 as hours_ago,
    data
FROM pushers 
WHERE user_name = '$USERNAME'
ORDER BY ts DESC;

-- Проверка что есть оба типа pushers
\echo ''
\echo '📊 Типы pushers для этого пользователя:'
SELECT 
    app_id,
    COUNT(*) as count,
    MAX(to_timestamp(ts/1000)) as last_registered
FROM pushers 
WHERE user_name = '$USERNAME'
GROUP BY app_id;

-- Проверка недавних регистраций
\echo ''
\echo '🕐 Недавние регистрации (последние 48 часов):'
SELECT 
    app_id,
    device_display_name,
    to_timestamp(ts/1000) as registered_at
FROM pushers 
WHERE user_name = '$USERNAME'
  AND ts > (EXTRACT(EPOCH FROM NOW() - INTERVAL '48 hours') * 1000)
ORDER BY ts DESC;

ENDSQL

echo ""
echo "🎯 Что должно быть:"
echo "✅ 2 записи pushers:"
echo "   - io.sergeyshmagin.kdbchat (обычные push)"
echo "   - io.sergeyshmagin.kdbchat.voip (VoIP push)"
echo "✅ pushkey не должен быть пустым"
echo "✅ Регистрация должна быть недавней (несколько часов назад)"
echo "✅ device_display_name должен быть читаемым"

ENDSSH