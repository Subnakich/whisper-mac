# Устройство приложения

Whisper Mac состоит из небольшого нативного SwiftUI-приложения и Python-пайплайна, который упаковывается в ресурсы `.app`. Управляемый Python runtime и модели устанавливаются по запросу в:

```text
~/Library/Application Support/WhisperMac
```

Пользовательская инструкция: [USAGE_RU.md](USAGE_RU.md).

Возможности:

- установка/обновление управляемого Python runtime;
- MLX Whisper с Metal;
- модели balanced, quality или произвольный MLX model ID/path;
- pyannote Community-1, выбор до 20 участников и локальное запоминание голосов;
- HF token в macOS Keychain;
- предварительная загрузка моделей в кэш;
- выбор языка, prompt и форматов;
- выбор входного файла и каталога результатов;
- пакетный выбор и drag-and-drop нескольких записей;
- просмотр и очистка кэша моделей.

## Каталоги

```text
app/Sources/      интерфейс и управление runtime
app/Resources/    иконка
cli/src/          распознавание, диаризация и экспорт
scripts/          сборка установщика и установка CLI
```

## Сборка `.pkg`

```bash
cd /Users/subnak/dev/whisper-mac
./scripts/build_pkg.sh
```

Результат:

```text
build/WhisperMac-0.3.1.pkg
```

Без переменных окружения пакет получает ad-hoc подпись для локального использования. Для распространения другим пользователям используйте Developer ID Application/Installer и нотариализацию по инструкции [SIGNING_RU.md](SIGNING_RU.md).

## Первый запуск

1. Установить `.pkg`.
2. Открыть `/Applications/Whisper Mac.app`.
3. Нажать «Подготовить приложение».
4. Ввести HF token и сохранить его в Keychain.
5. Выбрать модель и нажать «Загрузить выбранные модели» либо сразу начать обработку.
