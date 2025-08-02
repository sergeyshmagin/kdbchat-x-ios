#!/bin/bash

echo "🔧 Исправление URLs pushers"
echo "========================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Все pushers с их URLs:"
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb << ENDSQL

-- Проверяем все pushers и их data (содержит URL)
SELECT 
    u.name as user_name,
    p.app_id,
    left(p.pushkey, 20) || '...' as pushkey_prefix,
    p.data::json->>'url' as push_url,
    to_timestamp(p.ts/1000) as last_updated
FROM pushers p
JOIN users u ON p.user_name = u.name
WHERE u.name = '@testuser2:matrix.aibots.kz'
ORDER BY p.ts DESC;

ENDSQL

echo -e "\n2️⃣ УДАЛЯЕМ старые pushers с неправильными URLs:"
PGPASSWORD="matrix_secure_pass" psql -h 192.168.0.4 -U matrix_user -d matrixdb << ENDSQL

-- Удаляем pushers с неправильными URLs
DELETE FROM pushers 
WHERE user_name = '@testuser2:matrix.aibots.kz'
  AND (data::json->>'url' LIKE '%push-prod.kdbchat.io%' 
       OR data::json->>'url' LIKE '%kdbchat.io%'
       OR app_id LIKE '%.ios%');

-- Проверяем что осталось
SELECT 
    u.name as user_name,
    p.app_id,
    left(p.pushkey, 20) || '...' as pushkey_prefix,
    p.data::json->>'url' as push_url,
    to_timestamp(p.ts/1000) as last_updated
FROM pushers p
JOIN users u ON p.user_name = u.name
WHERE u.name = '@testuser2:matrix.aibots.kz'
ORDER BY p.ts DESC;

ENDSQL

echo -e "\n3️⃣ Перезапускаем pushers в Matrix Synapse:"
kubectl rollout restart deployment/matrix-synapse -n matrix

echo -e "\n4️⃣ Ждём перезапуска Matrix Synapse..."
kubectl wait --for=condition=ready pod -l app=matrix-synapse -n matrix --timeout=60s

ENDSSH

echo "🏁 Исправление URLs завершено!"
echo "📱 Теперь переизопустите приложение iOS для перерегистрации pushers с правильным URL!"