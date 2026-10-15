#!/usr/bin/env bash
# dubwave.sh — translate and dub a video using FFmpeg and API-compatible services.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="DubWave"
AUDIO_API_BASE="${AUDIO_API_BASE:-https://api.openai.com/v1}"
TEXT_API_BASE="${TEXT_API_BASE:-https://api.openai.com/v1}"
AUDIO_API_KEY="${AUDIO_API_KEY:-${OPENAI_API_KEY:-}}"
TEXT_API_KEY="${TEXT_API_KEY:-${OPENAI_API_KEY:-}}"
TRANSCRIPTION_MODEL="${TRANSCRIPTION_MODEL:-whisper-1}"
TRANSLATION_MODEL="${TRANSLATION_MODEL:-gpt-4o-mini}"
TTS_MODEL="${TTS_MODEL:-gpt-4o-mini-tts}"
TTS_VOICE="${TTS_VOICE:-alloy}"
CHUNK_SECONDS="${CHUNK_SECONDS:-300}"
BACKGROUND_VOLUME="${BACKGROUND_VOLUME:-0.12}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

usage() {
  cat <<'EOF'
DubWave — command-line video translation and dubbing

Usage:
  ./dubwave.sh check
  ./dubwave.sh translate INPUT_VIDEO OUTPUT_VIDEO TARGET_LANGUAGE

Examples:
  ./dubwave.sh check
  ./dubwave.sh translate ./input.mp4 ./output.mp4 Spanish
  ./dubwave.sh translate ./input.mov ./output.mp4 "Brazilian Portuguese"

Configuration:
  Copy .env.example to .env and add API keys.
  Audio transcription and speech generation require audio API endpoints.
  Translation uses a chat-completions-compatible text API.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local command_name
  for command_name in curl jq ffmpeg ffprobe awk; do
    command -v "$command_name" >/dev/null 2>&1 ||
      fail "Required command not found: $command_name"
  done
}

check_configuration() {
  require_commands

  [[ -n "$AUDIO_API_KEY" ]] ||
    fail "Set AUDIO_API_KEY or OPENAI_API_KEY in .env."
  [[ -n "$TEXT_API_KEY" ]] ||
    fail "Set TEXT_API_KEY or OPENAI_API_KEY in .env."
  [[ "$CHUNK_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    fail "CHUNK_SECONDS must be a positive integer."
  awk -v value="$BACKGROUND_VOLUME" \
    'BEGIN { exit !(value >= 0 && value <= 1) }' ||
    fail "BACKGROUND_VOLUME must be between 0 and 1."

  printf '%s\n' "Dependencies and configuration look ready."
}

api_url() {
  local base="${1%/}"
  local endpoint="$2"
  printf '%s/%s\n' "$base" "$endpoint"
}

srt_timestamp() {
  awk -v seconds="$1" 'BEGIN {
    milliseconds = int(seconds * 1000 + 0.5)
    hours = int(milliseconds / 3600000)
    milliseconds -= hours * 3600000
    minutes = int(milliseconds / 60000)
    milliseconds -= minutes * 60000
    whole_seconds = int(milliseconds / 1000)
    milliseconds -= whole_seconds * 1000
    printf "%02d:%02d:%02d,%03d", hours, minutes, whole_seconds, milliseconds
  }'
}

transcribe_chunk() {
  local input_file="$1"
  local output_file="$2"

  curl --fail --silent --show-error \
    --connect-timeout 20 \
    --max-time 600 \
    "$(api_url "$AUDIO_API_BASE" "audio/transcriptions")" \
    -H "Authorization: Bearer $AUDIO_API_KEY" \
    -F "file=@${input_file}" \
    -F "model=${TRANSCRIPTION_MODEL}" \
    -F "response_format=verbose_json" \
    > "$output_file"
}

translate_segments() {
  local source_json="$1"
  local target_language="$2"
  local request_file="$3"
  local response_file="$4"
  local result_file="$5"

  jq -n \
    --arg model "$TRANSLATION_MODEL" \
    --arg language "$target_language" \
    --argjson segments "$source_json" \
    '{
      model: $model,
      temperature: 0.2,
      response_format: {type: "json_object"},
      messages: [
        {
          role: "system",
          content: (
            "Translate each supplied video transcript segment into " +
            $language +
            ". Preserve meaning, tone, names, and segment order. " +
            "Return only a JSON object shaped like " +
            "{\"segments\":[{\"id\":0,\"text\":\"translated text\"}]}. " +
            "Keep every segment ID unchanged. Do not add or remove segments."
          )
        },
        {
          role: "user",
          content: ("Translate these segments: " + ($segments | tojson))
        }
      ]
    }' > "$request_file"

  curl --fail --silent --show-error \
    --connect-timeout 20 \
    --max-time 300 \
    "$(api_url "$TEXT_API_BASE" "chat/completions")" \
    -H "Authorization: Bearer $TEXT_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$request_file" \
    > "$response_file"

  jq -er '.choices[0].message.content | fromjson | .segments' \
    "$response_file" > "$result_file" ||
    fail "The translation API did not return the expected JSON response."
}

generate_speech() {
  local text="$1"
  local output_file="$2"
  local request_file="$3"

  jq -n \
    --arg model "$TTS_MODEL" \
    --arg voice "$TTS_VOICE" \
    --arg input "$text" \
    '{
      model: $model,
      voice: $voice,
      input: $input,
      response_format: "mp3"
    }' > "$request_file"

  curl --fail --silent --show-error \
    --connect-timeout 20 \
    --max-time 300 \
    "$(api_url "$AUDIO_API_BASE" "audio/speech")" \
    -H "Authorization: Bearer $AUDIO_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$request_file" \
    --output "$output_file"
}

