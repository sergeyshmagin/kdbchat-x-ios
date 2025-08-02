#!/bin/bash

echo "🧪 Тестирование push service"
echo "=========================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Проверка статуса push service..."
kubectl get pods -n matrix -o wide | grep -E "(push|livekit)"

echo -e "\n2️⃣ Проверка портов и сервисов..."
kubectl get services -n matrix | grep -E "(push|livekit)"

echo -e "\n3️⃣ Последние логи push service..."
echo "Логи за последние 10 минут:"
kubectl logs -n matrix -l app=livekit-push-service --since=10m | tail -20

echo -e "\n4️⃣ Тест доступности push endpoint..."
echo "Тестируем https://push.aibots.kz/_matrix/push/v1/notify"
curl -v -X POST https://push.aibots.kz/_matrix/push/v1/notify \
  -H "Content-Type: application/json" \
  -d '{"test": true}' \
  --connect-timeout 10 \
  --max-time 30 || echo "❌ Endpoint недоступен или не отвечает"

echo -e "\n5️⃣ Проверка конфигурации push service..."
kubectl describe pod -n matrix -l app=livekit-push-service | grep -A5 -B5 -E "(Env|Volume|Mount)"

echo -e "\n6️⃣ Проверка секретов для APNS..."
kubectl get secrets -n matrix | grep -E "(apns|push|p8|cert|key)"

echo -e "\n7️⃣ Проверка переменных окружения..."
kubectl get pods -n matrix -l app=livekit-push-service -o jsonpath='{.items[0].spec.containers[0].env}' | jq '.' 2>/dev/null || echo "jq не установлен или переменные не найдены"

ENDSSH

echo "🏁 Тестирование завершено!"
echo ""
echo "📋 Что проверить в результатах:"
echo "✅ Push service pod должен быть Running"
echo "✅ Service должен быть доступен"
echo "✅ Endpoint должен отвечать (не 404/500)"
echo "✅ Логи не должны содержать критических ошибок"
echo "✅ Секреты с p8 сертификатами должны быть смонтированы"