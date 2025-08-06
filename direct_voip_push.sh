#!/bin/bash

echo "=== Прямая отправка VoIP Push на testuser1 ==="

# Токен testuser1 из базы данных
DEVICE_TOKEN="eff408efc511ac1bf14729bafa63c713b280d944bbe973396e8bc65d6a02f620"

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'EOF'
# Проверяем токен в базе
echo "📱 Проверка токена testuser1 в базе данных:"
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb -t -c "SELECT pushkey FROM pushers WHERE user_name = '@testuser1:matrix.aibots.kz' AND app_id = 'io.sergeyshmagin.kdbchat.voip' LIMIT 1;" | xargs

# Отправляем тестовый запрос в push-сервис
echo ""
echo "🚀 Отправка тестового VoIP push..."

# Используем wget вместо curl
cd /tmp
cat > test_push.json << JSON
{
  "notification": {
    "counts": {"unread": 0},
    "devices": [{
      "app_id": "io.sergeyshmagin.kdbchat.voip",
      "data": {
        "default_payload": {
          "aps": {
            "alert": {
              "loc-args": ["Test Caller"],
              "loc-key": "Incoming call from %@"
            },
            "sound": "default",
            "mutable-content": 1
          }
        },
        "format": "event_id_only"
      },
      "pushkey": "eff408efc511ac1bf14729bafa63c713b280d944bbe973396e8bc65d6a02f620",
      "pushkey_ts": 1754396049
    }],
    "id": "test-voip-123",
    "sender": "@testcaller:matrix.aibots.kz",
    "type": "m.call.invite",
    "room_id": "!test:matrix.aibots.kz",
    "room_name": "Test Room",
    "event_id": "$test123"
  }
}
JSON

# Находим IP push-сервиса
PUSH_SERVICE_IP=$(kubectl get svc -n matrix-stack livekit-push-service -o jsonpath='{.spec.clusterIP}')
echo "Push service IP: $PUSH_SERVICE_IP"

# Отправляем через wget из пода, где есть доступ к сервису
kubectl run test-push --rm -i --restart=Never --image=alpine/curl -- \
  curl -X POST "http://$PUSH_SERVICE_IP:5500/_matrix/push/v1/notify" \
  -H "Content-Type: application/json" \
  --data-binary @- < test_push.json

# Смотрим логи push-сервиса
echo ""
echo "📋 Последние логи push-сервиса:"
kubectl logs deployment/livekit-push-service -n matrix-stack --tail=30 | grep -A10 -B10 "eff408ef"
EOF