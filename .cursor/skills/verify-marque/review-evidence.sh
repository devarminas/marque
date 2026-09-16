#!/usr/bin/env bash
#
# Capture and attach reviewer-facing media for a Marque PR.
#
# Complementary to DEMO+GAMELOG proof. A PNG or video that merely exists is
# never a behavioural pass (ARM-289). This helper only produces and surfaces
# human-visible artifacts so a reviewer does not have to launch the client.
#
# Not a windowed demo: doctor does not scan this file.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  review-evidence.sh capture-screenshot [--out PATH] [--attach] [--pr NUMBER|auto] [--caption TEXT]
  review-evidence.sh capture-frames [--out-prefix PATH] [--count N] [--interval-ms MS]
                                    [--mp4] [--gif] [--attach] [--pr NUMBER|auto] [--caption TEXT]
  review-evidence.sh stitch --prefix PATH [--mp4] [--gif]
  review-evidence.sh attach --files FILE [FILE ...] [--pr NUMBER|auto] [--caption TEXT] [--kind KIND]
                            [--stage-repo RELPATH]

Commands:
  capture-screenshot  Windowed --screenshot (optional absolute --out).
  capture-frames      Windowed --record-frames strip; optionally stitch mp4/gif.
  stitch              ffmpeg a prefix_1.png.. strip into mp4 and/or gif.
  attach              gh pr comment --attach (max 3 files), or --stage-repo fallback.

Kind heuristic (documentation, passed through --kind or inferred):
  screenshot  static layout/chrome at rest
  video       timing, motion, hover, mode chrome
  none        do not run this helper (pure DEMO+GAMELOG / Go / headless)

Markers (must be the last line; require exit 0 as well):
  REVIEW CAPTURE OK
  REVIEW STITCH OK
  REVIEW ATTACH OK

Environment:
  GODOT     Godot 4.7 executable (default: godot)
  DISPLAY   X11 display. Unset DISPLAY uses :1 when /tmp/.X11-unix/X1 exists.
  TMPDIR    Staging root (default: /tmp)
EOF
}

die() {
  echo "review-evidence: $*" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
GODOT="${GODOT:-godot}"
STAGING="${TMPDIR:-/tmp}/marque-review-evidence"
KIND=""
CAPTION=""
PR_SPEC=""
DO_ATTACH=0
DO_MP4=0
DO_GIF=0
OUT=""
OUT_PREFIX=""
STAGE_REPO=""
COUNT=16
INTERVAL_MS=100
FILES=()

ensure_display() {
  if [ -n "${DISPLAY:-}" ]; then
    return 0
  fi
  if [ -S /tmp/.X11-unix/X1 ]; then
    export DISPLAY=:1
    echo "review-evidence: DISPLAY unset; using :1"
    return 0
  fi
  die "no DISPLAY. Windowed self-capture needs a real X session (headless cannot produce reviewer pixels)."
}

ensure_godot() {
  command -v "$GODOT" >/dev/null 2>&1 || die "godot is not answering (set GODOT or put godot on PATH)"
}

ensure_repo_layout() {
  [ -f "$ROOT_DIR/client/project.godot" ] || die "not a Marque checkout (missing client/project.godot)"
  [ -f "$ROOT_DIR/client/scripts/main.gd" ] || die "missing client/scripts/main.gd"
}

warm_godot_cache() {
  if [ -d "$ROOT_DIR/client/.godot" ]; then
    return 0
  fi
  echo "review-evidence: warming client/.godot"
  "$GODOT" --headless --path "$ROOT_DIR/client" --editor --quit >/dev/null 2>&1 || true
}

mkdir_parent() {
  mkdir -p "$(dirname "$1")"
}

parse_common() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) OUT="${2:-}"; shift 2 ;;
      --out-prefix) OUT_PREFIX="${2:-}"; shift 2 ;;
      --prefix) OUT_PREFIX="${2:-}"; shift 2 ;;
      --count) COUNT="${2:-}"; shift 2 ;;
      --interval-ms) INTERVAL_MS="${2:-}"; shift 2 ;;
      --caption) CAPTION="${2:-}"; shift 2 ;;
      --kind) KIND="${2:-}"; shift 2 ;;
      --pr) PR_SPEC="${2:-}"; shift 2 ;;
      --stage-repo) STAGE_REPO="${2:-}"; shift 2 ;;
      --files)
        shift
        while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
          FILES+=("$1")
          shift
        done
        ;;
      --attach) DO_ATTACH=1; shift ;;
      --mp4) DO_MP4=1; shift ;;
      --gif) DO_GIF=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

