# План Приведения VoIP Push в Соответствие с Требованиями Apple

**Дата создания:** 05.08.2025  
**Статус:** КРИТИЧНО - Требует исправления перед App Store Review  
**Цель:** 100% соответствие Apple VoIP Push Guidelines

## 🚨 КРИТИЧЕСКИЕ ПРОБЛЕМЫ (БЛОКИРУЮТ APP STORE REVIEW)

### 1. Неправильное использование VoIP Push
**Местоположение:** `NotificationManager.swift:75-76`
```swift
// VoIP Push через обычные push уведомления (без специального entitlement)
// PKPushRegistry не используем - будем получать VoIP через обычный token с .voip topic
```

**❌ ПРОБЛЕМА:** Попытка использовать обычные push с VoIP topic вместо PKPushRegistry
**✅ РЕШЕНИЕ:** Полностью перейти на PKPushRegistry для VoIP звонков

### 2. ~~Отсутствующие VoIP Entitlements~~ ✅ НЕ ТРЕБУЕТСЯ
**Местоположение:** `ElementX.entitlements`
**✅ СТАТУС:** Специальные VoIP entitlements не нужны для обычных разработчиков
**📝 ПРИМЕЧАНИЕ:** `com.apple.developer.pushkit.unrestricted-voip` доступен только Apple для специальных случаев (Push-To-Talk)

## 🟡 СРЕДНИЕ ПРИОРИТЕТЫ

### 3. Дедупликация звонков
**❌ ПРОБЛЕМА:** Возможность повторной обработки одного звонка
**✅ РЕШЕНИЕ:** Реализовать проверку уникальности call_id

### 4. Валидация VoIP Payload
**❌ ПРОБЛЕМА:** Отсутствие строгой проверки содержимого VoIP push
**✅ РЕШЕНИЕ:** Добавить валидацию обязательных полей

## 📋 ПЛАН ИСПРАВЛЕНИЙ

### ЭТАП 1: КРИТИЧЕСКИЕ ИСПРАВЛЕНИЯ (1-2 дня)

#### 1.1. Исправить VoIP Push Implementation
```swift
// Удалить из NotificationManager.swift:75-76
// ❌ Убрать: PKPushRegistry не используем - будем получать VoIP через обычный token

// ✅ Оставить только PKPushRegistry для VoIP
func configureVoIPPush() {
    pushRegistry = PKPushRegistry(queue: nil)
    pushRegistry?.delegate = self
    pushRegistry?.desiredPushTypes = [.voIP] // ТОЛЬКО VoIP pushes
}
```

#### 1.2. ~~Добавить VoIP Entitlements~~ ✅ НЕ ТРЕБУЕТСЯ
**Статус:** Специальные VoIP entitlements не нужны для стандартных VoIP приложений
**Важно:** Только Background Mode `voip` в Info.plist требуется (уже настроен)

**Доступные entitlements для обычных разработчиков:**
```xml
<!-- Только если нужны deep links -->
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:aibots.kz</string>
</array>
```

#### 1.3. Очистить смешанный подход
**Удалить весь код, связанный с обычными push для звонков:**
- Убрать регистрацию обычного токена для VoIP
- Оставить PKPushRegistry как единственный источник VoIP

### ЭТАП 2: СРЕДНИЕ ПРИОРИТЕТЫ (2-3 дня)

#### 2.1. Реализовать дедупликацию звонков
```swift
class VoIPCallManager {
    private var processedCalls = Set<String>()
    
    func processVoIPCall(callId: String, roomId: String) -> Bool {
        guard !processedCalls.contains(callId) else {
            MXLog.warning("Duplicate VoIP call ignored: \(callId)")
            return false // Предотвращаем дублирование
        }
        
        processedCalls.insert(callId)
        
        // Очистка старых call IDs (через 5 минут)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            processedCalls.remove(callId)
        }
        
        return true
    }
}
```

#### 2.2. Добавить валидацию VoIP Payload
```swift
func validateVoIPPayload(_ payload: [AnyHashable: Any]) -> VoIPValidationResult {
    // Обязательные поля для звонка
    guard let roomId = payload["room_id"] as? String, !roomId.isEmpty,
          let callId = payload["call_id"] as? String, !callId.isEmpty,
          let eventType = payload["event_type"] as? String, 
          eventType == "m.call.invite" else {
        return .invalid("Missing required call fields")
    }
    
    // Дополнительная проверка - это действительно звонок?
    let hasCallerInfo = payload["sender_display_name"] is String
    let hasCallContent = payload["content"] is [String: Any]
    
    guard hasCallerInfo || hasCallContent else {
        return .invalid("Invalid call structure")
    }
    
    return .valid
}

enum VoIPValidationResult {
    case valid
    case invalid(String)
}
```

