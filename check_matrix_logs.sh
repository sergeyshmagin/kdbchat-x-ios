#!/bin/bash

echo "📊 Проверка Matrix Synapse push логов"
echo "====================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Логи Matrix Synapse (push события):"
kubectl logs -n matrix deployment/matrix-synapse --tail=1000 | grep -E "(push|testuser2)" | tail -20

echo -e "\n2️⃣ Ошибки в Matrix Synapse:"
kubectl logs -n matrix deployment/matrix-synapse --tail=500 | grep -E "(ERROR|WARN)" | tail -10

echo -e "\n3️⃣ Проверяем что Matrix знает о push gateway:"
kubectl logs -n matrix deployment/matrix-synapse --tail=1000 | grep -E "(push.*gateway|gateway.*push)" | tail -5

echo -e "\n4️⃣ События для пользователя testuser2:"
kubectl logs -n matrix deployment/matrix-synapse --tail=2000 | grep "testuser2" | tail -15

echo -e "\n5️⃣ Push events за последний час:"
kubectl logs -n matrix deployment/matrix-synapse --since=1h | grep -E "push.*notify|notify.*push" | tail -10

echo -e "\n6️⃣ Конфигурация Matrix push в homeserver.yaml:"
kubectl get configmap -n matrix matrix-synapse-config -o yaml | grep -A20 -B5 push || echo "Push конфигурация не найдена в configmap"

ENDSSH

echo "🏁 Проверка Matrix Synapse завершена!"