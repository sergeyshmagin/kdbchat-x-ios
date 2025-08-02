#!/bin/bash

echo "🧪 Проверка результатов тестирования push notifications"
echo "===================================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Логи Matrix Synapse (последние push события):"
kubectl logs -n matrix deployment/matrix-synapse --tail=200 | grep -E "(push|testuser)" | tail -15

echo -e "\n2️⃣ Логи Push Service (последние запросы):"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=100 | grep -E "(POST|push|testuser|room_id)" | tail -15

echo -e "\n3️⃣ Логи Push Service (ошибки):"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=200 | grep -E "(ERROR|WARN|Exception|Failed)" | tail -10

echo -e "\n4️⃣ Активные соединения к push service:"
kubectl exec -n matrix-stack deployment/livekit-push-service -- netstat -an | grep :5500 || echo "netstat недоступен"

echo -e "\n5️⃣ Тест push service изнутри кластера:"
kubectl run curl-test --rm -i --tty --restart=Never --image=curlimages/curl -- \
  curl -X POST \
  http://livekit-push-service.matrix-stack.svc.cluster.local:5500/_matrix/push/v1/notify \
  -H "Content-Type: application/json" \
  -d '{"notification": {"event_id": "test", "room_id": "test"}, "devices": [{"app_id": "io.sergeyshmagin.kdbchat", "pushkey": "test"}]}' \
  -v || echo "Curl тест не удался"

echo -e "\n6️⃣ События push_actions в базе данных:"
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb << ENDSQL

-- Последние push actions для testuser2
SELECT 
    user_name,
    room_id,
    event_id,
    to_timestamp(stream_ordering) as event_time,
    actions,
    highlight
FROM event_push_actions 
WHERE user_name = '@testuser2:matrix.aibots.kz'
ORDER BY stream_ordering DESC 
LIMIT 10;

-- Проверяем что pushers активны
SELECT 
    user_name,
    app_id,
    pushkey,
    last_stream_ordering,
    to_timestamp(ts/1000) as last_updated
FROM pushers 
WHERE user_name = '@testuser2:matrix.aibots.kz';

ENDSQL

ENDSSH

echo "🏁 Проверка результатов завершена!"