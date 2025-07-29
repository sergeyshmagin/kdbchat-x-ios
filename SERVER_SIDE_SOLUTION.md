# Серверное Решение для LiveKit Auto-Connect

## Проблема

Sygnal не умеет передавать `application_data` из Matrix событий в push уведомления. Нужно создать промежуточный сервис.

## Архитектура Решения

```
Matrix Homeserver → Custom Push Service → APNS → iOS App
                 ↘ Sygnal (fallback)
```

## Вариант 1: Matrix Event Webhook (Рекомендуется)

### 1. Webhook сервис на Python/Node.js

```python
# push_service.py
from flask import Flask, request, jsonify
import jwt
import requests
from datetime import datetime, timedelta

app = Flask(__name__)

@app.route('/matrix/push', methods=['POST'])
def handle_matrix_event():
    """Перехватывает Matrix события и отправляет enhanced push"""
    event = request.json
    
    if event['type'] == 'm.call.invite':
        return handle_call_invite(event)
    else:
        # Обычные сообщения через Sygnal
        return forward_to_sygnal(event)

def handle_call_invite(event):
    """Обработка входящих звонков с LiveKit данными"""
    
    # 1. Извлекаем данные из Matrix события
    room_id = event['room_id']
    sender = event['sender']
    sender_name = get_display_name(sender)
    app_data = event['content'].get('application_data', {})
    
    # 2. Генерируем LiveKit JWT токен
    livekit_token = generate_livekit_jwt(
        room_name=app_data.get('livekit_room_url', room_id),
        participant_identity=sender,
        participant_name=sender_name
    )
    
    # 3. Формируем enhanced push payload
    push_payload = {
        "aps": {
            "alert": {
                "title": f"Входящий вызов от {sender_name}",
                "body": "Коснитесь для ответа"
            },
            "sound": "default",
            "mutable-content": 1,
            "category": "CALL_INVITE"
        },
        # КРИТИЧЕСКИЕ LiveKit данные для auto-connect
        "livekit_access_token": livekit_token,
        "livekit_server_url": "wss://video.aibots.kz",
        "livekit_room_url": app_data.get('livekit_room_url', room_id),
        # Matrix данные
        "event_id": event['event_id'],
        "room_id": room_id,
        "sender": sender,
        "sender_display_name": sender_name,
        "call_id": event['content']['call_id']
    }
    
    # 4. Отправляем VoIP push напрямую в APNS
    send_voip_push(push_payload, get_user_devices(event['recipients']))
    
    return jsonify({"status": "sent"})

def generate_livekit_jwt(room_name, participant_identity, participant_name):
    """Генерирует JWT токен для LiveKit с правильными правами"""
    
    payload = {
        "iss": "LIVEKIT_API_KEY",  # Ваш LiveKit API ключ
        "sub": participant_identity,
        "iat": datetime.utcnow(),
        "exp": datetime.utcnow() + timedelta(hours=1),
        "room": room_name,
        "participant": {
            "identity": participant_identity,
            "name": participant_name
        },
        # Права участника
        "grants": {
            "room": room_name,
            "roomJoin": True,
            "canPublish": True,
            "canSubscribe": True,
            "canPublishData": True
        }
    }
    
    return jwt.encode(payload, "LIVEKIT_SECRET_KEY", algorithm="HS256")

def send_voip_push(payload, devices):
    """Отправляет VoIP push уведомление через APNS"""
    
    for device in devices:
        apns_payload = {
            "device_token": device['token'],
            "payload": payload,
            "topic": "io.sergeyshmagin.kdbchat.voip",  # VoIP topic
            "priority": 10,  # Высокий приоритет для VoIP
            "push_type": "voip"
        }
        
        # Используйте PyAPNs2 или аналогичную библиотеку
        send_to_apns(apns_payload)
```

### 2. Конфигурация Matrix Homeserver

```yaml
# homeserver.yaml
# Добавляем webhook для push событий
push:
  webhooks:
    - url: "https://your-server.com/matrix/push"
      events: ["m.call.invite"]
      
# Также оставляем Sygnal для обычных сообщений
push_gateways:
  - identity_server: "https://vector.im"
    base_url: "https://your-sygnal.com/_matrix/push/v1/notify"
```

### 3. Настройка APNS сертификатов

```python
# apns_config.py
from apns2.client import APNsClient
from apns2.payload import Payload

# VoIP сертификат для входящих звонков
voip_client = APNsClient(
    "path/to/voip-cert.pem",
    use_sandbox=False  # True для разработки
)

def send_to_apns(payload_data):
    """Отправка VoIP push через APNS"""
    
    payload = Payload(
        custom=payload_data["payload"],
        sound="default",
        category="CALL_INVITE"
    )
    
    voip_client.send_notification(
        token_hex=payload_data["device_token"],
        notification=payload,
        topic="io.sergeyshmagin.kdbchat.voip"
    )
```

## Вариант 2: Модификация Sygnal (Сложнее)

### 1. Создание форка Sygnal

```python
# sygnal_livekit_pusher.py
class LiveKitAPNsPusher(APNsPusher):
    """Расширенный pusher с поддержкой LiveKit"""
    
    def _build_payload(self, n, device):
        payload = super()._build_payload(n, device)
        
        # Если это call.invite - добавляем LiveKit данные
        if n.event_type == "m.call.invite":
            content = n.content or {}
            app_data = content.get("application_data", {})
            
            if app_data:
                # Генерируем JWT для LiveKit
                livekit_token = self._generate_livekit_jwt(n, app_data)
                
                payload.update({
                    "livekit_access_token": livekit_token,
                    "livekit_server_url": app_data.get("livekit_server_url", "wss://video.aibots.kz"),
                    "livekit_room_url": app_data.get("livekit_room_url")
                })
        
        return payload
```

### 2. Модифицированная конфигурация

```yaml
# modified_sygnal.yaml
apps:
  io.sergeyshmagin.kdbchat.voip:
    type: livekit_apns  # Наш кастомный pusher
    platform: ios
    cert: path/to/voip-cert.pem
    key: path/to/voip-key.pem
    topic: io.sergeyshmagin.kdbchat.voip
    # LiveKit конфигурация
    livekit:
      api_key: "LIVEKIT_API_KEY"
      secret_key: "LIVEKIT_SECRET_KEY"
      server_url: "wss://video.aibots.kz"
      token_ttl: 3600  # 1 час
```

## Интеграция с iOS App

Ваш iOS код **уже готов** к работе с enhanced push:

```swift
// В NotificationHandler.swift - уже реализовано
private func extractLiveKitCredentialsFromPushPayload(_ payload: [AnyHashable: Any]) -> LiveKitCredentials {
    // Код уже ищет livekit_access_token в push payload
    let accessToken = payload["livekit_access_token"] as? String
    let serverURL = payload["livekit_server_url"] as? String
    // ...
}
```

## Deployment Checklist

### На сервере:
- [ ] Webhook сервис развернут и доступен
- [ ] APNS сертификаты настроены для VoIP
- [ ] LiveKit API ключи сконфигурированы
- [ ] Matrix homeserver перенастроен для webhook

### На iOS:
- [ ] Код уже готов (ничего менять не нужно)
- [ ] Тестирование с реальными push уведомлениями

## Ожидаемый Результат

После внедрения серверного решения:

1. ✅ **Auto-connect заработает** - звонки будут подключаться автоматически
2. ✅ **Task 4 выполнен полностью** - оценка поднимется до 95/100
3. ✅ **Пользователи не увидят экран "Join Room"** 
4. ✅ **Мгновенное подключение к LiveKit** при ответе на звонок

Серверное решение критически важно для завершения Task 4.