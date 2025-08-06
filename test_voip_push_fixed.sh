#!/bin/bash

echo "=== Исправленный тест VoIP Push с правильным call_id ==="

# Правильный VoIP токен из логов testuser1
VOIP_TOKEN="0e474db75ec75b063888362a02bb9a9ec76d5659a80a21ccfd8202e15d7b0554"
CALL_ID="call_$(date +%s)_$(uuidgen | head -c 8)"

echo "📞 Используем call_id: $CALL_ID"
echo "📱 Используем VoIP токен: $VOIP_TOKEN"

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << EOF
echo "🚀 Отправка VoIP push с правильным call_id..."

# Создаем JSON файл с исправленным запросом
cat > /tmp/test_voip_fixed.json << JSON
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
            "mutable-content": 1,
            "content-available": 1
          },
          "call_id": "$CALL_ID",
          "caller_id": "@testcaller:matrix.aibots.kz",
          "caller_name": "Test Caller",
          "room_id": "!test:matrix.aibots.kz",
          "event_id": "$CALL_ID",
          "call_type": "voip",
          "has_video": "1"
        },
        "format": "event_id_only"
      },
      "pushkey": "$VOIP_TOKEN",
      "pushkey_ts": $(date +%s)
    }],
    "id": "test-voip-fixed-$CALL_ID",
    "sender": "@testcaller:matrix.aibots.kz",
    "type": "m.call.invite",
    "room_id": "!test:matrix.aibots.kz",
    "room_name": "Test Room",
    "event_id": "$CALL_ID"
  }
}
JSON

# Получаем IP push-сервиса
PUSH_SERVICE_IP=\$(kubectl get svc -n matrix-stack livekit-push-service -o jsonpath='{.spec.clusterIP}')
echo "Push service IP: \$PUSH_SERVICE_IP"

# Отправляем через временный pod с curl
kubectl run test-voip-fixed --rm -i --restart=Never --image=alpine/curl -- \\
  curl -X POST "http://\$PUSH_SERVICE_IP:5500/_matrix/push/v1/notify" \\
  -H "Content-Type: application/json" \\
  --data-binary @- < /tmp/test_voip_fixed.json

echo ""
echo "📋 Проверяем логи push-сервиса:"
kubectl logs deployment/livekit-push-service -n matrix-stack --tail=20 | grep -A5 -B5 "0e474db7\\|SUCCESS\\|DeviceTokenNotForTopic"

echo ""
echo "✅ Тест завершен. Проверьте устройство testuser1 на входящий звонок!"
EOF