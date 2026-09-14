#!/bin/sh
set -eu

cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "Эта утилита предназначена для macOS на Apple Silicon (arm64)." >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Не найден ffmpeg. Установите его и повторите:" >&2
  echo "  brew install ffmpeg" >&2
  exit 1
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"
"$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if (3, 11) <= sys.version_info[:2] < (3, 14) else 1)' || {
  echo "Нужен Python 3.11–3.13. Текущий: $("$PYTHON_BIN" --version 2>&1)" >&2
  exit 1
}

"$PYTHON_BIN" -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e ".[mac]"

echo
echo "Готово. Запуск:"
echo "  source $(pwd)/.venv/bin/activate"
echo "  whisper-mac запись.mp3 --language ru --min-speakers 2 --max-speakers 2"
