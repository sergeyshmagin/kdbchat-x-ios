# Исправление предупреждений dSYM

## Проблема
При публикации в App Store появляются предупреждения:
- LiveKitWebRTC.framework - отсутствует dSYM  
- Sentry.framework - отсутствует dSYM
- YbridOgg.framework - отсутствует dSYM
- YbridOpus.framework - отсутствует dSYM

## Решения

### Вариант 1: Отключить загрузку символов для внешних библиотек

В Xcode → Project Settings → Build Settings → Release:

1. **Strip Debug Symbols During Copy** = YES
2. **Debug Information Format** = DWARF with dSYM File  
3. **Strip Style** = Non-Global Symbols

### Вариант 2: Исключить проблемные фреймворки из загрузки символов

Добавить в Build Settings → Other Linker Flags:
```
-Wl,-S -Wl,-x
```

### Вариант 3: Создать символы для внешних библиотек (рекомендуется)

Запустить скрипт:
```bash
./scripts/copy_dsym.sh
```

## Результат
После применения любого из решений предупреждения исчезнут, но качество crash reporting может снизиться для внешних библиотек.

## Рекомендация
Использовать **Вариант 1** - это стандартная практика для внешних библиотек.