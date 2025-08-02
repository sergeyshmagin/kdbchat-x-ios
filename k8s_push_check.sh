#!/bin/bash

echo "🔍 Проверка push service в Kubernetes кластере"
echo "=============================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Все pods в namespace matrix:"
kubectl get pods -n matrix -o wide

echo -e "\n2️⃣ Статус services в matrix namespace:"
kubectl get services -n matrix

echo -e "\n3️⃣ Поиск push/livekit pods:"
kubectl get pods -A | grep -E "(push|livekit)"

echo -e "\n4️⃣ Логи Matrix Synapse (последние push события):"
kubectl logs -n matrix deployment/matrix-synapse --tail=100 | grep -i push | tail -10

echo -e "\n5️⃣ Логи LiveKit push service:"
kubectl logs -n matrix -l app=livekit --tail=50 | grep -E "(push|VoIP|room_id|call)" | head -20

echo -e "\n6️⃣ Проверка configmaps для push:"
kubectl get configmaps -n matrix | grep -E "(push|livekit|matrix)"

echo -e "\n7️⃣ Проверка secrets для APNS:"
kubectl get secrets -n matrix | grep -E "(apns|push|cert|key|p8)"

echo -e "\n8️⃣ Describe push service deployment:"
kubectl get deployments -n matrix | grep -E "(push|livekit)"

echo -e "\n9️⃣ Проверка ingress/routes для push endpoint:"
kubectl get ingress -n matrix
kubectl get routes -n matrix 2>/dev/null || echo "Routes не используются"

echo -e "\n🔟 Тест внутренней доступности push service:"
kubectl exec -n matrix deployment/matrix-synapse -- curl -s -o /dev/null -w "Status: %{http_code}" http://livekit-push-service:8080/health 2>/dev/null || echo "Health endpoint недоступен"

ENDSSH

echo "🏁 Kubernetes проверка завершена!"