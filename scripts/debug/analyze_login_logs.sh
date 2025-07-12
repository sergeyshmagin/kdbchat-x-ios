#!/bin/bash

# Скрипт для анализа логов приложения при проблемах с входом
# Автор: AI Assistant
# Дата: $(date)

set -e

echo "🔍 Анализ логов приложения ElementX для диагностики проблем с входом"
echo "================================================================"

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

# Проверяем доступность сервера
log_info "Проверка доступности Matrix сервера..."
if curl -s --connect-timeout 10 https://matrix.aibots.kz/.well-known/matrix/client > /dev/null; then
    log_success "Сервер matrix.aibots.kz доступен"
else
    log_error "Сервер matrix.aibots.kz недоступен"
fi

# Ищем логи приложения
log_info "Поиск логов приложения..."

# Проверяем различные возможные места хранения логов
LOG_DIRS=(
    "$HOME/Library/Containers/io.element.elementx/Data/Library/Application Support"
    "$HOME/Library/Group Containers/group.io.element.elementx"
    "$HOME/Library/Application Support/ElementX"
    "/tmp"
)

FOUND_LOGS=false

for dir in "${LOG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        log_info "Проверяем директорию: $dir"
        if find "$dir" -name "*.log" -type f 2>/dev/null | grep -q .; then
            log_success "Найдены логи в: $dir"
            find "$dir" -name "*.log" -type f 2>/dev/null | while read -r log_file; do
                echo "  📄 $log_file"
            done
            FOUND_LOGS=true
        fi
    fi
done

if [ "$FOUND_LOGS" = false ]; then
    log_warn "Логи приложения не найдены в стандартных местах"
fi

# Анализируем системные логи
log_info "Анализ системных логов для ElementX..."

# Получаем последние логи ElementX
echo ""
echo "📋 Последние логи ElementX из системного журнала:"
echo "------------------------------------------------"

# Ищем логи за последний час
log show --predicate 'process == "ElementX"' --last 1h 2>/dev/null | grep -E "(error|Error|ERROR|fail|Fail|FAIL|timeout|Timeout|TIMEOUT|login|Login|LOGIN|auth|Auth|AUTH)" | head -20 || {
    log_warn "Не найдены системные логи для ElementX"
}

# Проверяем сетевые подключения
echo ""
log_info "Проверка сетевых подключений..."
echo "--------------------------------"

# Проверяем DNS
if nslookup matrix.aibots.kz > /dev/null 2>&1; then
    log_success "DNS резолвинг работает"
else
    log_error "Проблемы с DNS резолвингом"
fi

# Проверяем HTTPS подключение
if curl -s --connect-timeout 10 https://matrix.aibots.kz/.well-known/matrix/client > /dev/null; then
    log_success "HTTPS подключение к серверу работает"
else
    log_error "Проблемы с HTTPS подключением к серверу"
fi

# Анализ конфигурации приложения
echo ""
log_info "Анализ конфигурации приложения..."
echo "------------------------------------"

# Проверяем настройки приложения
if [ -f "$HOME/Library/Preferences/io.element.elementx.plist" ]; then
    log_info "Найдены настройки приложения"
    # Можно добавить анализ настроек если нужно
else
    log_warn "Файл настроек приложения не найден"
fi

# Рекомендации по диагностике
echo ""
echo "💡 Рекомендации по диагностике:"
echo "================================"

echo "1. Включите подробное логирование в приложении:"
echo "   - Откройте приложение"
echo "   - Перейдите в Settings -> Developer Options"
echo "   - Установите Log Level в 'Debug' или 'Trace'"
echo "   - Включите нужные trace packs"

echo ""
echo "2. Проверьте сетевые настройки:"
echo "   - Убедитесь, что нет блокировки файрвола"
echo "   - Проверьте VPN настройки"
echo "   - Убедитесь, что DNS работает корректно"

echo ""
echo "3. Попробуйте альтернативные серверы:"
echo "   - matrix.org"
echo "   - vector.im"

echo ""
echo "4. Для получения подробных логов:"
echo "   - Запустите приложение из Xcode"
echo "   - Смотрите консоль Xcode во время попытки входа"
echo "   - Ищите ошибки связанные с:"
echo "     * Network connectivity"
echo "     * Authentication"
echo "     * Server configuration"
echo "     * Timeout errors"

echo ""
echo "5. Проверьте сервер matrix.aibots.kz:"
echo "   - Статус: https://matrix.aibots.kz/_matrix/client/versions"
echo "   - Well-known: https://matrix.aibots.kz/.well-known/matrix/client"

echo ""
log_info "Анализ завершен. Проверьте рекомендации выше для дальнейшей диагностики." 