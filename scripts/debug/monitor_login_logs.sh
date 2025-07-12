#!/bin/bash

# Скрипт для мониторинга логов в реальном времени при попытке входа
# Автор: AI Assistant
# Дата: $(date)

set -e

echo "🔍 Мониторинг логов ElementX в реальном времени"
echo "=============================================="
echo "Запустите приложение и попробуйте войти в систему"
echo "Этот скрипт будет отслеживать логи в реальном времени"
echo "Нажмите Ctrl+C для остановки"
echo ""

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

# Проверяем, что log утилита доступна
if ! command -v log &> /dev/null; then
    log_error "Утилита 'log' не найдена. Требуется macOS 10.15+"
    exit 1
fi

# Создаем временный файл для логов
TEMP_LOG_FILE=$(mktemp)
trap "rm -f $TEMP_LOG_FILE" EXIT

log_info "Начинаем мониторинг логов..."
echo ""

# Функция для мониторинга системных логов
monitor_system_logs() {
    log show --predicate 'process == "ElementX"' --last 1m --info 2>/dev/null | while read -r line; do
        # Фильтруем важные сообщения
        if echo "$line" | grep -q -E "(error|Error|ERROR|fail|Fail|FAIL|timeout|Timeout|TIMEOUT|login|Login|LOGIN|auth|Auth|AUTH|network|Network|NETWORK|server|Server|SERVER)"; then
            timestamp=$(date '+%H:%M:%S')
            echo "[$timestamp] $line"
        fi
    done
}

# Функция для мониторинга сетевых подключений
monitor_network() {
    while true; do
        # Проверяем подключения к matrix.aibots.kz
        if curl -s --connect-timeout 5 https://matrix.aibots.kz/.well-known/matrix/client > /dev/null; then
            echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} Сервер доступен"
        else
            echo -e "${RED}[$(date '+%H:%M:%S')]${NC} Сервер недоступен"
        fi
        sleep 10
    done
}

# Функция для анализа логов приложения
analyze_logs() {
    echo ""
    echo "📊 Анализ найденных ошибок:"
    echo "============================"
    
    # Ищем ошибки в системных логах
    local errors=$(log show --predicate 'process == "ElementX"' --last 10m 2>/dev/null | grep -E "(error|Error|ERROR|fail|Fail|FAIL)" | wc -l)
    echo "Найдено ошибок в системных логах: $errors"
    
    # Ищем таймауты
    local timeouts=$(log show --predicate 'process == "ElementX"' --last 10m 2>/dev/null | grep -E "(timeout|Timeout|TIMEOUT)" | wc -l)
    echo "Найдено таймаутов: $timeouts"
    
    # Ищем проблемы с сетью
    local network_issues=$(log show --predicate 'process == "ElementX"' --last 10m 2>/dev/null | grep -E "(network|Network|NETWORK|connection|Connection)" | wc -l)
    echo "Найдено сетевых проблем: $network_issues"
    
    echo ""
}

# Основной цикл мониторинга
echo "🚀 Запуск мониторинга..."
echo "Нажмите Ctrl+C для остановки"
echo ""

# Запускаем мониторинг в фоне
monitor_system_logs &
MONITOR_PID=$!

# Запускаем мониторинг сети в фоне
monitor_network &
NETWORK_PID=$!

# Ждем сигнала завершения
trap "kill $MONITOR_PID $NETWORK_PID 2>/dev/null; analyze_logs; exit" INT

# Основной цикл
while true; do
    sleep 1
done 