run_windowed_godot() {
  ensure_display
  ensure_godot
  ensure_repo_layout
  warm_godot_cache
  # Bound runaway loops. 3600 frames is a minute at 60 Hz; capture paths quit sooner.
  "$GODOT" --path "$ROOT_DIR/client" --audio-driver Dummy --quit-after 3600 "$@"
}

resolve_pr() {
  local spec="${1:-auto}"
  if [ "$spec" = "auto" ] || [ -z "$spec" ]; then
    gh pr view --json number --jq .number 2>/dev/null || die "no open PR for this branch (pass --pr NUMBER)"
    return 0
  fi
  echo "$spec"
}

attach_files() {
  local caption kind body dest branch pr
  caption="${CAPTION:-Reviewer-facing visual evidence}"
  kind="${KIND:-screenshot}"
  if [ "${#FILES[@]}" -eq 0 ]; then
    die "attach needs --files"
  fi
  if [ "${#FILES[@]}" -gt 3 ]; then
    echo "review-evidence: taking the first 3 of ${#FILES[@]} files (skill cap)"
    FILES=("${FILES[@]:0:3}")
  fi
  local f attach_args=() ext
  for f in "${FILES[@]}"; do
    [ -f "$f" ] || die "missing artifact: $f"
    ext="${f##*.}"
    case "$ext" in
      mp4|webm|mov|avi|MP4|WEBM|MOV|AVI)
        attach_args+=(--attach "$f")
        ;;
      *)
        attach_args+=(--attach "$f#${caption}")
        ;;
    esac
  done
  body="$(cat <<EOF
**Reviewer evidence** (human-visible; **not** a behavioural pass).

