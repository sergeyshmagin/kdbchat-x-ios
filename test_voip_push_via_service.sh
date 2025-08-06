#!/bin/bash

echo "=== Отправка тестового VoIP Push через livekit-push-service ==="

# Создаем тестовый запрос
ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 'cat > /tmp/test_voip_request.py << EOF
#!/usr/bin/env python3
import requests
import json

# URL push-сервиса (внутри кластера)
PUSH_SERVICE_URL = "http://livekit-push-service.matrix-stack:5500/_matrix/push/v1/notify"

# Тестовый запрос в формате Matrix Push Gateway
test_request = {
    "notification": {
        "counts": {
            "unread": 0
        },
        "devices": [
            {
                "app_id": "io.sergeyshmagin.kdbchat.voip",
                "data": {
                    "default_payload": {
                        "aps": {
                            "alert": {
                                "loc-args": [],
                                "loc-key": "Incoming call"
                            },
                            "mutable-content": 1
                        },
                        "pusher_notification_client_identifier": "test123"
                    },
                    "format": "event_id_only"
                },
                "pushkey": "eff408efc511ac1bf14729bafa63c713b280d944bbe973396e8bc65d6a02f620",
                "pushkey_ts": 1754396049
            }
        ],
        "id": "test-voip-push",
        "sender": "@testcaller:matrix.aibots.kz",
        "type": "m.call.invite",
        "room_id": "!test:matrix.aibots.kz",
        "room_name": "Test Call",
        "event_id": "$test123",
        "sender_display_name": "Test Caller"
    }
}

print("📱 Отправка тестового VoIP push запроса...")
print(f"🎯 URL: {PUSH_SERVICE_URL}")
print(f"📋 Payload: {json.dumps(test_request, indent=2)}")

try:
    response = requests.post(PUSH_SERVICE_URL, json=test_request)
    print(f"✅ Ответ сервера: {response.status_code}")
    print(f"📋 Результат: {response.text}")
except Exception as e:
    print(f"❌ Ошибка: {e}")
EOF

# Запускаем из pod где есть доступ к сервису
kubectl exec -n matrix-stack deployment/matrix-synapse -- python3 /tmp/test_voip_request.py
'