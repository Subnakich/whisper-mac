from __future__ import annotations

import argparse
import os
import platform
import sys
from pathlib import Path

from .core import (
    DEFAULT_ASR_MODEL,
    DEFAULT_DIARIZATION_MODEL,
    DEFAULT_FASTER_WHISPER_MODEL,
    QUALITY_ASR_MODEL,
    QUALITY_FASTER_WHISPER_MODEL,
    environment_token,
    process_file,
    report_progress,
)


MODEL_ALIASES = {
    "mlx": {
        "balanced": DEFAULT_ASR_MODEL,
        "quality": QUALITY_ASR_MODEL,
    },
    "faster-whisper": {
        "balanced": DEFAULT_FASTER_WHISPER_MODEL,
        "quality": QUALITY_FASTER_WHISPER_MODEL,
    },
}


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("значение должно быть положительным")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="whisper-mac",
        description="Локальная расшифровка на Apple Silicon: MLX Whisper + pyannote Community-1.",
    )
    parser.add_argument("files", nargs="+", type=Path, help="аудио- или видеофайлы")
    default_output = os.environ.get("OUTPUT_DIR")
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=Path(default_output) if default_output else None,
        help="каталог результатов",
    )
    parser.add_argument(
        "--backend",
        choices=("auto", "mlx", "faster-whisper"),
        default=os.environ.get("ASR_BACKEND", "auto"),
        help="ASR backend: auto, mlx или faster-whisper",
    )
    parser.add_argument(
        "--model",
        default="balanced",
        help="balanced (по умолчанию), quality или Hugging Face model/path",
    )
    parser.add_argument("--language", default="auto", help="язык: auto, ru, en, ...")
    parser.add_argument("--prompt", help="словарная подсказка: имена, бренды, термины")
    parser.add_argument("--no-diarize", action="store_true", help="не определять спикеров")
    parser.add_argument(
        "--diarization-model",
        default=DEFAULT_DIARIZATION_MODEL,
        help="Hugging Face model или локальный каталог",
    )
    parser.add_argument("--min-speakers", type=positive_int)
    parser.add_argument("--max-speakers", type=positive_int)
    parser.add_argument(
        "--diarization-device",
        choices=("auto", "mps", "cpu"),
        default="auto",
        help="ускорение диаризации: auto, mps или cpu",
    )
    parser.add_argument(
        "--speaker-profiles",
        type=Path,
        help="локальная библиотека сохранённых голосовых профилей",
    )
    parser.add_argument(
        "--session-result",
        type=Path,
        help="служебный файл с найденными голосами для приложения",
    )
    parser.add_argument(
        "--avoid-overwrite",
        action="store_true",
        help="добавлять номер к имени результата вместо перезаписи существующих файлов",
    )
    parser.add_argument(
        "--format",
        dest="formats",
        action="append",
        choices=("txt", "md", "json", "srt", "vtt"),
        help="формат результата; можно повторить (по умолчанию: txt,md,json,srt,vtt)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.min_speakers and args.max_speakers and args.min_speakers > args.max_speakers:
        parser.error("--min-speakers не может быть больше --max-speakers")

    backend = args.backend
    if backend == "auto":
        backend = (
            "mlx"
            if platform.system() == "Darwin" and platform.machine() == "arm64"
            else "faster-whisper"
        )
    asr_model = MODEL_ALIASES[backend].get(args.model, args.model)
    formats = set(args.formats or ("txt", "md", "json", "srt", "vtt"))
    failed = False
    total_files = len(args.files)
    for index, source in enumerate(args.files, 1):
        report_progress(
            "file_started",
            0.0,
            file_index=index,
            total_files=total_files,
            file_name=source.name,
        )
        print(f"→ {source}", file=sys.stderr)
        try:
            paths = process_file(
                source,
                output_dir=args.output_dir,
                backend=backend,
                asr_model=asr_model,
                diarization_model=args.diarization_model,
                language=args.language,
                initial_prompt=args.prompt,
                enable_diarization=not args.no_diarize,
                token=environment_token(),
                min_speakers=args.min_speakers,
                max_speakers=args.max_speakers,
                formats=formats,
                diarization_device=args.diarization_device,
                speaker_profiles=args.speaker_profiles,
                session_result=args.session_result,
                avoid_overwrite=args.avoid_overwrite,
            )
            for path in paths:
                print(f"  ✓ {path}", file=sys.stderr)
            report_progress(
                "file_completed",
                1.0,
                file_index=index,
                total_files=total_files,
                file_name=source.name,
            )
        except Exception as exc:
            failed = True
            print(f"  ✗ {exc}", file=sys.stderr)
            report_progress(
                "file_failed",
                1.0,
                file_index=index,
                total_files=total_files,
                file_name=source.name,
                message=str(exc),
            )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
