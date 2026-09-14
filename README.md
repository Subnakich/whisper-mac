# Whisper Mac

Локальное приложение для расшифровки аудио на Mac с Apple Silicon. Использует MLX Whisper для распознавания речи и pyannote Community-1 для разделения участников по голосам.

Проект состоит из нативного SwiftUI-интерфейса в `mac-app` и Python-пайплайна в `mac-cli`.

## Возможности

- локальная расшифровка без облачного ASR;
- ускорение Apple Metal;
- диаризация и экспорт TXT, Markdown, JSON, SRT и VTT;
- загрузка моделей по требованию;
- хранение Hugging Face token в macOS Keychain;
- локальные профили знакомых голосов.

## Быстрая сборка

```bash
cd mac-app
./build_pkg.sh
```

Подробности находятся в [инструкции приложения](mac-app/USAGE_RU.md).