translate_video() {
  local input_video="$1"
  local output_video="$2"
  local target_language="$3"

  [[ -f "$input_video" ]] || fail "Input video not found: $input_video"
  [[ "$input_video" != "$output_video" ]] ||
    fail "Input and output paths must be different."

  check_configuration

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dubwave.XXXXXX")"
  trap 'rm -rf "$work_dir"' EXIT

  local source_audio="$work_dir/source.wav"
  local chunks_dir="$work_dir/chunks"
  local records_file="$work_dir/transcript.ndjson"
  local segments_json="$work_dir/segments.json"
  local translated_file="$work_dir/translated.json"
  local subtitle_file="${output_video%.*}.srt"

  mkdir -p "$chunks_dir"
  : > "$records_file"

  printf 'Extracting audio...\n'
  ffmpeg -hide_banner -loglevel error -y \
    -i "$input_video" \
    -vn -ac 1 -ar 16000 -c:a pcm_s16le \
    "$source_audio" ||
    fail "Could not extract audio. Check that the video has an audio track."

  printf 'Splitting audio into %s-second chunks...\n' "$CHUNK_SECONDS"
  ffmpeg -hide_banner -loglevel error -y \
    -i "$source_audio" \
    -f segment \
    -segment_time "$CHUNK_SECONDS" \
    -reset_timestamps 1 \
    -c:a pcm_s16le \
    "$chunks_dir/chunk_%04d.wav"

  shopt -s nullglob
  local chunks=("$chunks_dir"/chunk_*.wav)
  shopt -u nullglob
  ((${#chunks[@]} > 0)) || fail "No audio chunks were created."

  printf 'Transcribing %s chunk(s)...\n' "${#chunks[@]}"
  local index=0
  local chunk response offset
  for chunk in "${chunks[@]}"; do
    response="$work_dir/transcription_${index}.json"
    offset=$((index * CHUNK_SECONDS))

    transcribe_chunk "$chunk" "$response" ||
      fail "Transcription failed for chunk $((index + 1))."

    jq -c --argjson offset "$offset" \
      '.segments[]? | {
        start: (.start + $offset),
        end: (.end + $offset),
        text: .text
      }' "$response" >> "$records_file" ||
      fail "Could not read transcription segments."

    index=$((index + 1))
  done

  jq -s '.' "$records_file" > "$segments_json"
  local segment_count
  segment_count="$(jq 'length' "$segments_json")"
  ((segment_count > 0)) || fail "The transcription returned no speech segments."

  printf 'Translating %s segment(s) into %s...\n' \
    "$segment_count" "$target_language"
  translate_segments \
    "$(cat "$segments_json")" \
    "$target_language" \
    "$work_dir/translation_request.json" \
    "$work_dir/translation_response.json" \
    "$translated_file"

  [[ "$(jq 'length' "$translated_file")" -eq "$segment_count" ]] ||
    fail "Translation returned a different number of segments than transcription."

  printf 'Generating speech and subtitles...\n'
  : > "$subtitle_file"

  local speech_dir="$work_dir/speech"
  mkdir -p "$speech_dir"

  local i translated_text start end start_ms
  for ((i = 0; i < segment_count; i++)); do
    translated_text="$(jq -er ".[$i].text" "$translated_file")"
    start="$(jq -er ".[$i].start" "$segments_json")"
    end="$(jq -er ".[$i].end" "$segments_json")"

    [[ -n "$translated_text" ]] || fail "Translation contains an empty segment."

    printf '%s\n%s --> %s\n%s\n\n' \
      "$((i + 1))" \
      "$(srt_timestamp "$start")" \
      "$(srt_timestamp "$end")" \
      "$translated_text" >> "$subtitle_file"

    generate_speech \
      "$translated_text" \
      "$speech_dir/voice_$(printf '%04d' "$i").mp3" \
      "$work_dir/tts_request.json" ||
      fail "Speech generation failed for segment $((i + 1))."
  done

  printf 'Mixing dubbed audio and rendering video...\n'
  local -a ffmpeg_args
  ffmpeg_args=(-hide_banner -loglevel error -y -i "$source_audio")

  for ((i = 0; i < segment_count; i++)); do
    ffmpeg_args+=(-i "$speech_dir/voice_$(printf '%04d' "$i").mp3")
  done

  local filter_graph=""
  local delayed_labels=""
  local delay_ms label

  for ((i = 0; i < segment_count; i++)); do
    start="$(jq -er ".[$i].start" "$segments_json")"
    delay_ms="$(awk -v value="$start" 'BEGIN { printf "%.0f", value * 1000 }')"
    label="voice$i"

    filter_graph+="[$((i + 1)):a]adelay=${delay_ms}|${delay_ms}[${label}];"
    delayed_labels+="[${label}]"
  done

  filter_graph+="${delayed_labels}amix=inputs=${segment_count}:duration=longest:normalize=0[dubbed];"
  filter_graph+="[0:a]volume=${BACKGROUND_VOLUME}[background];"
  filter_graph+="[dubbed][background]amix=inputs=2:duration=longest:normalize=0[mixed]"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$input_video" \
    "${ffmpeg_args[@]:2}" \
    -filter_complex "$filter_graph" \
    -map 0:v:0 \
    -map '[mixed]' \
    -c:v copy \
    -c:a aac \
    -b:a 192k \
    -shortest \
    "$output_video" ||
    fail "FFmpeg could not render the dubbed video."

  printf 'Done.\nVideo: %s\nSubtitles: %s\n' "$output_video" "$subtitle_file"
}

main() {
  local command="${1:-}"
  case "$command" in
    check)
      check_configuration
      ;;
    translate)
      [[ $# -eq 4 ]] || {
        usage >&2
        exit 2
      }
      translate_video "$2" "$3" "$4"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      usage >&2
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"