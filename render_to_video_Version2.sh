#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --dir DIR         Directory with frames (default: project/renders)
  --fps N           Framerate (default: 30)
  --out FILE        Output file path (default: <dir>/video_<fps>fps.mp4)
  --audio FILE      Optional audio file to mux (mp3/m4a/wav)
  --dry-run         Print the ffmpeg command but do not execute
  --hw MODE         Hardware accel: auto|nvenc|vaapi|none (default: auto)
  --bitrate B       Force video bitrate (e.g. 2500k or 3M). Overrides auto bitrate.
  --auto-bitrate    Enable automatic bitrate estimation (default)
  --max-width N     Maximum output width (will scale down if needed)
  --max-height N    Maximum output height (will scale down if needed)
  -h, --help        Show this message
USAGE
  exit "${1:-0}"
}

# defaults
RENDER_DIR="project/renders"
FPS=30
OUT_FILE=""
AUDIO=""
DRY_RUN=0
HW_MODE="auto"
FORCE_BITRATE=""
AUTO_BITRATE=1
MAX_W=""
MAX_H=""

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) RENDER_DIR="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --audio) AUDIO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --hw) HW_MODE="$2"; shift 2 ;;
    --bitrate) FORCE_BITRATE="$2"; AUTO_BITRATE=0; shift 2 ;;
    --auto-bitrate) AUTO_BITRATE=1; shift ;;
    --max-width) MAX_W="$2"; shift 2 ;;
    --max-height) MAX_H="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

# basic deps
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found in PATH. Install ffmpeg and retry." >&2
  exit 2
fi

if [[ ! -d "$RENDER_DIR" ]]; then
  echo "Error: render directory not found: $RENDER_DIR" >&2
  exit 3
fi

# collect files safely
declare -a files
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "$RENDER_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "Error: no image frames found in $RENDER_DIR" >&2
  exit 4
fi

# predictable sort
LC_ALL=C
if command -v sort >/dev/null 2>&1 && sort --version >/dev/null 2>&1; then
  IFS=$'\n' read -r -d '' -a files < <(printf '%s\n' "${files[@]}" | sort -V && printf '\0')
else
  IFS=$'\n' read -r -d '' -a files < <(printf '%s\n' "${files[@]}" | sort && printf '\0')
fi

# Choose output file if not given
if [[ -z "$OUT_FILE" ]]; then
  OUT_FILE="${RENDER_DIR%/}/video_${FPS}fps.mp4"
fi

# escape regex metachars for use in =~
escape_for_regex() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//./\\.}"
  s="${s//^/\\^}"
  s="${s//\$/\\$}"
  s="${s//\*/\\*}"
  s="${s//+/\\+}"
  s="${s//\?/\\?}"
  s="${s//\(/\\(}"
  s="${s//\)/\\)}"
  s="${s//\[/\\[}"
  s="${s//\]/\\]}"
  s="${s//\{/\\{}"
  s="${s//\}/\\}}"
  s="${s//|/\\|}"
  s="${s//-/\\-}"
  printf '%s' "$s"
}

