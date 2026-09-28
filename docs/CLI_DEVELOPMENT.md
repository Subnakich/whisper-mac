# Разработка CLI

Python-пайплайн из `cli/` используется нативным приложением и может запускаться самостоятельно.

Для обычного использования соберите `.pkg`; вручную создавать `.venv` не требуется.

## Ручной запуск для разработки

```bash
./scripts/install_cli.sh
source cli/.venv/bin/activate
whisper-mac recording.mp3 --backend mlx --language ru
```

Runtime использует MLX Whisper, pyannote Community-1, временные метки слов и экспорт TXT/Markdown/JSON/SRT/VTT.

Тесты без загрузки моделей:

```bash
PYTHONPATH=cli/src python3 -m pytest cli/tests -q
```
