#!/bin/bash

echo "🔍 Проверка routing для push service"
echo "=================================="

ssh -i ~/.ssh/aibots_server aisha@95.58.199.128 << 'ENDSSH'

echo "1️⃣ Все ingress в кластере:"
kubectl get ingress -A

echo -e "\n2️⃣ Ingress для push в matrix-stack:"
kubectl get ingress -n matrix-stack -o yaml | grep -A10 -B5 push || echo "Push ingress не найден"

echo -e "\n3️⃣ Services в matrix-stack (детально):"
kubectl get services -n matrix-stack -o wide

echo -e "\n4️⃣ Endpoints для push service:"
kubectl get endpoints -n matrix-stack livekit-push-service

echo -e "\n5️⃣ NetworkPolicies:"
kubectl get networkpolicies -A | grep -E "(matrix|push)" || echo "Network policies не найдены"

echo -e "\n6️⃣ Проверка что push service отвечает внутри кластера:"
kubectl run test-curl --rm -i --tty --image=curlimages/curl -- curl -v -X POST http://livekit-push-service.matrix-stack.svc.cluster.local:5500/_matrix/push/v1/notify -H "Content-Type: application/json" -d '{"test": true}' || echo "Не удалось создать test pod"

echo -e "\n7️⃣ Логи nginx ingress controller:"
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --tail=50 | grep -E "(push|matrix)" | tail -10 || echo "Ingress controller логи не найдены"

echo -e "\n8️⃣ Тест доступности с внешней стороны:"
curl -v -X POST https://push.aibots.kz/_matrix/push/v1/notify -H "Content-Type: application/json" -d '{"test": true}' --connect-timeout 5 || echo "Внешний endpoint недоступен"

ENDSSH

echo "🏁 Проверка routing завершена!"