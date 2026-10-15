DubWave CLI
A Bash command-line starter project for translating a video's spoken audio,generating dubbed speech, and writing translated SRT subtitles.

The workflow uses FFmpeg for media processing, an audio API for transcriptionand speech generation, and a chat-completions-compatible text API fortranslation.

Features
Extracts and chunks audio before transcription.
Translates timestamped transcript segments into the requested language.
Generates speech for each translated segment.
Mixes generated speech with the original audio at a configurable volume.
Writes a translated .srt subtitle file beside the output video.
Supports separate API settings for audio and translation.
Requirements
Bash
curl
jq
ffmpeg
ffprobe
awk
API credentials for compatible transcription, translation, and speech endpoints
Installing dependencies
Debian / Ubuntu:

sudo apt-get updatesudo apt-get install bash curl jq ffmpeg gawk
macOS (Homebrew):

brew install bash curl jq ffmpeg gawk
Fedora / RHEL:

sudo dnf install bash curl jq ffmpeg gawk
Arch:

sudo pacman -S bash curl jq ffmpeg gawk
Windows: use WSL2 and follow the Debian/Ubuntu instructions.

Setup
git clone https://github.com/swordenkisk/dubwave.gitcd dubwavecp .env.example .envchmod +x dubwave.sh
Edit .env and set API keys and model identifiers supported by your chosenproviders. Keep .env private; it contains credentials.

Check the local tools and configuration:

./dubwave.sh check
Usage
./dubwave.sh translate INPUT_VIDEO OUTPUT_VIDEO TARGET_LANGUAGE
Example:

./dubwave.sh translate ./input.mp4 ./output.mp4 Spanish
The command creates the dubbed video and a subtitle file at ./output.srt.

Configuration
AUDIO_API_BASE: Base URL for transcription and speech endpoints.
AUDIO_API_KEY: Credential for the audio API.
TEXT_API_BASE: Base URL for a chat-completions-compatible text API.
TEXT_API_KEY: Credential for the text API.
TRANSCRIPTION_MODEL: Transcription model identifier.
TRANSLATION_MODEL: Translation model identifier.
TTS_MODEL: Text-to-speech model identifier.
TTS_VOICE: Voice identifier supported by the speech provider.
CHUNK_SECONDS: Audio chunk duration in seconds.
BACKGROUND_VOLUME: Original audio level in the final mix, from 0 to 1.
When using one provider for all tasks, OPENAI_API_KEY can supply both keys.Configure separate audio and text bases and keys when your providers exposedifferent endpoints.

Workflow overview
FFmpeg extracts mono 16 kHz audio from the video.
Audio is split into chunks (default 300 seconds) for transcription.
Each chunk is transcribed with timestamped segments.
Segments are translated into the target language as a single batch.
Speech is generated per translated segment and written as an SRT subtitle.
FFmpeg delays each speech clip to its original timestamp, mixes it over aquiet copy of the source audio, and muxes with the original video stream.
Notes
Provider APIs, model identifiers, account access, and billing vary.Configure values that your provider currently supports.
This starter expects transcription responses with timestamped segmentsand text-to-speech endpoints that return audio data.
The generated voice is synthetic. Tell viewers when a video includesAI-generated speech.
Review generated translations and audio before publishing.
Use videos and voice likenesses only when you have the appropriate rightsand permissions.
This is a command-line prototype, not a replacement for a productiondubbing studio.
License
MIT. See the LICENSE file.

Quick start (all necessary programs)
bash

# 1. Install dependencies (Ubuntu/Debian example)
sudo apt-get update && sudo apt-get install -y bash curl jq ffmpeg gawk

# 2. Clone and set up
git clone https://github.com/swordenkisk/dubwave.git
cd dubwave
cp .env.example .env
chmod +x dubwave.sh

# 3. Add your API key(s) to .env
 $EDITOR .env

# 4. Verify environment
./dubwave.sh check

# 5. Translate and dub
./dubwave.sh translate ./input.mp4 ./output.mp4 Spanish
Everything above is self-contained: dubwave.sh is the only program, and curl, jq, ffmpeg, ffprobe, and awk are the required external tools (all standard packages on Linux/macOS). The LICENSE file was added since the README references it. Let me know if you'd also like a GitHub Actions workflow, a Makefile, or ShellCheck CI added to the repo.