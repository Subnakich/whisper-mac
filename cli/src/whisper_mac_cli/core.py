from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


DEFAULT_ASR_MODEL = "mlx-community/whisper-large-v3-turbo"
QUALITY_ASR_MODEL = "mlx-community/whisper-large-v3-mlx"
DEFAULT_FASTER_WHISPER_MODEL = "large-v3-turbo"
QUALITY_FASTER_WHISPER_MODEL = "large-v3"
DEFAULT_DIARIZATION_MODEL = "pyannote/speaker-diarization-community-1"
PROGRESS_PREFIX = "@@WHISPER_MAC_PROGRESS@@"


def report_progress(stage: str, progress: float, **details: Any) -> None:
    """Emit a private, line-oriented progress event for the macOS app."""
    if os.environ.get("WHISPER_MAC_PROGRESS") != "1":
        return
    payload = {"stage": stage, "progress": max(0.0, min(1.0, progress)), **details}
    print(PROGRESS_PREFIX + json.dumps(payload, ensure_ascii=False), file=sys.stderr, flush=True)


def audio_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / float(audio.getframerate())


def _cached_model_bytes(repo_id: str) -> tuple[int, int]:
    cache_root = Path(
        os.environ.get(
            "HF_HUB_CACHE",
            Path.home() / ".cache" / "huggingface" / "hub",
        )
    )
    model_root = cache_root / ("models--" + repo_id.replace("/", "--"))
    tree_files = sorted(
        (model_root / "trees").glob("*.json"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    if not tree_files:
        return 0, 0
    try:
        manifest = json.loads(tree_files[0].read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0, 0

    downloaded = 0
    total = 0
    blobs = model_root / "blobs"
    for metadata in manifest.get("files", {}).values():
        size = int(metadata.get("size") or metadata.get("lfs_size") or 0)
        total += size
        candidates = [metadata.get("blob_id"), metadata.get("lfs_sha256")]
        present = 0
        for identifier in filter(None, candidates):
            exact = blobs / str(identifier)
            if exact.exists():
                present = max(present, exact.stat().st_size)
            for partial in blobs.glob(f"{identifier}.*.incomplete"):
                present = max(present, partial.stat().st_size)
        downloaded += min(size, present)
    return downloaded, total


def ensure_huggingface_model(repo_or_path: str, *, token: str | None = None) -> str:
    local = Path(repo_or_path).expanduser()
    if local.exists():
        return str(local)
    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:
        raise RuntimeError("huggingface-hub не установлен") from exc

    try:
        return snapshot_download(repo_or_path, token=token, local_files_only=True)
    except Exception:
        pass

    stop = threading.Event()

    def watch_download() -> None:
        while not stop.wait(0.5):
            downloaded, total = _cached_model_bytes(repo_or_path)
            report_progress(
                "download_asr",
                0.04 + (0.06 * downloaded / total if total else 0.0),
                downloaded=downloaded,
                total=total,
            )

    report_progress("download_asr", 0.04, downloaded=0, total=0)
    watcher = threading.Thread(target=watch_download, daemon=True)
    watcher.start()
    try:
        return snapshot_download(repo_or_path, token=token)
    finally:
        stop.set()
        watcher.join(timeout=1)


@dataclass(frozen=True)
class Word:
    start: float
    end: float
    text: str
    probability: float | None = None
    speaker: str | None = None


@dataclass(frozen=True)
class Turn:
    start: float
    end: float
    speaker: str


@dataclass(frozen=True)
class DiarizationResult:
    turns: list[Turn]
    embeddings: dict[str, list[float]]


def _normalized(vector: Iterable[float]) -> list[float]:
    values = [float(value) for value in vector]
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values] if norm else values


def _mean_embedding(samples: list[list[float]]) -> list[float]:
    valid = [sample for sample in samples if sample]
    if not valid:
        return []
    size = len(valid[0])
    matching = [sample for sample in valid if len(sample) == size]
    if not matching:
        return []
    return _normalized(
        sum(float(sample[index]) for sample in matching) / len(matching)
        for index in range(size)
    )


def _cosine_similarity(left: list[float], right: list[float]) -> float:
    if not left or len(left) != len(right):
        return -1.0
    normalized_left = _normalized(left)
    normalized_right = _normalized(right)
    return sum(a * b for a, b in zip(normalized_left, normalized_right))


def load_speaker_profiles(path: Path | None) -> list[dict[str, Any]]:
    if path is None or not path.is_file():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    profiles = payload.get("profiles", []) if isinstance(payload, dict) else []
    return [profile for profile in profiles if isinstance(profile, dict)]


def match_speaker_profiles(
    embeddings: dict[str, list[float]],
    profiles: list[dict[str, Any]],
    *,
    threshold: float = 0.72,
    margin: float = 0.06,
) -> dict[str, dict[str, Any]]:
    """Conservatively match speakers to saved profiles, at most once per recording."""
    candidates: list[tuple[float, float, str, dict[str, Any]]] = []
    for label, embedding in embeddings.items():
        scores: list[tuple[float, dict[str, Any]]] = []
        for profile in profiles:
            samples = profile.get("samples")
            if not isinstance(samples, list):
                continue
            centroid = _mean_embedding(
                [sample for sample in samples if isinstance(sample, list)]
            )
            scores.append((_cosine_similarity(embedding, centroid), profile))
        scores.sort(key=lambda item: item[0], reverse=True)
        if not scores:
            continue
        best_score, best_profile = scores[0]
        runner_up = scores[1][0] if len(scores) > 1 else -1.0
        if best_score >= threshold and best_score - runner_up >= margin:
            candidates.append((best_score, runner_up, label, best_profile))

    matches: dict[str, dict[str, Any]] = {}
    used_profiles: set[str] = set()
    for score, _, label, profile in sorted(candidates, reverse=True, key=lambda item: item[0]):
        profile_id = str(profile.get("id", ""))
        name = str(profile.get("name", "")).strip()
        if not profile_id or not name or profile_id in used_profiles:
            continue
        matches[label] = {"id": profile_id, "name": name, "confidence": score}
        used_profiles.add(profile_id)
    return matches


def ffmpeg_executable() -> str:
    configured = os.environ.get("FFMPEG_BINARY")
    if configured:
        resolved = shutil.which(configured)
        if resolved:
            return resolved
        configured_path = Path(configured).expanduser()
        if configured_path.is_file() and os.access(configured_path, os.X_OK):
            return str(configured_path)
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


def require_ffmpeg() -> str:
    executable = ffmpeg_executable()
    try:
        completed = subprocess.run(
            [executable, "-version"], capture_output=True, text=True, check=False
        )
    except FileNotFoundError as exc:
        raise RuntimeError(
            "Встроенный модуль чтения аудио не найден. Обновите компоненты приложения."
        ) from exc
    if completed.returncode != 0:
        raise RuntimeError("ffmpeg runtime не найден. Переустановите runtime приложения.")
    return executable


def convert_audio(source: Path, destination: Path, *, ffmpeg: str | None = None) -> None:
    completed = subprocess.run(
        [
            ffmpeg or ffmpeg_executable(),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "ffmpeg не смог прочитать файл")


def transcribe_mlx(
    audio_path: Path,
    *,
    model: str,
    language: str | None,
    initial_prompt: str | None,
) -> dict[str, Any]:
    try:
        import mlx_whisper
    except ImportError as exc:
        detail = str(exc)
        if "No Metal device available" in detail:
            raise RuntimeError(
                "Metal недоступен в текущей сессии. Запускайте whisper-mac в обычном "
                "Terminal.app/iTerm на Mac, не из headless или виртуализированной среды."
            ) from exc
        raise RuntimeError("mlx-whisper не установлен; запустите ./scripts/install_cli.sh") from exc

    options: dict[str, Any] = {
        "path_or_hf_repo": model,
        "word_timestamps": True,
        "verbose": False,
        "condition_on_previous_text": True,
    }
    if language and language != "auto":
        options["language"] = language
    if initial_prompt:
        options["initial_prompt"] = initial_prompt
    try:
        import soundfile as sf

        samples, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
    except Exception as exc:
        raise RuntimeError(f"Не удалось прочитать подготовленный звук: {exc}") from exc
    if int(sample_rate) != 16_000:
        raise RuntimeError("Подготовленный звук должен иметь частоту 16 кГц")
    if getattr(samples, "ndim", 1) > 1:
        samples = samples.mean(axis=1)
    return mlx_whisper.transcribe(samples, **options)


def transcribe_faster_whisper(
    audio_path: Path,
    *,
    model: str,
    language: str | None,
    initial_prompt: str | None,
) -> dict[str, Any]:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise RuntimeError(
            "faster-whisper не установлен; пересоберите Docker image или установите extra [docker]"
        ) from exc

    device = os.environ.get("ASR_DEVICE", "cpu")
    compute_type = os.environ.get(
        "ASR_COMPUTE_TYPE", "int8" if device == "cpu" else "float16"
    )
    whisper = WhisperModel(model, device=device, compute_type=compute_type)
    options: dict[str, Any] = {
        "word_timestamps": True,
        "vad_filter": True,
        "condition_on_previous_text": True,
    }
    if language and language != "auto":
        options["language"] = language
    if initial_prompt:
        options["initial_prompt"] = initial_prompt
    segments, info = whisper.transcribe(str(audio_path), **options)
    serialized_segments: list[dict[str, Any]] = []
    text_parts: list[str] = []
    for segment in segments:
        text_parts.append(segment.text)
        serialized_segments.append(
            {
                "start": float(segment.start),
                "end": float(segment.end),
                "text": segment.text,
                "words": [
                    {
                        "start": float(word.start),
                        "end": float(word.end),
                        "word": word.word,
                        "probability": float(word.probability),
                    }
                    for word in (segment.words or [])
                ],
            }
        )
    return {
        "text": "".join(text_parts),
        "language": info.language,
        "segments": serialized_segments,
    }


def transcribe(
    audio_path: Path,
    *,
    backend: str,
    model: str,
    language: str | None,
    initial_prompt: str | None,
) -> dict[str, Any]:
    if backend == "mlx":
        return transcribe_mlx(
            audio_path,
            model=model,
            language=language,
            initial_prompt=initial_prompt,
        )
    if backend == "faster-whisper":
        return transcribe_faster_whisper(
            audio_path,
            model=model,
            language=language,
            initial_prompt=initial_prompt,
        )
    raise RuntimeError(f"Неизвестный ASR backend: {backend}")


def words_from_result(result: dict[str, Any]) -> list[Word]:
    words: list[Word] = []
    for segment in result.get("segments", []):
        segment_words = segment.get("words") or []
        if segment_words:
            for item in segment_words:
                if "start" not in item or "end" not in item:
                    continue
                text = str(item.get("word", ""))
                if not text:
                    continue
                probability = item.get("probability")
                words.append(
                    Word(
                        start=float(item["start"]),
                        end=float(item["end"]),
                        text=text,
                        probability=float(probability) if probability is not None else None,
                    )
                )
        elif segment.get("text") and "start" in segment and "end" in segment:
            words.append(
                Word(
                    start=float(segment["start"]),
                    end=float(segment["end"]),
                    text=str(segment["text"]),
                )
            )
    return words


def _iter_annotation(annotation: Any) -> Iterable[Turn]:
    if hasattr(annotation, "itertracks"):
        for segment, _, speaker in annotation.itertracks(yield_label=True):
            yield Turn(float(segment.start), float(segment.end), str(speaker))
        return
    for segment, speaker in annotation:
        yield Turn(float(segment.start), float(segment.end), str(speaker))


def diarize(
    audio_path: Path,
    *,
    model: str,
    token: str | None,
    min_speakers: int | None,
    max_speakers: int | None,
    device: str = "auto",
) -> DiarizationResult:
    try:
        from pyannote.audio import Pipeline
    except ImportError as exc:
        raise RuntimeError("pyannote.audio не установлен; запустите ./scripts/install_cli.sh") from exc

    source_is_local = Path(model).expanduser().exists()
    if not token and not source_is_local:
        raise RuntimeError(
            "Для загрузки pyannote нужен HF_TOKEN. Примите условия модели на Hugging Face "
            "и выполните: export HF_TOKEN=hf_..."
        )
    pipeline = Pipeline.from_pretrained(
        str(Path(model).expanduser()) if source_is_local else model,
        token=token,
    )
    if pipeline is None:
        raise RuntimeError(
            "Нет доступа к модели разделения голосов. Примите условия community-1 "
            "на Hugging Face и проверьте ключ доступа."
        )

    import torch

    selected_device = device
    if selected_device == "auto":
        selected_device = "mps" if torch.backends.mps.is_available() else "cpu"
    if selected_device == "mps" and not torch.backends.mps.is_available():
        selected_device = "cpu"
    if selected_device == "mps":
        pipeline.to(torch.device("mps"))
        report_progress("diarization_accelerated", 0.0)

    kwargs: dict[str, int] = {}
    if min_speakers is not None:
        kwargs["min_speakers"] = min_speakers
    if max_speakers is not None:
        kwargs["max_speakers"] = max_speakers

    class AppProgressHook:
        def __call__(
            self,
            step_name: str,
            step_artifact: Any,
            file: Any = None,
            total: int | None = None,
            completed: int | None = None,
        ) -> None:
            if completed is None or not total:
                fraction = 1.0
            else:
                fraction = completed / total
            report_progress(
                "diarization_progress",
                fraction,
                step=str(step_name),
            )

    try:
        report_progress("diarizing", 0.74)
        import soundfile as sf
        samples, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=True)
        waveform = torch.from_numpy(samples.T.copy())
        audio_input = {"waveform": waveform, "sample_rate": int(sample_rate)}
        try:
            output = pipeline(audio_input, hook=AppProgressHook(), **kwargs)
        except RuntimeError:
            if selected_device != "mps":
                raise
            report_progress("diarization_cpu_fallback", 0.0)
            pipeline.to(torch.device("cpu"))
            if hasattr(torch, "mps"):
                torch.mps.empty_cache()
            output = pipeline(audio_input, hook=AppProgressHook(), **kwargs)
    except Exception as exc:
        raise RuntimeError(f"Не удалось выполнить диаризацию: {exc}") from exc
    annotation = getattr(output, "exclusive_speaker_diarization", None)
    if annotation is None:
        annotation = getattr(output, "speaker_diarization", output)
    turns = list(_iter_annotation(annotation))
    labels = (
        [str(label) for label in annotation.labels()]
        if hasattr(annotation, "labels")
        else sorted({turn.speaker for turn in turns})
    )
    raw_embeddings = getattr(output, "speaker_embeddings", None)
    embeddings: dict[str, list[float]] = {}
    if raw_embeddings is not None:
        for label, embedding in zip(labels, raw_embeddings):
            if hasattr(embedding, "detach"):
                embedding = embedding.detach().cpu()
            if hasattr(embedding, "tolist"):
                embedding = embedding.tolist()
            embeddings[label] = _normalized(embedding)
    return DiarizationResult(turns, embeddings)


def _overlap(start_a: float, end_a: float, start_b: float, end_b: float) -> float:
    return max(0.0, min(end_a, end_b) - max(start_a, start_b))


def assign_speakers(words: list[Word], turns: list[Turn]) -> list[Word]:
    if not turns:
        return words
    assigned: list[Word] = []
    for word in words:
        best = max(
            turns,
            key=lambda turn: (
                _overlap(word.start, word.end, turn.start, turn.end),
                -abs(((word.start + word.end) / 2) - ((turn.start + turn.end) / 2)),
            ),
        )
        assigned.append(
            Word(
                start=word.start,
                end=word.end,
                text=word.text,
                probability=word.probability,
                speaker=best.speaker,
            )
        )
    return assigned


def _join_text(parts: list[str]) -> str:
    text = "".join(parts).strip()
    return " ".join(text.split())


def make_utterances(words: list[Word], max_gap: float = 1.0) -> list[dict[str, Any]]:
    utterances: list[dict[str, Any]] = []
    current: list[Word] = []
    for word in words:
        if current and (
            word.speaker != current[-1].speaker or word.start - current[-1].end > max_gap
        ):
            utterances.append(_utterance(current))
            current = []
        current.append(word)
    if current:
        utterances.append(_utterance(current))
    return utterances


def _utterance(words: list[Word]) -> dict[str, Any]:
    return {
        "start": words[0].start,
        "end": words[-1].end,
        "speaker": words[0].speaker,
        "text": _join_text([word.text for word in words]),
        "words": [
            {
                "start": word.start,
                "end": word.end,
                "text": word.text.strip(),
                "probability": word.probability,
                "speaker": word.speaker,
            }
            for word in words
        ],
    }


def format_timestamp(seconds: float, decimal_marker: str = ",") -> str:
    milliseconds = max(0, round(seconds * 1000))
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    secs, millis = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{decimal_marker}{millis:03d}"


def display_speaker(value: str | None) -> str:
    if not value:
        return "Речь"
    if value.startswith("SPEAKER_"):
        try:
            return f"Спикер {int(value.removeprefix('SPEAKER_')) + 1}"
        except ValueError:
            pass
    return value


def render_txt(utterances: list[dict[str, Any]]) -> str:
    lines = []
    for item in utterances:
        speaker = display_speaker(item.get("speaker"))
        lines.append(f"[{format_timestamp(item['start'], '.')}] {speaker}: {item['text']}")
    return "\n".join(lines) + ("\n" if lines else "")


def render_md(utterances: list[dict[str, Any]]) -> str:
    blocks = ["# Расшифровка"]
    for item in utterances:
        speaker = display_speaker(item.get("speaker"))
        timestamp = format_timestamp(item["start"], ".")
        blocks.append(f"**{speaker} · {timestamp}**\n\n{item['text']}")
    return "\n\n".join(blocks) + "\n"


def render_srt(utterances: list[dict[str, Any]]) -> str:
    blocks = []
    for index, item in enumerate(utterances, 1):
        speaker = f"{display_speaker(item['speaker'])}: " if item.get("speaker") else ""
        blocks.append(
            f"{index}\n{format_timestamp(item['start'])} --> {format_timestamp(item['end'])}\n"
            f"{speaker}{item['text']}"
        )
    return "\n\n".join(blocks) + ("\n" if blocks else "")


def render_vtt(utterances: list[dict[str, Any]]) -> str:
    blocks = ["WEBVTT"]
    for item in utterances:
        speaker = f"{display_speaker(item['speaker'])}: " if item.get("speaker") else ""
        blocks.append(
            f"{format_timestamp(item['start'], '.')} --> {format_timestamp(item['end'], '.')}\n"
            f"{speaker}{item['text']}"
        )
    return "\n\n".join(blocks) + "\n"


def write_outputs(
    output_base: Path,
    *,
    metadata: dict[str, Any],
    utterances: list[dict[str, Any]],
    formats: set[str],
) -> list[Path]:
    output_base.parent.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    renderers = {"txt": render_txt, "md": render_md, "srt": render_srt, "vtt": render_vtt}
    for output_format in sorted(formats):
        path = output_base.with_suffix(f".{output_format}")
        if output_format == "json":
            path.write_text(
                json.dumps({**metadata, "utterances": utterances}, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        else:
            path.write_text(renderers[output_format](utterances), encoding="utf-8")
        written.append(path)
    return written


def available_output_base(output_base: Path, formats: set[str]) -> Path:
    """Return a non-conflicting output name for batch processing."""
    if not any(output_base.with_suffix(f".{name}").exists() for name in formats):
        return output_base
    index = 2
    while True:
        candidate = output_base.with_name(f"{output_base.name}-{index}")
        if not any(candidate.with_suffix(f".{name}").exists() for name in formats):
            return candidate
        index += 1


def process_file(
    source: Path,
    *,
    output_dir: Path | None,
    backend: str,
    asr_model: str,
    diarization_model: str,
    language: str | None,
    initial_prompt: str | None,
    enable_diarization: bool,
    token: str | None,
    min_speakers: int | None,
    max_speakers: int | None,
    formats: set[str],
    diarization_device: str = "auto",
    speaker_profiles: Path | None = None,
    session_result: Path | None = None,
    avoid_overwrite: bool = False,
) -> list[Path]:
    if not source.is_file():
        raise RuntimeError(f"Файл не найден: {source}")
    report_progress("preparing", 0.01)
    ffmpeg = require_ffmpeg()
    with tempfile.TemporaryDirectory(prefix="whisper-mac-") as temp_dir:
        wav_path = Path(temp_dir) / "audio.wav"
        report_progress("converting", 0.03)
        convert_audio(source, wav_path, ffmpeg=ffmpeg)
        duration = audio_duration(wav_path)
        resolved_asr_model = (
            ensure_huggingface_model(asr_model, token=token)
            if backend == "mlx"
            else asr_model
        )
        report_progress("recognizing", 0.12, audio_duration=duration)
        recognition_started = time.monotonic()
        result = transcribe(
            wav_path,
            backend=backend,
            model=resolved_asr_model,
            language=language,
            initial_prompt=initial_prompt,
        )
        recognition_elapsed = max(time.monotonic() - recognition_started, 0.001)
        report_progress(
            "recognized",
            0.68 if enable_diarization else 0.9,
            audio_duration=duration,
            elapsed=recognition_elapsed,
            speed=duration / recognition_elapsed,
        )
        words = words_from_result(result)
        if enable_diarization:
            report_progress("loading_diarization", 0.7, audio_duration=duration)
            try:
                diarization_result = diarize(
                    wav_path,
                    model=diarization_model,
                    token=token,
                    min_speakers=min_speakers,
                    max_speakers=max_speakers,
                    device=diarization_device,
                )
            except Exception as exc:
                report_progress(
                    "error",
                    0.7,
                    code="diarization",
                    message=str(exc),
                )
                raise
            embeddings = diarization_result.embeddings
            matches = match_speaker_profiles(
                embeddings, load_speaker_profiles(speaker_profiles)
            )
            turns = [
                Turn(turn.start, turn.end, matches.get(turn.speaker, {}).get("name", turn.speaker))
                for turn in diarization_result.turns
            ]
            report_progress("diarized", 0.92, audio_duration=duration)
        else:
            turns = []
            embeddings = {}
            matches = {}
        utterances = make_utterances(assign_speakers(words, turns))

    report_progress("exporting", 0.95)
    target_dir = output_dir or source.parent
    output_base = target_dir / source.stem
    if avoid_overwrite:
        output_base = available_output_base(output_base, formats)
    metadata = {
        "source": str(source.resolve()),
        "language": result.get("language"),
        "asr_backend": backend,
        "asr_model": asr_model,
        "diarization_model": diarization_model if enable_diarization else None,
    }
    written = write_outputs(output_base, metadata=metadata, utterances=utterances, formats=formats)
    if session_result is not None:
        durations: dict[str, float] = {}
        if enable_diarization:
            for turn in diarization_result.turns:
                durations[turn.speaker] = durations.get(turn.speaker, 0.0) + max(
                    0.0, turn.end - turn.start
                )
        speakers = []
        for index, label in enumerate(sorted(embeddings)):
            match = matches.get(label)
            speakers.append(
                {
                    "label": label,
                    "display_name": match["name"] if match else display_speaker(label),
                    "embedding": embeddings[label],
                    "duration": durations.get(label, 0.0),
                    "profile_id": match["id"] if match else None,
                    "confidence": match["confidence"] if match else None,
                    "order": index,
                }
            )
        session_result.parent.mkdir(parents=True, exist_ok=True)
        session_result.write_text(
            json.dumps(
                {"version": 1, "source": str(source.resolve()), "speakers": speakers},
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    report_progress("done", 1.0)
    return written


def environment_token() -> str | None:
    return os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_ACCESS_TOKEN")
