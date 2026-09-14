# whisper-mac runtime

Python-пайплайн, который используется нативным приложением [Whisper Mac](../mac-app/README.md).

Для обычной установки соберите `.pkg` из `mac-app`; вручную создавать `.venv` не требуется. Этот каталог оставлен для разработки и автономного запуска CLI.

## Ручной запуск для разработки

```bash
chmod +x install.sh
./install.sh
source .venv/bin/activate
whisper-mac recording.mp3 --backend mlx --language ru
```

Runtime использует MLX Whisper, pyannote Community-1, word-level timestamps и экспорт TXT/JSON/SRT/VTT.
