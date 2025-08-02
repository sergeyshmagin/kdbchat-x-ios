# 🚀 НЕМЕДЛЕННЫЙ ПЛАН ДЕЙСТВИЙ

## Текущая ситуация:
- ✅ VoIP background mode включён в Info.plist
- ✅ VoIP entitlement НЕ требуется (проверено)
- ✅ Используются p8 сертификаты (не pem)
- ❌ Push notifications не доставляются

## КРИТИЧЕСКИЕ ДЕЙСТВИЯ:

### 1. Проверить на сервере (СРОЧНО!)

```bash
# Подключиться к серверу
ssh -i ~/.ssh/aibots_server aisha@95.58.199.128

# Запустить диагностику
bash < check_push_service.sh
```

**Что проверяем**:
- Формат VoIP push payload (должен содержать room_id, call_id)
- APNs headers для p8 (apns-topic, apns-push-type, apns-priority)
- Логи ошибок push service

### 2. Проверить регистрацию pushers в БД

```sql
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb

-- Смотрим все pushers
SELECT app_id, pushkey, kind, app_display_name, profile_tag, ts, data
FROM pushers 
WHERE user_name = '@ваш_юзер:aibots.kz'
ORDER BY ts DESC;

-- Проверяем что есть 2 записи:
-- 1. io.sergeyshmagin.kdbchat (обычные)
-- 2. io.sergeyshmagin.kdbchat.voip (VoIP)
```

### 3. Включить детальное логирование в приложении

1. Откройте приложение на РЕАЛЬНОМ устройстве (не симулятор!)
2. Settings → Developer Options → Log Level: **Trace**
3. Включите ВСЕ trace packs
4. Перезапустите приложение

### 4. Мониторинг логов в реальном времени

```bash
# На Mac с подключенным iPhone
xcrun devicectl device log stream --level debug | grep -E "(NotificationManager|VoIP|push|PKPush)" | tee voip_debug.log
```

**Что искать в логах**:
```
[NotificationManager] 📲 VoIP push token received: <токен>
[NotificationManager] 🚀 STARTING VoIP pusher registration...
[NotificationManager] ✅ VoIP pusher registration SUCCESSFUL!
```

### 5. Тестовый звонок

После всех проверок:
1. Позвоните с другого аккаунта
2. В логах должно появиться:
   ```
   [NotificationManager] 📥 Received VoIP push notification
   [NotificationManager] 📞 Processing VoIP call: Room=<room_id>
   ```

## 🔴 Если push не приходят:

### Проверка 1: Payload формат
Push service должен отправлять:
```json
{
  "aps": {
    "alert": "Incoming call",
    "sound": "default"
  },
  "room_id": "!xxxxx:aibots.kz",
  "call_id": "xxxxx",
  "caller_name": "User Name"
}
```

### Проверка 2: APNs Headers для p8
```
apns-topic: io.sergeyshmagin.kdbchat.voip
apns-push-type: voip
apns-priority: 10
```

### Проверка 3: App ID соответствие
- Клиент отправляет: `io.sergeyshmagin.kdbchat.voip`
- Сервер должен знать этот app_id

## 📊 Диагностика badge count = 2

Это отдельная проблема. Matrix считает КОМНАТЫ, не сообщения:
- 2 комнаты с непрочитанными = badge 2
- Даже если там 100 сообщений

**Временное решение**: Отключить badge
Settings → Hide unread messages badge

**Постоянное решение**: Изменить логику на сервере или в BadgeCountService

## ⏰ Следующие шаги (по приоритету):

1. **Сейчас**: Проверить сервер и формат push
2. **Через 30 мин**: Анализ логов с устройства  
3. **Через 1 час**: Если не работает - проверить p8 сертификат
4. **Завтра**: Исправить badge count