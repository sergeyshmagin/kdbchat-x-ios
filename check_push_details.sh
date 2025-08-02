#!/bin/bash

echo "🔍 Детальная проверка push запросов"
echo "=================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Полные логи Push Service (последние push запросы):"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=500 | grep -A20 -B5 "Processing push notification" | tail -50

echo -e "\n2️⃣ Проверка что push service обрабатывает запросы:"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=200 | grep -E "(APNS|apns|ios|iPhone|testuser2)" | tail -10

echo -e "\n3️⃣ Ошибки в push service:"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=200 | grep -E "(Exception|Error|Failed|Traceback)" | tail -15

echo -e "\n4️⃣ Исправим SQL запрос и проверим push_actions:"
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb << ENDSQL

-- Проверяем таблицу pushers (правильное название колонок)
SELECT 
    u.name as user_name,
    p.app_id,
    left(p.pushkey, 20) || '...' as pushkey_prefix,
    p.last_stream_ordering,
    to_timestamp(p.ts/1000) as last_updated
FROM pushers p
JOIN users u ON p.user_name = u.name
WHERE u.name = '@testuser2:matrix.aibots.kz';

-- Последние push actions для testuser2
SELECT 
    epa.user_id,
    epa.room_id,
    epa.event_id,
    epa.stream_ordering,
    epa.actions
FROM event_push_actions epa
WHERE epa.user_id = '@testuser2:matrix.aibots.kz'
ORDER BY epa.stream_ordering DESC 
LIMIT 5;

ENDSQL

echo -e "\n5️⃣ Проверяем что Matrix отправляет push:"
kubectl logs -n matrix deployment/matrix-synapse --tail=1000 | grep -E "(push.*gateway|gateway.*push|push.*testuser2)" | tail -10

ENDSSH

echo "🏁 Детальная проверка завершена!"