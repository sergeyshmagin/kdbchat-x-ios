#!/bin/bash

echo "=== Проверка исправления VoIP pusher регистрации ==="

# Выводим изменения в коде
echo "✅ Изменения в NotificationManager.swift:"
echo "Строка 559: Добавлен .voip суффикс к app ID"
grep -n "voipAppId.*\.voip" "ElementX/Sources/Services/Notification/Manager/NotificationManager.swift" || echo "❌ Не найдены изменения"

echo ""
echo "📋 Команды для проверки на сервере:"
echo "1. SSH к серверу:"
echo "   ssh -i ~/.ssh/aibots_server aisha@95.58.199.128"
echo ""
echo "2. Проверить БД Synapse (найти VoIP pusher для testuser1):"
echo '   psql -h 192.168.0.4 -U synapse_user -d synapse -c "SELECT user_name, app_id, pushkey, data FROM pushers WHERE user_name LIKE '\''%testuser1%'\'' ORDER BY user_name, app_id;"'
echo ""
echo "3. Проверить логи push сервиса:"
echo "   kubectl logs -f deployment/livekit-push-service | grep VoIP"
echo ""
echo "🔧 После установки обновленного приложения на устройство:"
echo "   - VoIP pusher должен зарегистрироваться с app_id: io.sergeyshmagin.kdbchat.voip"
echo "   - Сервер должен использовать VoIP токен для VoIP push уведомлений"
echo "   - CallKit должен активироваться при входящих звонках"