- Kind: \`${kind}\`
- ${caption}
- DEMO+GAMELOG (or Go / headless) still gate. PNG/video presence is never proof (ARM-289).
EOF
)"

  if [ -n "$STAGE_REPO" ]; then
    case "$STAGE_REPO" in
      /*) dest="$STAGE_REPO" ;;
      *) dest="$ROOT_DIR/$STAGE_REPO" ;;
    esac
    mkdir -p "$dest"
    for f in "${FILES[@]}"; do
      cp -f "$f" "$dest/$(basename "$f")"
      echo "review-evidence: staged $dest/$(basename "$f")"
    done
  fi

  pr=""
  if command -v gh >/dev/null 2>&1; then
    pr="$(gh pr view --json number --jq .number 2>/dev/null || true)"
    if [ -n "${PR_SPEC:-}" ] && [ "$PR_SPEC" != "auto" ]; then
      pr="$PR_SPEC"
    fi
    if [ -n "$pr" ]; then
      if gh pr comment "$pr" --body "$body" "${attach_args[@]}"; then
        echo "REVIEW ATTACH OK"
        return 0
      fi
      echo "review-evidence: gh pr comment --attach failed (installation tokens often cannot upload assets)."
    else
      echo "review-evidence: no open PR for this branch (pass --pr NUMBER, or rely on --stage-repo)."
    fi
  fi

  if [ -n "$STAGE_REPO" ]; then
    branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
    echo "review-evidence: commit the staged files and put blob/${branch}/…?raw=true links in the PR body."
    echo "REVIEW STAGE OK"
    return 0
  fi
  die "attach failed and no --stage-repo fallback"
}

stitch_prefix() {
  local prefix="$1"
  [ -n "$prefix" ] || die "stitch needs --prefix"
  [ -f "${prefix}_1.png" ] || die "no ${prefix}_1.png to stitch"
  if [ "$DO_MP4" -eq 0 ] && [ "$DO_GIF" -eq 0 ]; then
    DO_MP4=1
  fi
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required to stitch frames (not installed)"
  local vf="scale=trunc(iw/2)*2:trunc(ih/2)*2"
  if [ "$DO_MP4" -eq 1 ]; then
    ffmpeg -y -loglevel error -framerate 12 -start_number 1 -i "${prefix}_%d.png" \
      -vf "$vf" -c:v libx264 -pix_fmt yuv420p "${prefix}.mp4"
    echo "review-evidence: wrote ${prefix}.mp4"
  fi
  if [ "$DO_GIF" -eq 1 ]; then
    ffmpeg -y -loglevel error -framerate 12 -start_number 1 -i "${prefix}_%d.png" \
      -vf "$vf" "${prefix}.gif"
    echo "review-evidence: wrote ${prefix}.gif"
  fi
  echo "REVIEW STITCH OK"
}

cmd="${1:-}"
if [ -z "$cmd" ] || [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ]; then
  usage
  exit 0
fi
shift

case "$cmd" in
  capture-screenshot)
    parse_common "$@"
    mkdir -p "$STAGING"
    if [ -z "$OUT" ]; then
      OUT="$STAGING/baseline.png"
    fi
    case "$OUT" in
      /*) ;;
      *) die "--out must be an absolute path, got $OUT" ;;
    esac
    mkdir_parent "$OUT"
    KIND="${KIND:-screenshot}"
    run_windowed_godot -- --screenshot "$OUT"
    [ -f "$OUT" ] || die "capture wrote no file at $OUT"
    echo "review-evidence: $OUT"
    echo "REVIEW CAPTURE OK"
    if [ "$DO_ATTACH" -eq 1 ]; then
      FILES=("$OUT")
      attach_files
    fi
    ;;
  capture-frames)
    parse_common "$@"
    mkdir -p "$STAGING"
    if [ -z "$OUT_PREFIX" ]; then
      OUT_PREFIX="$STAGING/frames"
    fi
    case "$OUT_PREFIX" in
      /*) ;;
      *) die "--out-prefix must be an absolute path, got $OUT_PREFIX" ;;
    esac
    mkdir_parent "${OUT_PREFIX}_1.png"
    KIND="${KIND:-video}"
    run_windowed_godot -- --record-frames "$OUT_PREFIX" --record-count "$COUNT" \
      --record-interval-ms "$INTERVAL_MS"
    [ -f "${OUT_PREFIX}_1.png" ] || die "capture wrote no ${OUT_PREFIX}_1.png"
    echo "REVIEW CAPTURE OK"
    if [ "$DO_MP4" -eq 1 ] || [ "$DO_GIF" -eq 1 ]; then
      stitch_prefix "$OUT_PREFIX"
    fi
    if [ "$DO_ATTACH" -eq 1 ]; then
      FILES=()
      if [ -f "${OUT_PREFIX}.mp4" ]; then
        FILES+=("${OUT_PREFIX}.mp4")
      elif [ -f "${OUT_PREFIX}.gif" ]; then
        FILES+=("${OUT_PREFIX}.gif")
      else
        FILES+=("${OUT_PREFIX}_1.png")
        if [ -f "${OUT_PREFIX}_2.png" ]; then
          FILES+=("${OUT_PREFIX}_2.png")
        fi
        last="${OUT_PREFIX}_${COUNT}.png"
        if [ -f "$last" ] && [ "$last" != "${OUT_PREFIX}_1.png" ] && [ "$last" != "${OUT_PREFIX}_2.png" ]; then
          FILES+=("$last")
        fi
      fi
      attach_files
    fi
    ;;
  stitch)
    parse_common "$@"
    stitch_prefix "$OUT_PREFIX"
    ;;
  attach)
    parse_common "$@"
    attach_files
    ;;
  *)
    usage >&2
    die "unknown command: $cmd"
    ;;
esac
