# 📱 Руководство по тестированию LiveKit интеграции

## 🚀 Быстрый старт

### 1. Сборка и установка
```bash
# Сборка для симулятора
xcodebuild -project ElementX.xcodeproj -scheme ElementX -configuration Debug \
           -sdk iphonesimulator -destination "platform=iOS Simulator,name=iPhone 16 Pro Max" \
           build -allowProvisioningUpdates CODE_SIGNING_ALLOWED=NO

# Установка на симулятор
xcrun simctl install F0084A84-2CB7-4C36-906A-29516615D958 \
      "/Users/sergeysh/Library/Developer/Xcode/DerivedData/ElementX-*/Build/Products/Debug-iphonesimulator/ElementX.app"

# Запуск приложения
xcrun simctl launch F0084A84-2CB7-4C36-906A-29516615D958 io.element.elementx
```

### 2. Тестирование звонков

#### Шаги:
1. **Войти в приложение** с учетными данными Matrix
2. **Перейти в комнату** с другими участниками
3. **Нажать кнопку видеозвонка** 📹
4. **Наблюдать логи** в Console.app или Xcode

#### Ожидаемое поведение:
- ✅ Запрос разрешений на камеру/микрофон
- ✅ Получение OpenID токена от Matrix
- ✅ Получение JWT токена от auth сервера
- ⚠️ **Timeout при подключении к LiveKit** (на симуляторе)

---

## 🔍 Мониторинг логов

### Xcode Console:
```bash
# Фильтр для LiveKit логов
grep -i "livekit\|auth\|call"
```

### Ключевые логи для отслеживания:
```
✅ Testing LiveKit authentication server connectivity...
✅ Auth server reachability test result: ✅ Connected
✅ Media permissions - Camera: true, Microphone: true
✅ Successfully obtained OpenID token from Matrix homeserver
✅ LiveKit auth successful for room: !roomId
❌ Failed to start LiveKit call: Error Domain=io.livekit.swift-sdk Code=101 "Timed out"
```

---

## 🐛 Известные проблемы

### 1. Connection Timeout на симуляторе
**Проблема**: `LiveKit SDK Code=101 "Timed out"`
**Причина**: AudioSession ошибки на симуляторе
**Решение**: Тестирование на реальном устройстве

### 2. AudioSession errors
**Проблема**: `AudioSessionGetProperty failed with error: -50`
**Причина**: Симулятор не имеет реального аудио оборудования
**Решение**: Ожидаемое поведение на симуляторе

---

## 📱 Тестирование на реальном устройстве

### Подготовка:
1. **Подключить iPhone** через USB
2. **Настроить Developer профиль** в Xcode
3. **Включить Developer Mode** на устройстве

### Сборка для устройства:
```bash
# Узнать имя устройства
xcrun xctrace list devices

# Сборка для устройства
xcodebuild -project ElementX.xcodeproj -scheme ElementX -configuration Debug \
           -destination "platform=iOS,name=Your iPhone Name" \
           build -allowProvisioningUpdates
```

### Ожидаемые результаты:
- ✅ Успешное подключение к LiveKit
- ✅ Установка audio/video соединения
- ✅ Работающие медиа треки

---

## 📊 Что проверить

### ✅ Функциональность auth:
- [ ] Matrix OpenID токен получается
- [ ] Auth сервер доступен
- [ ] JWT токен валидный

### ✅ Permissions:
- [ ] Camera permission запрашивается
- [ ] Microphone permission запрашивается  
- [ ] Permissions предоставляются

### ✅ UI/UX:
- [ ] LiveKitCallScreen загружается
- [ ] Loading индикаторы показываются
- [ ] Error состояния отображаются
- [ ] Retry кнопка работает

### ⏳ LiveKit connection:
- [ ] Подключение к signaling серверу
- [ ] Установка WebRTC соединения
- [ ] Audio/Video треки активны

---

## 🔧 Troubleshooting

### Если auth не работает:
1. Проверить доступность `https://livekit-auth.aibots.kz/api/auth`
2. Проверить Matrix OpenID поддержку на homeserver
3. Проверить логи auth сервера

### Если connection timeout:
1. Протестировать на реальном устройстве
2. Проверить firewall/network настройки
3. Попробовать другие STUN серверы

### Если UI не работает:
1. Проверить navigation coordinator
2. Проверить SwiftUI view bindings
3. Проверить @Published properties

---

## 📈 Следующие этапы

После решения connection timeout:

1. **Phase 3: CallKit интеграция**
   - Incoming call поддержка
   - Background call handling
   - System call UI

2. **Phase 4: UI/UX полировка**
   - Proper VideoView реализация
   - Screen sharing
   - Picture-in-Picture

3. **Phase 5: Production готовность**
   - Unit тесты
   - Performance оптимизация
   - Error handling улучшения

---

*Обновлено: 15 июля 2025*