# detect numeric sequence pattern
pattern=""
start_number=""
pad=0
prefix=""
suffix=""
DETECTED=""
for f in "${files[@]}"; do
  name="$(basename "$f")"
  if [[ "$name" =~ ^(.*?)([0-9]+)(\.[^.]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[2]}"
    suffix="${BASH_REMATCH[3]}"
    pad="${#num}"
    pattern="${prefix}%0${pad}d${suffix}"
    first_with_digits="$name"
    DETECTED="numeric"
    break
  fi
done

INPUT_ARGS=()
if [[ "$DETECTED" == "numeric" ]]; then
  esc_prefix="$(escape_for_regex "$prefix")"
  esc_suffix="$(escape_for_regex "$suffix")"
  nums=()
  for f in "${files[@]}"; do
    n="$(basename "$f")"
    if [[ "$n" =~ ^${esc_prefix}([0-9]+)${esc_suffix}$ ]]; then
      nums+=("${BASH_REMATCH[1]}")
    fi
  done
  if [[ ${#nums[@]} -gt 0 ]]; then
    min="${nums[0]}"
    for v in "${nums[@]}"; do
      if ((10#$v < 10#$min)); then min="$v"; fi
    done
    start_number="$((10#$min))"
    INPUT_ARGS+=(-start_number "${start_number}" -i "${RENDER_DIR%/}/${pattern}")
  else
    DETECTED="glob"
  fi
fi

if [[ -z "${INPUT_ARGS[*]:-}" ]]; then
  if compgen -G "${RENDER_DIR%/}/*.png" >/dev/null; then
    INPUT_ARGS+=(-pattern_type glob -i "${RENDER_DIR%/}/*.png")
    DETECTED="glob"
  elif compgen -G "${RENDER_DIR%/}/*.jpg" >/dev/null; then
    INPUT_ARGS+=(-pattern_type glob -i "${RENDER_DIR%/}/*.jpg")
    DETECTED="glob"
  else
    INPUT_ARGS+=(-pattern_type glob -i "${RENDER_DIR%/}/*.jpeg")
    DETECTED="glob"
  fi
fi

# helper: try to detect hardware encoders available via ffmpeg -encoders
detect_hw_encoder() {
  local want="$1" # nvenc/vaapi
  if [[ "$want" == "nvenc" ]]; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'h264_nvenc|hevc_nvenc' >/dev/null 2>&1; then
      echo "h264_nvenc"
      return 0
    fi
  elif [[ "$want" == "vaapi" ]]; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'h264_vaapi|hevc_vaapi' >/dev/null 2>&1; then
      echo "h264_vaapi"
      return 0
    fi
  fi
  return 1
}

HW_ENCODER=""
if [[ "$HW_MODE" == "auto" ]]; then
  # prefer NVENC then VAAPI then none
  if detect_hw_encoder nvenc >/dev/null 2>&1; then
    HW_ENCODER="$(detect_hw_encoder nvenc)"
  elif detect_hw_encoder vaapi >/dev/null 2>&1; then
    HW_ENCODER="$(detect_hw_encoder vaapi)"
  else
    HW_ENCODER=""
  fi
elif [[ "$HW_MODE" == "nvenc" ]]; then
  HW_ENCODER="$(detect_hw_encoder nvenc || true)"
elif [[ "$HW_MODE" == "vaapi" ]]; then
  HW_ENCODER="$(detect_hw_encoder vaapi || true)"
elif [[ "$HW_MODE" == "none" ]]; then
  HW_ENCODER=""
else
  echo "Unknown --hw mode: $HW_MODE" >&2
  exit 1
fi

if [[ -n "$HW_ENCODER" ]]; then
  echo "Using hardware encoder: $HW_ENCODER"
else
  if [[ "$HW_MODE" != "none" ]]; then
    echo "No supported hardware encoder detected or chosen; falling back to libx264"
  fi
fi

# try to detect resolution of first frame (identify -> ffprobe fallback)
FIRST_FILE="${files[0]}"
FRAME_W=""
FRAME_H=""
if command -v identify >/dev/null 2>&1; then
  if identify_output="$(identify -format "%w %h" "$FIRST_FILE" 2>/dev/null || true)"; then
    read -r FRAME_W FRAME_H <<<"$identify_output"
  fi
fi
if [[ -z "$FRAME_W" || -z "$FRAME_H" ]]; then
  if command -v ffprobe >/dev/null 2>&1; then
    if ffprobe_out="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$FIRST_FILE" 2>/dev/null || true)"; then
      if [[ "$ffprobe_out" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        FRAME_W="${BASH_REMATCH[1]}"
        FRAME_H="${BASH_REMATCH[2]}"
      fi
    fi
  fi
fi

# automatic bitrate estimation (kbps) if requested and resolution available
AUTO_BITRATE_VAL=""
if [[ $AUTO_BITRATE -eq 1 && -n "$FRAME_W" && -n "$FRAME_H" && -z "$FORCE_BITRATE" ]]; then
  # heuristic: kbps = clamp((w*h*fps)/1200, 800, 8000)
  est_kbps=$(( (FRAME_W * FRAME_H * FPS) / 1200 ))
  if (( est_kbps < 800 )); then est_kbps=800; fi
  if (( est_kbps > 8000 )); then est_kbps=8000; fi
  AUTO_BITRATE_VAL="${est_kbps}k"
  echo "Auto bitrate estimate: ${AUTO_BITRATE_VAL} (from ${FRAME_W}x${FRAME_H}@${FPS}fps)"
fi

# scale filter if max dims provided
SCALE_FILTER=""
if [[ -n "$MAX_W" || -n "$MAX_H" ]]; then
  # default to a large number if only one provided
  if [[ -z "$MAX_W" ]]; then MAX_W=99999; fi
  if [[ -z "$MAX_H" ]]; then MAX_H=99999; fi
  # scale preserving aspect ratio and preventing upscaling
  # force_original_aspect_ratio=decrease keeps aspect ratio; we then pad is omitted to avoid forcing exact dims
  SCALE_FILTER="scale='if(gt(iw,${MAX_W}),${MAX_W},iw)':'if(gt(ih,${MAX_H}),${MAX_H},ih)':force_original_aspect_ratio=decrease"
fi

# build ffmpeg command
FFMPEG_CMD=(ffmpeg -y -framerate "${FPS}")
FFMPEG_CMD+=("${INPUT_ARGS[@]}")

# optional audio
if [[ -n "$AUDIO" ]]; then
  FFMPEG_CMD+=(-i "$AUDIO")
fi

# codec selection
if [[ -n "$HW_ENCODER" ]]; then
  # pick hw encoder (only h264 for now)
  if [[ "$HW_ENCODER" == "h264_nvenc" ]]; then
    # NVENC settings (reasonable defaults)
    VIDEO_CODEC_ARGS=(-c:v h264_nvenc -preset p4)
    # if we have a bitrate target, we'll use vbr_hq, else use constqp-ish (let ffmpeg choose)
    if [[ -n "$FORCE_BITRATE" || -n "$AUTO_BITRATE_VAL" ]]; then
      VIDEO_CODEC_ARGS+=(-rc vbr_hq)
    fi
  elif [[ "$HW_ENCODER" == "h264_vaapi" ]]; then
    VIDEO_CODEC_ARGS=(-vaapi_device /dev/dri/renderD128 -c:v h264_vaapi)
    # VAAPI usually prefers -b:v target
  else
    # fallback, but shouldn't happen
    VIDEO_CODEC_ARGS=(-c:v libx264)
  fi
else
  VIDEO_CODEC_ARGS=(-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p)
fi

# bitrate handling
if [[ -n "$FORCE_BITRATE" ]]; then
  # use constant target bitrate with sane buffers
  VIDEO_CODEC_ARGS+=(-b:v "${FORCE_BITRATE}" -maxrate "${FORCE_BITRATE}" -bufsize "$(printf '%dk' $(( ${FORCE_BITRATE%k:-0} * 2 )))")
elif [[ -n "$AUTO_BITRATE_VAL" ]]; then
  # if using hw encoder, prefer vbr style flags, else set -b:v
  VIDEO_CODEC_ARGS+=(-b:v "${AUTO_BITRATE_VAL}" -maxrate "${AUTO_BITRATE_VAL}" -bufsize "$(( ${AUTO_BITRATE_VAL%k} * 2 ))k")
fi

# filters
FILTERS=()
if [[ -n "$SCALE_FILTER" ]]; then
  FILTERS+=("$SCALE_FILTER")
fi

# append filters if any
if [[ ${#FILTERS[@]} -gt 0 ]]; then
  FFMPEG_CMD+=(-vf "$(IFS=,; echo "${FILTERS[*]}")")
fi

# movflags for web streaming and finalize output args
if [[ -n "$AUDIO" ]]; then
  FFMPEG_CMD+=("${VIDEO_CODEC_ARGS[@]}" -c:a aac -b:a 192k -movflags +faststart -shortest "$OUT_FILE")
else
  FFMPEG_CMD+=("${VIDEO_CODEC_ARGS[@]}" -movflags +faststart "$OUT_FILE")
fi

# show plan
echo "Found ${#files[@]} frames in: $RENDER_DIR"
echo "Detection method: ${DETECTED:-unknown}"
if [[ "$DETECTED" == "numeric" ]]; then
  echo "Numeric pattern: ${pattern} (start=${start_number}, pad=${pad})"
else
  echo "Using glob input (pattern_type glob)"
fi
echo
echo "ffmpeg command:"
for arg in "${FFMPEG_CMD[@]}"; do
  printf "%q " "$arg"
done
echo
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run requested; not executing ffmpeg."
  exit 0
fi

# execute
"${FFMPEG_CMD[@]}"
echo "Done. Output: $OUT_FILE"