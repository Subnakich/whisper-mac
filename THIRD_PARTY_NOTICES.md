# Third-party software and models

The Apache License 2.0 in this repository covers the original Whisper Mac
source code and documentation only. Third-party libraries, tools, model
weights, product names, and trademarks remain subject to their respective
licenses and terms.

The installer does not contain the machine-learning model weights or Python
runtime dependencies listed below. Whisper Mac downloads them to the user's
local cache during application preparation.

## Speech recognition

- **OpenAI Whisper large-v3-turbo** is the default speech-recognition model.
  Whisper Mac downloads the MLX conversion
  [`mlx-community/whisper-large-v3-turbo`](https://huggingface.co/mlx-community/whisper-large-v3-turbo),
  derived from
  [`openai/whisper-large-v3-turbo`](https://huggingface.co/openai/whisper-large-v3-turbo).
  The upstream OpenAI model and Whisper source are published under the MIT
  License. The MLX conversion's model card does not currently display a
  separate license identifier; consult both model cards before redistributing
  the downloaded weights.
- **OpenAI Whisper large-v3** is available as the higher-quality option via
  [`mlx-community/whisper-large-v3-mlx`](https://huggingface.co/mlx-community/whisper-large-v3-mlx),
  whose model card identifies the license as MIT.
- **MLX Whisper** (`mlx-whisper`) runs Whisper locally on Apple Silicon using
  Apple's MLX framework. It is published by the MLX contributors under the
  MIT License: <https://github.com/ml-explore/mlx-examples/tree/main/whisper>.

## Speaker diarization

- **pyannote.audio** provides the speaker-diarization runtime and is published
  under the MIT License: <https://github.com/pyannote/pyannote-audio>.
- **pyannote speaker-diarization-community-1** is the default diarization
  pipeline: <https://huggingface.co/pyannote/speaker-diarization-community-1>.
  Its model card identifies the license as CC BY 4.0. Access is gated: users
  must accept the model provider's access conditions and use their own
  Hugging Face read token. Those conditions are independent of the Whisper Mac
  license.

## Other dependencies

Whisper Mac also installs supporting open-source packages declared in
`cli/pyproject.toml`, together with their transitive dependencies. Their
licenses are supplied by their respective distributions. The exact resolved
set can change when a new build updates dependency versions; distributors
should review the resolved environment before shipping binaries.

OpenAI, Whisper, Apple, MLX, pyannote, Hugging Face, and other names may be
trademarks of their respective owners. Their use here is descriptive and does
not imply sponsorship or endorsement.
