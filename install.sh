#!/usr/bin/env bash
# One-command installer for RST Elastic AI Copilot.
#
#   curl -fsSL https://github.com/reallysec/RST-Elastic-AI-Copilot/releases/latest/download/install.sh | sudo bash
#
# Options: --version <x.y.z> (default: latest)   --dir <path> (default below)
#          --mirror github|cn   github: GitHub Releases only; cn: China mirror (Tencent COS) first,
#                               GitHub second. Default: GitHub first, the China mirror when it fails.
#                               Same as env RST_MIRROR=github|cn.
#          --download-only   verify and save the archive in the current directory, deploy nothing
#                            (carry it to an air-gapped host and run deploy.sh there)
#
# Every edition is the same archive: without a license it runs as the Community Edition;
# importing a license in Settings -> License unlocks Professional or Enterprise in place.
# Downloads the delivery archive and its .sha256, verifies it, unpacks it into one fixed
# directory and runs deploy.sh there. Re-running it (a newer version) keeps .env and
# state/machine-id in that directory, so data and the host fingerprint are kept.
set -euo pipefail

PRODUCT="RST Elastic AI Copilot"
STEM="RST-Elastic-AI-Copilot"                     # archive: <STEM>-<version>.tar.gz
GH_REPO="reallysec/RST-Elastic-AI-Copilot"
DIR="/opt/rst-elastic-ai-copilot"
# China mirror (Tencent COS): <base>/rst-elastic-ai-copilot/<version>/<file> and .../latest/VERSION.
# The bucket does not exist yet — this default is a PLACEHOLDER. Until it is replaced (or
# RST_COS_BASE is set) the mirror is skipped instead of trying a bogus host.
COS_PLACEHOLDER="https://rst-releases-XXXXXXXX.cos.ap-shanghai.myqcloud.com"
COS_BASE="${RST_COS_BASE:-$COS_PLACEHOLDER}"
COS_PREFIX="rst-elastic-ai-copilot"

VERSION=""; DOWNLOAD_ONLY=0; MIRROR="${RST_MIRROR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --version) VERSION="${2#v}"; shift 2 ;;
    --dir)     DIR="${2:?}"; shift 2 ;;
    --mirror)  MIRROR="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$MIRROR" in
  "")     ORDER="github cn" ;;
  github) ORDER="github" ;;
  cn)     ORDER="cn github" ;;
  *) fail "--mirror must be github or cn" ;;
esac

# ── preflight ────────────────────────────────────────────────────────────────
for c in curl tar sha256sum; do command -v "$c" >/dev/null || fail "missing command: $c"; done
if [ "$DOWNLOAD_ONLY" = 0 ]; then
  [ "$(uname -s)" = Linux ] || fail "Linux only."
  [ "$(id -u)" = 0 ] || fail "run as root: pipe to 'sudo bash'."
  command -v docker >/dev/null || fail "Docker Engine 24+ is required. Install it first, e.g.: curl -fsSL https://get.docker.com | sh"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (the docker compose plugin)."
  [ -r /dev/tty ] || fail "deploy.sh asks questions; run this from an interactive terminal."
fi

# A stalled GitHub download (common from mainland China) counts as a failure: give up
# below 10 KB/s for 30 s so the mirror gets its turn.
CURL=(curl -fL --retry 2 --connect-timeout 15 --speed-limit 10240 --speed-time 30)

# Latest version from the /releases/latest redirect (no API call, no rate limit).
github_latest() {
  local u; u="$("${CURL[@]}" -sS -o /dev/null -w '%{url_effective}' "https://github.com/$GH_REPO/releases/latest")" || return 1
  u="${u##*/}"
  case "$u" in v[0-9]*) printf '%s' "${u#v}" ;; *) return 1 ;; esac
}
cos_latest() { "${CURL[@]}" -sS "$COS_BASE/$COS_PREFIX/latest/VERSION" | tr -d ' \r\n'; }

# Download + verify from one source into the current directory. Returns non-zero
# (never exits) so the caller can try the next source.
get_from() {  # github|cn
  local v="$VERSION" base
  case "$1" in
    github) [ -n "$v" ] || v="$(github_latest)" || return 1
            base="https://github.com/$GH_REPO/releases/download/v$v" ;;
    cn)     if [ "$COS_BASE" = "$COS_PLACEHOLDER" ]; then
              say "== China mirror not configured yet (set RST_COS_BASE); skipping it"; return 1
            fi
            [ -n "$v" ] || v="$(cos_latest)" || return 1
            base="$COS_BASE/$COS_PREFIX/$v" ;;
  esac
  [ -n "$v" ] || return 1
  ARCHIVE="$STEM-$v.tar.gz"
  say "== $PRODUCT $v: downloading from $base"
  if "${CURL[@]}" -o "$ARCHIVE.sha256" "$base/$ARCHIVE.sha256" \
     && "${CURL[@]}" -o "$ARCHIVE" "$base/$ARCHIVE" \
     && sha256sum -c "$ARCHIVE.sha256"; then
    VERSION="$v"; return 0
  fi
  rm -f "$ARCHIVE" "$ARCHIVE.sha256"; return 1
}
fetch_bundle() {
  local s
  for s in $ORDER; do
    get_from "$s" && return 0
    say "== download from $s failed"
  done
  fail "could not download and verify the archive (tried: $ORDER). Check the version and the network."
}

if [ "$DOWNLOAD_ONLY" = 1 ]; then
  fetch_bundle
  say "== saved $PWD/$ARCHIVE; on the target host: tar xzf $ARCHIVE && cd $STEM-$VERSION && ./deploy.sh"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
fetch_bundle
say "== $PRODUCT $VERSION -> $DIR"

# ── unpack into the fixed directory ──────────────────────────────────────────
# The archive carries no .env and no state/, so an existing install keeps both. Old image
# tars are removed first so deploy.sh loads only this version's images.
mkdir -p "$DIR"
rm -f "$DIR"/"$STEM"-images-*.tar
tar xzf "$ARCHIVE" -C "$DIR" --strip-components=1
say "== unpacked; starting deploy.sh"
cd "$DIR"
exec ./deploy.sh </dev/tty
