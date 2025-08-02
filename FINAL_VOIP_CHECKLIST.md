# ✅ ФИНАЛЬНЫЙ ЧЕКЛИСТ VoIP Push Notifications

## 🟢 Что уже правильно настроено:

1. ✅ VoIP background mode включён в Info.plist
2. ✅ LiveKit включён через флаг компиляции `-DLIVEKIT_ENABLED`
3. ✅ PKPushRegistry настроен в NotificationManager
4. ✅ CallKit интеграция реализована в LiveKitCallKitService
5. ✅ Обработка VoIP push в AppCoordinator

## 🔴 Что нужно проверить на сервере:

### 1. Формат VoIP Push Payload

Ваш push service ДОЛЖЕН отправлять в таком формате:
```json
{
  "aps": {
    "content-available": 1,
    "alert": {
      "title": "Incoming call",
      "body": "Call from User Name"
    }
  },
  "room_id": "!xxxxx:aibots.kz",    // ИЛИ "roomId"
  "call_id": "xxxxx",                // ИЛИ "event_id"
  "caller_name": "User Name",        // ИЛИ "sender_display_name"
  "has_video": true                  // ИЛИ "video"
}
```

### 2. HTTP Headers для p8 сертификата

При отправке VoIP push ОБЯЗАТЕЛЬНЫ headers:
```
apns-topic: io.sergeyshmagin.kdbchat.voip
apns-push-type: voip
apns-priority: 10
apns-expiration: 0
```

### 3. Проверка Flask push service

```python
# Пример правильной отправки VoIP push с p8
import jwt
import httpx
from datetime import datetime, timedelta

def send_voip_push(device_token, room_id, call_id, caller_name):
    # JWT для p8 аутентификации
    auth_jwt = jwt.encode({
        "iss": "YOUR_TEAM_ID",
        "iat": datetime.utcnow()
    }, YOUR_P8_KEY, algorithm="ES256", headers={
        "alg": "ES256",
        "kid": "YOUR_KEY_ID"
    })
    
    # Payload
    payload = {
        "aps": {"content-available": 1},
        "room_id": room_id,
        "call_id": call_id,
        "caller_name": caller_name,
        "has_video": True
    }
    
    # Headers
    headers = {
        "authorization": f"bearer {auth_jwt}",
        "apns-topic": "io.sergeyshmagin.kdbchat.voip",
        "apns-push-type": "voip",
        "apns-priority": "10",
        "apns-expiration": "0"
    }
    
    # Отправка
    response = httpx.post(
        f"https://api.push.apple.com/3/device/{device_token}",
        json=payload,
        headers=headers
    )
    
    return response.status_code == 200
```

## 📱 Тестирование на устройстве:

### 1. Добавьте тестовую кнопку в Developer Options:

```swift
// В DeveloperOptionsScreen добавьте:
NavigationLink("VoIP Push Test") {
    VoIPTestView() // Код из test_voip_locally.swift
}
```

### 2. Логирование в реальном времени:

```bash
# Terminal 1: Device logs
xcrun devicectl device log stream --level debug --process ElementX | grep -E "(VoIP|push|PKPush|NotificationManager)"

# Terminal 2: Console.app
# Откройте Console.app, выберите устройство, фильтр: "VoIP OR push"
```

### 3. Что должно быть в логах при успехе:

```
1. При запуске приложения:
   [NotificationManager] 📲 VoIP push token received: <token>
   [NotificationManager] ✅ VoIP pusher registration SUCCESSFUL!

2. При входящем звонке:
   [NotificationManager] 📥 Received VoIP push notification
   [NotificationManager] 📞 Processing VoIP call: Room=xxx, Caller=xxx
   [AppCoordinator] 📞 Handling VoIP push: Room=xxx
   [LiveKitCallKitService] Reporting incoming call: xxx
```

## 🚨 Частые проблемы:

### Проблема 1: "No VoIP token received"
- Проверьте что приложение запущено на РЕАЛЬНОМ устройстве
- Проверьте Provisioning Profile (должен поддерживать push)

### Проблема 2: "VoIP pusher registration failed"
- Проверьте app_id на сервере (io.sergeyshmagin.kdbchat.voip)
- Проверьте доступность push.aibots.kz

### Проблема 3: "Invalid VoIP push payload"
- room_id отсутствует в payload
- Проверьте формат JSON от сервера

### Проблема 4: Badge = 2
- Matrix считает комнаты, не сообщения
- Временно: Settings → Hide unread messages badge

## 🎯 Итоговые действия:

1. **На сервере**: Проверить формат payload и headers
2. **В приложении**: Добавить VoIP тест в Developer Options
3. **Тестирование**: Сделать звонок и проверить логи
4. **Мониторинг**: Следить за логами push service

## 📊 Метрики успеха:

✅ VoIP token регистрируется при запуске
✅ Pusher появляется в БД Matrix
✅ Входящий звонок будит приложение
✅ CallKit показывает UI звонка
✅ Звонок подключается через LiveKit