#!/bin/bash

echo "📋 Проверка логов LiveKit push service"
echo "====================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Статус livekit-push-service:"
kubectl get pods -n matrix-stack | grep livekit-push

echo -e "\n2️⃣ Логи push service (последние 100 строк):"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=100

echo -e "\n3️⃣ Логи push service (ошибки и VoIP):"
kubectl logs -n matrix-stack deployment/livekit-push-service --tail=500 | grep -E "(ERROR|WARN|VoIP|voip|room_id|call_id|@testuser2)" | tail -20

echo -e "\n4️⃣ Services в matrix-stack:"
kubectl get services -n matrix-stack

echo -e "\n5️⃣ ConfigMaps для push service:"
kubectl get configmaps -n matrix-stack | grep -E "(push|livekit)"

echo -e "\n6️⃣ Secrets для APNS в matrix-stack:"
kubectl get secrets -n matrix-stack | grep -E "(apns|push|cert|key|p8)"

echo -e "\n7️⃣ Describe push service:"
kubectl describe deployment -n matrix-stack livekit-push-service | grep -A10 -B5 -E "(Env|Image|Port|Volume)"

echo -e "\n8️⃣ Тест доступности push service изнутри кластера:"
kubectl exec -n matrix-stack deployment/livekit-push-service -- curl -s -X POST http://localhost:8080/_matrix/push/v1/notify -H "Content-Type: application/json" -d '{"test":true}' 2>/dev/null || echo "Push endpoint недоступен внутри пода"

ENDSSH

echo "🏁 Проверка push service завершена!"