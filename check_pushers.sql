-- Скрипт для проверки pushers в базе данных Matrix
-- Запускать: PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb -f check_pushers.sql

\echo '========================================'
\echo '📱 ПРОВЕРКА PUSH NOTIFICATIONS'
\echo '========================================'
\echo ''

-- 1. Все pushers для всех пользователей
\echo '1️⃣ Все активные pushers:'
SELECT 
    user_name,
    app_id,
    pushkey,
    kind,
    app_display_name,
    device_display_name,
    profile_tag,
    ts,
    data
FROM pushers
ORDER BY ts DESC
LIMIT 20;

\echo ''
\echo '2️⃣ Статистика по app_id:'
SELECT 
    app_id,
    COUNT(*) as count,
    COUNT(DISTINCT user_name) as unique_users,
    MAX(ts) as last_registered
FROM pushers
GROUP BY app_id
ORDER BY count DESC;

\echo ''
\echo '3️⃣ VoIP pushers (должны быть с .voip):'
SELECT 
    user_name,
    app_id,
    LEFT(pushkey, 20) || '...' as pushkey_prefix,
    device_display_name,
    ts
FROM pushers
WHERE app_id LIKE '%voip%'
ORDER BY ts DESC;

\echo ''
\echo '4️⃣ Последние регистрации (24 часа):'
SELECT 
    user_name,
    app_id,
    device_display_name,
    ts,
    AGE(NOW(), TO_TIMESTAMP(ts/1000)) as age
FROM pushers
WHERE ts > (EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours') * 1000)
ORDER BY ts DESC;

\echo ''
\echo '5️⃣ Дубликаты pushers (потенциальная проблема):'
SELECT 
    user_name,
    app_id,
    COUNT(*) as duplicate_count
FROM pushers
GROUP BY user_name, app_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

\echo ''
\echo '6️⃣ Проверка конкретного пользователя:'
\echo 'Замените @user:aibots.kz на вашего пользователя'
\echo ''
-- SELECT * FROM pushers WHERE user_name = '@user:aibots.kz';

\echo ''
\echo '📊 ИТОГИ:'
\echo '- Должно быть 2 pusher на пользователя (обычный + VoIP)'
\echo '- VoIP должен иметь app_id с .voip'
\echo '- Проверьте что pushkey не пустой'
\echo '- ts должен быть недавним (в миллисекундах)'