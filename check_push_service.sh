#!/bin/bash

# Скрипт для проверки push service на сервере
# Запускать на сервере: ssh -i ~/.ssh/aibots_server aisha@95.58.199.128

echo "🔍 Проверка Push Service для iOS VoIP"
echo "====================================="

# 1. Проверить что push service работает
echo -e "\n1️⃣ Проверка состояния push service:"
kubectl get pods -n matrix | grep -E "(push|livekit)" || echo "❌ Push service не найден"

# 2. Проверить конфигурацию
echo -e "\n2️⃣ Проверка конфигурации push service:"
kubectl describe configmap -n matrix -l app=livekit-push-service 2>/dev/null || echo "⚠️ ConfigMap не найден"

# 3. Проверить логи за последние 5 минут
echo -e "\n3️⃣ Последние логи push service (ошибки):"
kubectl logs -n matrix -l app=livekit-push-service --tail=100 | grep -E "(ERROR|WARN|voip|VoIP)" || echo "✅ Ошибок не найдено"

# 4. Проверить формат push payload
echo -e "\n4️⃣ Проверка формата VoIP push (из логов):"
kubectl logs -n matrix -l app=livekit-push-service --tail=500 | grep -A5 -B5 "voip" | head -20

# 5. Проверить p8 сертификаты
echo -e "\n5️⃣ Проверка наличия p8 сертификатов:"
kubectl get secrets -n matrix | grep -E "(apns|push|p8)" || echo "⚠️ Секреты с сертификатами не найдены"

# 6. Тестовый запрос к push service
echo -e "\n6️⃣ Проверка доступности push endpoint:"
curl -s -o /dev/null -w "%{http_code}" https://push.aibots.kz/_matrix/push/v1/notify || echo "❌ Endpoint недоступен"

echo -e "\n\n📋 Что проверить вручную:"
echo "1. Формат VoIP push должен содержать:"
echo "   - room_id или roomId"
echo "   - call_id или event_id"
echo "   - caller_name или sender_display_name"
echo "   - Правильные APNs headers для p8:"
echo "     * apns-topic: io.sergeyshmagin.kdbchat.voip"
echo "     * apns-push-type: voip"
echo "     * apns-priority: 10"
echo ""
echo "2. В базе данных Matrix проверить pushers:"
echo "   PGPASSWORD='matrix_secure_pass' psql -h 192.168.0.4 -U matrix_user -d matrixdb"
echo "   SELECT * FROM pushers WHERE kind='http' ORDER BY ts DESC LIMIT 10;"