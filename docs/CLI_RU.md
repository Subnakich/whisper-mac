# Использование

Пользовательская инструкция для `.pkg` и GUI находится в [USAGE_RU.md](USAGE_RU.md).

Справка разработческого CLI:

```bash
source cli/.venv/bin/activate
whisper-mac --help
```

Пример:

```bash
export HF_TOKEN=hf_...
whisper-mac call.mp3 \
  --backend mlx \
  --model balanced \
  --language ru \
  --min-speakers 2 \
  --max-speakers 2
```
