import sys
from types import SimpleNamespace

from whisper_mac_cli.core import (
    Turn,
    Word,
    assign_speakers,
    ffmpeg_executable,
    format_timestamp,
    make_utterances,
    match_speaker_profiles,
    render_md,
    transcribe_mlx,
)
from whisper_mac_cli.cli import MODEL_ALIASES


def test_assigns_words_and_splits_on_speaker_change():
    words = [
        Word(0.0, 0.8, " Привет"),
        Word(0.8, 1.2, ","),
        Word(1.2, 1.8, " Анна"),
        Word(2.0, 2.5, " Здравствуйте"),
    ]
    turns = [Turn(0.0, 1.9, "SPEAKER_00"), Turn(1.9, 3.0, "SPEAKER_01")]

    utterances = make_utterances(assign_speakers(words, turns))

    assert len(utterances) == 2
    assert utterances[0]["speaker"] == "SPEAKER_00"
    assert utterances[0]["text"] == "Привет, Анна"
    assert utterances[1]["speaker"] == "SPEAKER_01"


def test_nearest_turn_is_used_when_word_has_no_overlap():
    word = Word(3.0, 3.1, " пауза")
    assigned = assign_speakers(
        [word], [Turn(0.0, 1.0, "A"), Turn(4.0, 5.0, "B")]
    )
    assert assigned[0].speaker == "B"


def test_timestamp_rounding():
    assert format_timestamp(3661.2346) == "01:01:01,235"


def test_backend_model_aliases():
    assert MODEL_ALIASES["faster-whisper"]["balanced"] == "large-v3-turbo"
    assert MODEL_ALIASES["faster-whisper"]["quality"] == "large-v3"
    assert MODEL_ALIASES["mlx"]["balanced"].startswith("mlx-community/")


def test_markdown_export():
    content = render_md([{"start": 1.25, "end": 2.0, "speaker": "SPEAKER_00", "text": "Привет"}])
    assert content.startswith("# Расшифровка")
    assert "**Спикер 1 · 00:00:01.250**" in content
    assert "Привет" in content


def test_missing_configured_ffmpeg_falls_back_to_bundled(monkeypatch):
    monkeypatch.setenv("FFMPEG_BINARY", "definitely-missing-ffmpeg")
    monkeypatch.setitem(
        sys.modules,
        "imageio_ffmpeg",
        SimpleNamespace(get_ffmpeg_exe=lambda: "/bundled/ffmpeg"),
    )

    assert ffmpeg_executable() == "/bundled/ffmpeg"


def test_mlx_receives_audio_samples_instead_of_ffmpeg_path(monkeypatch, tmp_path):
    class Samples:
        ndim = 1

    samples = Samples()
    captured = {}

    def transcribe(audio, **options):
        captured["audio"] = audio
        return {"segments": []}

    monkeypatch.setitem(sys.modules, "mlx_whisper", SimpleNamespace(transcribe=transcribe))
    monkeypatch.setitem(
        sys.modules,
        "soundfile",
        SimpleNamespace(read=lambda *args, **kwargs: (samples, 16_000)),
    )

    result = transcribe_mlx(
        tmp_path / "audio.wav",
        model="local-model",
        language="ru",
        initial_prompt=None,
    )

    assert result == {"segments": []}
    assert captured["audio"] is samples


def test_matches_a_saved_voice_profile():
    matches = match_speaker_profiles(
        {"SPEAKER_00": [1.0, 0.0, 0.0]},
        [{"id": "anna", "name": "Анна", "samples": [[0.99, 0.01, 0.0]]}],
    )

    assert matches["SPEAKER_00"]["name"] == "Анна"
    assert matches["SPEAKER_00"]["confidence"] > 0.99


def test_does_not_guess_between_similar_profiles():
    matches = match_speaker_profiles(
        {"SPEAKER_00": [1.0, 0.0]},
        [
            {"id": "one", "name": "Первый", "samples": [[1.0, 0.02]]},
            {"id": "two", "name": "Второй", "samples": [[1.0, 0.03]]},
        ],
    )

    assert matches == {}


def test_same_profile_is_not_assigned_to_two_speakers():
    matches = match_speaker_profiles(
        {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.99, 0.01]},
        [{"id": "anna", "name": "Анна", "samples": [[1.0, 0.0]]}],
    )

    assert len(matches) == 1
