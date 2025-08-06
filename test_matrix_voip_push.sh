#!/bin/bash

echo "=== Тест VoIP Push в формате Matrix ==="

# Правильный VoIP токен из логов testuser1
VOIP_TOKEN="0e474db75ec75b063888362a02bb9a9ec76d5659a80a21ccfd8202e15d7b0554"
CALL_ID="call_$(date +%s)_$(uuidgen | head -c 8)"

echo "📞 Используем call_id: $CALL_ID"
echo "📱 Используем VoIP токен: $VOIP_TOKEN"

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << EOF
echo "🚀 Отправка VoIP push в формате Matrix..."

# Создаем JSON файл в стандартном формате Matrix push
cat > /tmp/test_matrix_voip.json << JSON
{
  "notification": {
    "counts": {"unread": 0},
    "devices": [{
      "app_id": "io.sergeyshmagin.kdbchat.voip",
      "data": {
        "default_payload": {
          "aps": {
            "alert": {
              "title": "Incoming call",
              "body": "From testcaller"
            },
            "sound": "default",
            "content-available": 1
          }
        },
        "format": "event_id_only"
      },
      "pushkey": "$VOIP_TOKEN",
      "pushkey_ts": $(date +%s)
    }],
    "id": "test-matrix-voip",
    "sender": "@testcaller:matrix.aibots.kz",
    "type": "m.call.invite",
    "room_id": "!test:matrix.aibots.kz",
    "room_name": "Test Room",
    "event_id": "$CALL_ID",
    "call_id": "$CALL_ID",
    "caller_id": "@testcaller:matrix.aibots.kz",
    "caller_name": "testcaller",
    "call_type": "voip",
    "has_video": 1
  }
}
JSON

echo "📦 Payload structure:"
cat /tmp/test_matrix_voip.json | head -20

# Получаем IP push-сервиса
PUSH_SERVICE_IP=\$(kubectl get svc -n matrix-stack livekit-push-service -o jsonpath='{.spec.clusterIP}')
echo "Push service IP: \$PUSH_SERVICE_IP"

# Отправляем через временный pod с curl
kubectl run test-matrix-voip --rm -i --restart=Never --image=alpine/curl -- \\
  curl -X POST "http://\$PUSH_SERVICE_IP:5500/_matrix/push/v1/notify" \\
  -H "Content-Type: application/json" \\
  --data-binary @- < /tmp/test_matrix_voip.json

echo ""
echo "📋 Проверяем логи push-сервиса:"
kubectl logs deployment/livekit-push-service -n matrix-stack --tail=15 | grep -A3 -B3 "SUCCESS\\|0e474db7"

echo ""
echo "✅ Тест завершен. Проверьте устройство testuser1!"
EOF