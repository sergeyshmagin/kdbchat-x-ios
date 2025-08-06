#!/bin/bash

echo "=== Тестовая отправка VoIP Push с правильным токеном testuser1 ==="

# Правильный VoIP токен из логов testuser1
VOIP_TOKEN="0e474db75ec75b063888362a02bb9a9ec76d5659a80a21ccfd8202e15d7b0554"

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << EOF
echo "🚀 Отправка тестового VoIP push с правильным VoIP токеном..."

# Создаем JSON файл с правильным запросом
cat > /tmp/test_voip_with_correct_token.json << JSON
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
      "pushkey": "$VOIP_TOKEN",
      "pushkey_ts": 1754396049
    }],
    "id": "test-voip-correct-token",
    "sender": "@testcaller:matrix.aibots.kz",
    "type": "m.call.invite",
    "room_id": "!test:matrix.aibots.kz",
    "room_name": "Test Room",
    "event_id": "\$test123"
  }
}
JSON

# Получаем IP push-сервиса
PUSH_SERVICE_IP=\$(kubectl get svc -n matrix-stack livekit-push-service -o jsonpath='{.spec.clusterIP}')
echo "Push service IP: \$PUSH_SERVICE_IP"

# Отправляем через временный pod с curl
kubectl run test-voip-correct --rm -i --restart=Never --image=alpine/curl -- \\
  curl -X POST "http://\$PUSH_SERVICE_IP:5500/_matrix/push/v1/notify" \\
  -H "Content-Type: application/json" \\
  --data-binary @- < /tmp/test_voip_with_correct_token.json

echo ""
echo "📋 Смотрим логи push-сервиса:"
kubectl logs deployment/livekit-push-service -n matrix-stack --tail=20 | grep -A5 -B5 "0e474db7\\|SUCCESS\\|DeviceTokenNotForTopic"
EOF