# Whisper Mac `.pkg`

Нативное SwiftUI-приложение для Apple Silicon. Сам `.pkg` содержит только приложение и код пайплайна. Runtime и модели устанавливаются по запросу в:

```text
~/Library/Application Support/WhisperMac
```

Подробная пользовательская инструкция: [USAGE_RU.md](USAGE_RU.md).

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

## Сборка

```bash
cd /Users/subnak/dev/whisper-gui/mac-app
chmod +x build_pkg.sh
./build_pkg.sh
```

Результат:

```text
mac-app/build/WhisperMac-0.3.1.pkg
```

Без переменных окружения пакет получает ad-hoc подпись для локального использования. Для распространения другим пользователям используйте Developer ID Application/Installer и нотариализацию по инструкции [SIGNING_RU.md](SIGNING_RU.md).

## Первый запуск

1. Установить `.pkg`.
2. Открыть `/Applications/Whisper Mac.app`.
3. Нажать «Установить / обновить runtime».
4. Ввести HF token и сохранить его в Keychain.
5. Выбрать модель и нажать «Загрузить выбранные модели» либо сразу начать обработку.
