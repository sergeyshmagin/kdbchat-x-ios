#!/bin/bash

# Скрипт для детального анализа ошибки failedLoggingIn
# Автор: AI Assistant
# Дата: $(date)

set -e

echo "🔍 Детальный анализ ошибки failedLoggingIn"
echo "=========================================="

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для логирования
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo ""
log_info "Анализ ошибки failedLoggingIn в ElementX"
echo ""

# Анализ возможных причин ошибки failedLoggingIn
echo "📋 Возможные причины ошибки failedLoggingIn:"
echo "============================================="

echo "1. Client is nil - клиент не инициализирован"
echo "2. Matrix API ошибки - проблемы с сервером"
echo "3. Ошибки создания пользовательской сессии"
echo "4. Сетевые проблемы"
echo "5. Проблемы с sliding sync"
echo "6. Неправильная конфигурация сервера"
echo ""

# Проверка сервера
log_info "Проверка сервера matrix.aibots.kz..."

echo "🔍 Проверка well-known файла:"
if curl -s https://matrix.aibots.kz/.well-known/matrix/client | jq . 2>/dev/null; then
    log_success "Well-known файл корректный"
else
    log_error "Проблемы с well-known файлом"
fi

echo ""
echo "🔍 Проверка API версий:"
if curl -s https://matrix.aibots.kz/_matrix/client/versions | jq . 2>/dev/null; then
    log_success "API версии доступны"
else
    log_error "Проблемы с API версиями"
fi

echo ""
echo "🔍 Проверка sliding sync:"
if curl -s https://matrix.aibots.kz/_matrix/client/r0/sync | head -c 100; then
    log_success "Синхронизация доступна"
else
    log_error "Проблемы с синхронизацией"
fi

# Анализ логов
echo ""
log_info "Анализ системных логов для failedLoggingIn..."

echo "📋 Поиск ошибок failedLoggingIn в логах:"
log show --predicate 'process == "ElementX"' --last 1h 2>/dev/null | grep -i "failedLoggingIn\|failed.*login\|login.*failed" | head -10 || {
    log_warn "Не найдены логи с ошибками failedLoggingIn"
}

echo ""
echo "📋 Поиск ошибок Matrix API:"
log show --predicate 'process == "ElementX"' --last 1h 2>/dev/null | grep -i "matrix.*api\|client.*error\|forbidden\|userDeactivated" | head -10 || {
    log_warn "Не найдены логи с ошибками Matrix API"
}

echo ""
echo "📋 Поиск сетевых ошибок:"
log show --predicate 'process == "ElementX"' --last 1h 2>/dev/null | grep -i "network\|connection\|timeout\|dns" | head -10 || {
    log_warn "Не найдены сетевые ошибки"
}

# Рекомендации по диагностике
echo ""
echo "💡 Рекомендации по диагностике failedLoggingIn:"
echo "=============================================="

echo "1. Включите подробное логирование:"
echo "   - Откройте приложение ElementX"
echo "   - Settings → Developer Options"
echo "   - Log Level: Trace"
echo "   - Включите все trace packs"

echo ""
echo "2. Запустите приложение из Xcode:"
echo "   - Откройте проект в Xcode"
echo "   - Запустите в режиме отладки"
echo "   - Попробуйте войти"
echo "   - Смотрите консоль Xcode"

echo ""
echo "3. Проверьте конкретные ошибки в коде:"
echo "   - AuthenticationService.swift:130-200"
echo "   - LoginScreenViewModel.swift:250-300"
echo "   - Ищите логи с 'client is nil'"
echo "   - Ищите логи с 'Matrix API error'"

echo ""
echo "4. Тестирование с альтернативными серверами:"
echo "   - matrix.org"
echo "   - vector.im"
echo "   - Проверьте, работает ли вход на других серверах"

echo ""
echo "5. Проверка сетевых настроек:"
echo "   - Отключите VPN если используется"
echo "   - Проверьте файрвол"
echo "   - Попробуйте другое сетевое подключение"

# Заключение
echo ""
echo "📊 Заключение по анализу failedLoggingIn:"
echo "========================================"

echo "Ошибка failedLoggingIn может возникать по следующим причинам:"
echo ""
echo "🔴 Критические причины:"
echo "  - Client не инициализирован (client is nil)"
echo "  - Проблемы с Matrix API (forbidden, userDeactivated)"
echo "  - Ошибки создания пользовательской сессии"
echo ""
echo "🟡 Возможные причины:"
echo "  - Сетевые проблемы (таймауты, DNS)"
echo "  - Проблемы с sliding sync"
echo "  - Неправильная конфигурация сервера"
echo "  - Проблемы с OIDC"
echo ""
echo "🟢 Рекомендации:"
echo "  - Включите подробное логирование в приложении"
echo "  - Запустите из Xcode для получения детальных логов"
echo "  - Попробуйте альтернативный сервер"

echo ""
log_info "Анализ завершен. Используйте созданные инструменты для дальнейшей диагностики." 