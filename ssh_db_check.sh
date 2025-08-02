#!/bin/bash

echo "🔍 Подключение к серверу для проверки push notifications"
echo "=================================================="

# Подключение к серверу и выполнение проверок
ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "📱 Проверка push service статуса..."
echo "-----------------------------------"

# 1. Проверить статус pods
echo "1️⃣ Статус push-related pods:"
kubectl get pods -n matrix | grep -E "(push|livekit|sygnal)" || echo "❌ Push service pods не найдены"

# 2. Проверить логи push service
echo -e "\n2️⃣ Логи push service (последние ошибки):"
kubectl logs -n matrix -l app=livekit-push-service --tail=50 | grep -E "(ERROR|WARN|voip|VoIP|room_id|call_id)" || echo "ℹ️ Специфичных логов не найдено"

# 3. Проверить конфигурацию
echo -e "\n3️⃣ Проверка конфигурации push service:"
kubectl get configmaps -n matrix | grep -E "(push|livekit)" || echo "⚠️ Push ConfigMaps не найдены"

# 4. Проверить secrets (сертификаты)
echo -e "\n4️⃣ Проверка секретов (p8 сертификаты):"
kubectl get secrets -n matrix | grep -E "(apns|push|p8|cert)" || echo "⚠️ APNS секреты не найдены"

# 5. Проверить доступность endpoint
echo -e "\n5️⃣ Тест push endpoint:"
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" https://push.aibots.kz/_matrix/push/v1/notify || echo "❌ Push endpoint недоступен"

echo -e "\n6️⃣ Проверка базы данных Matrix..."
echo "-----------------------------------"

# Подключение к PostgreSQL
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb << 'ENDSQL'

\echo '📊 СТАТИСТИКА PUSHERS:'
SELECT 
    app_id,
    COUNT(*) as count,
    COUNT(DISTINCT user_name) as unique_users,
    MAX(ts) as last_registered_ts
FROM pushers
GROUP BY app_id
ORDER BY count DESC;

\echo ''
\echo '📱 VoIP PUSHERS (должны быть с .voip):'
SELECT 
    user_name,
    app_id,
    LEFT(pushkey, 20) || '...' as pushkey_prefix,
    device_display_name,
    to_timestamp(ts/1000) as registered_at
FROM pushers
WHERE app_id LIKE '%voip%'
ORDER BY ts DESC
LIMIT 10;

\echo ''
\echo '🔄 ПОСЛЕДНИЕ РЕГИСТРАЦИИ (24 часа):'
SELECT 
    user_name,
    app_id,
    device_display_name,
    to_timestamp(ts/1000) as registered_at,
    (EXTRACT(EPOCH FROM NOW()) * 1000 - ts)/1000/3600 as hours_ago
FROM pushers
WHERE ts > (EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours') * 1000)
ORDER BY ts DESC
LIMIT 15;

\echo ''
\echo '❗ ДУБЛИКАТЫ PUSHERS (потенциальная проблема):'
SELECT 
    user_name,
    app_id,
    COUNT(*) as duplicate_count
FROM pushers
GROUP BY user_name, app_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

\echo ''
\echo '📋 ИТОГО АКТИВНЫХ PUSHERS:'
SELECT COUNT(*) as total_pushers FROM pushers;

ENDSQL

echo -e "\n✅ Проверка завершена!"
echo "📋 Что проверить дальше:"
echo "1. Должно быть 2 типа app_id: обычный и .voip"
echo "2. Проверьте что pushkey не пустые"
echo "3. Регистрации должны быть недавними"
echo "4. Push service должен быть запущен"

ENDSSH

echo "🏁 SSH проверка завершена!"