#### 2.3. Улучшить CallKit интеграцию
```swift
// Убедиться, что все звонки попадают в Recents
func configureCallKitProvider() {
    let configuration = CXProviderConfiguration(localizedName: "kdbchat")
    configuration.supportsVideo = true
    configuration.includesCallsInRecents = true // ✅ КРИТИЧНО для App Store
    configuration.maximumCallsPerCallGroup = 1
    
    // Обязательно устанавливаем иконку
    if let iconImage = UIImage(named: "AppIcon") {
        configuration.iconTemplateImageData = iconImage.pngData()
    }
    
    provider = CXProvider(configuration: configuration)
}
```

### ЭТАП 3: ТЕСТИРОВАНИЕ И ВАЛИДАЦИЯ (1-2 дня)

#### 3.1. Тестовые сценарии
1. **Приложение убито** → VoIP push → CallKit активируется
2. **Приложение в фоне** → VoIP push → CallKit активируется
3. **Быстрая отмена звонка** → Один VoIP push, отмена через сигналинг
4. **DND режим** → CallKit соблюдает настройки
5. **Звонки в Recents** → Все звонки видны в системном журнале

#### 3.2. Compliance проверки
```swift
class VoIPComplianceChecker {
    func runComplianceCheck() -> ComplianceReport {
        var issues: [String] = []
        
        // 1. Проверка PKPushRegistry
        if pushRegistry == nil {
            issues.append("PKPushRegistry not configured")
        }
        
        // 2. Проверка CallKit
        if provider == nil {
            issues.append("CXProvider not configured")
        }
        
        // 3. Проверка entitlements
        let entitlements = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.pushkit.unrestricted-voip")
        if entitlements == nil {
            issues.append("VoIP entitlement missing")
        }
        
        // 4. Проверка background mode
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        if !(backgroundModes?.contains("voip") ?? false) {
            issues.append("VoIP background mode missing")
        }
        
        return ComplianceReport(issues: issues)
    }
}
```

## 🎯 КРИТЕРИИ УСПЕХА

### Технические требования:
- ✅ PKPushRegistry используется исключительно для VoIP
- ✅ CallKit активируется немедленно при VoIP push
- ✅ Один VoIP push на звонок (no duplicates)
- ✅ Все звонки логируются в системные Recents
- ✅ Background Mode `voip` настроен (уже есть)

### App Store Review требования:
- ✅ Реальная VoIP функциональность (LiveKit)
- ✅ Соблюдение DND и системных настроек
- ✅ Корректный UX для входящих звонков
- ✅ Нет использования VoIP для не-звонковых целей

## 🚀 ПОРЯДОК ВНЕДРЕНИЯ

### День 1:
1. Исправить VoIP push implementation в NotificationManager
2. ~~Добавить VoIP entitlements~~ (не требуется для обычных разработчиков)
3. Очистить смешанный подход

### День 2:
1. Реализовать дедупликацию звонков
2. Добавить валидацию VoIP payload  
3. Провести базовое тестирование

### День 3:
1. Комплексное тестирование всех сценариев
2. Проверка compliance
3. Подготовка к App Store Review

## 📚 ССЫЛКИ НА ДОКУМЕНТАЦИЮ APPLE

1. [VoIP Best Practices](https://developer.apple.com/documentation/pushkit/responding_to_voip_notifications_from_pushkit)
2. [CallKit Integration](https://developer.apple.com/documentation/callkit)
3. [App Store Review Guidelines - VoIP](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
4. [PushKit Framework Reference](https://developer.apple.com/documentation/pushkit)

## ⚠️ ВАЖНЫЕ ЗАМЕЧАНИЯ

1. **НЕ ОТПРАВЛЯТЬ** несколько VoIP push для одного звонка
2. **НЕ ИСПОЛЬЗОВАТЬ** VoIP push для сообщений/данных
3. **ВСЕГДА ВЫЗЫВАТЬ** CallKit немедленно после VoIP push
4. **ОБЯЗАТЕЛЬНО ТЕСТИРОВАТЬ** на убитом приложении
5. **ДОБАВИТЬ ПОДРОБНЫЕ ИНСТРУКЦИИ** для App Store Review

---

**Статус:** 🔴 ТРЕБУЕТ НЕМЕДЛЕННОГО ВНИМАНИЯ  
**Дедлайн:** До следующей отправки в App Store Review  
**Ответственный:** Development Team  
**Проверка:** QA + Compliance Review