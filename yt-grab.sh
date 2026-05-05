#!/bin/bash
#####################################################################################
# Author: Tempus Thales
# Version: 0.06
# Date: 05/04/2026 May the fourth be with you.
# Description: Convert YouTube URLs to MP4 video or MP3 audio.
#
# Auto-installs missing deps on macOS, Arch, Debian/Ubuntu, and Fedora families,
# because I'm cool like that.
#####################################################################################
# Changelog:
# 0.06 - 05/04/2026 - Added macOS support via Homebrew
#                   - Exits with brew install instructions if brew is missing
# 0.05 - 05/04/2026 - -l can be used alone to download an entire playlist
#                   - Builds canonical playlist?list= URL when no video ID given
# 0.04 - 05/04/2026 - Simplified invocation: pass YouTube video IDs instead of URLs
#                   - Full URLs still accepted for backward compatibility
#                   - New -l flag for optional playlist ID
# 0.03 - 05/04/2026 - Running with no arguments now shows usage (exit 0)
#                   - Added Windows-style /? as a help flag
# 0.02 - 05/04/2026 - Default download folder changed to ~/yt-downloads
#                   - Folder existence is checked and reported before download
# 0.01 - 05/04/2026 - Initial release
#                   - YouTube URL to MP4/MP3 conversion via yt-dlp + ffmpeg
#                   - OS auto-detection via /etc/os-release (ID + ID_LIKE)
#                   - Auto-install support for Arch, Debian/Ubuntu, Fedora families
#                   - Interactive install prompt with -y flag for non-interactive use
#                   - Multiple URL and playlist support
#                   - Configurable output directory
#####################################################################################

set -euo pipefail

OUTPUT_DIR="${HOME}/yt-downloads"
FORMAT=""
LIST_ID=""
ASSUME_YES=0

usage() {
    cat <<EOF
Usage: $(basename "$0") -f <mp4|mp3> [-o <dir>] [-l <playlist_id>] [-y] [<video_id> ...]

Options:
  -f FORMAT   Output format: mp4 or mp3 (required)
  -o DIR      Output directory (default: ~/yt-downloads)
  -l ID       YouTube playlist ID (downloads the whole playlist on its own,
              or anchors playback when combined with a video ID)
  -y          Assume yes to dependency install prompt (non-interactive)
  -h, /?      Show this help

Examples:
  Download a single video as MP4:
    $(basename "$0") -f mp4 cGDX6cbqzsk

  Convert a video to MP3:
    $(basename "$0") -f mp3 cGDX6cbqzsk

  Download multiple individual videos:
    $(basename "$0") -f mp3 cGDX6cbqzsk dQw4w9WgXcQ

  Download an entire playlist as MP4:
    $(basename "$0") -f mp4 -l PLxxxxxxxxxx

  Download an entire playlist as MP3:
    $(basename "$0") -f mp3 -l RDcGDX6cbqzsk

Notes:
  * Positional arguments are YouTube video IDs (the part after v= in the URL).
  * Full URLs are also accepted if you'd rather paste them in directly.
  * Files are named "<video title>.<ext>" in the output directory.
  * Missing yt-dlp/ffmpeg are auto-installed on macOS (via Homebrew),
    Arch, Debian/Ubuntu, and Fedora.
EOF
}

# Echoes "macos", "arch", "debian", "fedora", or "" (unsupported/undetected).
detect_os_family() {
    # macOS first: it doesn't ship /etc/os-release.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macos"
        return
    fi

    if [[ ! -r /etc/os-release ]]; then
        echo ""
        return
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        arch|cachyos|endeavouros|manjaro|garuda|artix) echo "arch";   return ;;
        ubuntu|debian|pop|linuxmint|elementary|zorin)  echo "debian"; return ;;
        fedora|nobara|bazzite)                         echo "fedora"; return ;;
    esac

    case "${ID_LIKE:-}" in
        *arch*)            echo "arch";   return ;;
        *debian*|*ubuntu*) echo "debian"; return ;;
        *fedora*)          echo "fedora"; return ;;
    esac

    echo ""
}

install_deps() {
    local missing=("$@")
    local family
    family="$(detect_os_family)"

    if [[ -z "$family" ]]; then
        echo "Error: missing dependencies (${missing[*]}) and OS could not be identified." >&2
        echo "Supported auto-install: macOS, Arch, Debian/Ubuntu, Fedora families." >&2
        echo "Install ${missing[*]} manually and re-run." >&2
        exit 1
    fi

    # macOS requires Homebrew. Bail with install instructions if brew is missing.
    if [[ "$family" == "macos" ]] && ! command -v brew >/dev/null 2>&1; then
        echo "Error: Homebrew is required to auto-install dependencies on macOS." >&2
        echo "" >&2
        echo "Install Homebrew, then re-run this script:" >&2
        echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
        echo "" >&2
        echo "More info: https://brew.sh" >&2
        exit 1
    fi

    # Map generic names to distro-specific package names.
    local pkgs=()
    local p
    for p in "${missing[@]}"; do
        if [[ "$family" == "fedora" && "$p" == "ffmpeg" ]]; then
            # ffmpeg-free is in default Fedora repos. Handles MP4 muxing and MP3
            # encoding. For full codec support, swap to RPM Fusion ffmpeg separately.
            pkgs+=("ffmpeg-free")
        else
            pkgs+=("$p")
        fi
    done

    echo "Missing dependencies: ${missing[*]}"
    echo "Detected OS family:   $family"

    local desc
    case "$family" in
        macos)  desc="brew install ${pkgs[*]}" ;;
        arch)   desc="sudo pacman -S --needed ${pkgs[*]}" ;;
        debian) desc="sudo apt update && sudo apt install -y ${pkgs[*]}" ;;
        fedora) desc="sudo dnf install -y ${pkgs[*]}" ;;
    esac
    echo "Will run: $desc"

    if [[ "$ASSUME_YES" != "1" ]]; then
        local reply
        if ! read -r -p "Proceed? [y/N] " reply; then
            echo "Aborted (no input)." >&2
            exit 1
        fi
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo "Aborted." >&2
            exit 1
        fi
    fi

    case "$family" in
        macos)  brew install "${pkgs[@]}" ;;
        arch)   sudo pacman -S --needed "${pkgs[@]}" ;;
        debian) sudo apt update && sudo apt install -y "${pkgs[@]}" ;;
        fedora) sudo dnf install -y "${pkgs[@]}" ;;
    esac
}

# Ensure output directory exists, reporting whether it was reused or created.
ensure_output_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        echo "Using existing download folder: $dir"
    elif [[ -e "$dir" ]]; then
        echo "Error: '$dir' exists but is not a directory." >&2
        exit 1
    else
        echo "Creating download folder: $dir"
        mkdir -p "$dir"
    fi
}

# Build a full YouTube URL from a video ID. Passes through anything that
# already looks like a URL. Appends &list=<LIST_ID> when -l was given.
build_youtube_url() {
    local id="$1"
    local url

    if [[ "$id" =~ ^https?:// ]]; then
        url="$id"
    else
        url="https://www.youtube.com/watch?v=${id}"
    fi

    if [[ -n "$LIST_ID" && "$url" != *"list="* ]]; then
        if [[ "$url" == *"?"* ]]; then
            url="${url}&list=${LIST_ID}"
        else
            url="${url}?list=${LIST_ID}"
        fi
    fi

    echo "$url"
}

# Bare invocation or Windows-style /? both show help and exit cleanly.
if [[ $# -eq 0 || "${1:-}" == "/?" ]]; then
    usage
    exit 0
fi

# Parse args
while getopts ":f:o:l:yh" opt; do
    case "$opt" in
        f) FORMAT="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        l) LIST_ID="$OPTARG" ;;
        y) ASSUME_YES=1 ;;
        h) usage; exit 0 ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
        :)  echo "Option -$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Validate args before touching the system
if [[ "$FORMAT" != "mp4" && "$FORMAT" != "mp3" ]]; then
    echo "Error: -f must be 'mp4' or 'mp3'" >&2
    usage
    exit 1
fi

if [[ $# -eq 0 && -z "$LIST_ID" ]]; then
    echo "Error: provide at least one video ID, or use -l <playlist_id>" >&2
    usage
    exit 1
fi

# Build the URL list.
# - No positional + -l set: download the whole playlist via the canonical URL.
# - One or more positionals: each becomes a video URL (with playlist appended if set).
urls=()
if [[ $# -eq 0 && -n "$LIST_ID" ]]; then
    urls+=("https://www.youtube.com/playlist?list=${LIST_ID}")
else
    for id in "$@"; do
        urls+=("$(build_youtube_url "$id")")
    done
fi

# Dependency check + auto-install
missing=()
for cmd in yt-dlp ffmpeg; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [[ ${#missing[@]} -gt 0 ]]; then
    install_deps "${missing[@]}"

    # Re-verify after install attempt
    for cmd in yt-dlp ffmpeg; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' still not found after install attempt." >&2
            exit 1
        fi
    done
fi

ensure_output_dir "$OUTPUT_DIR"
OUTPUT_TEMPLATE="${OUTPUT_DIR}/%(title)s.%(ext)s"

if [[ "$FORMAT" == "mp4" ]]; then
    # Best mp4 video + best m4a audio, merged. Falls back to best mp4, then anything.
    yt-dlp \
        -f "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b" \
        --merge-output-format mp4 \
        -o "$OUTPUT_TEMPLATE" \
        "${urls[@]}"
else
    # Extract audio, convert to mp3 at highest quality (VBR ~245 kbps).
    yt-dlp \
        -x \
        --audio-format mp3 \
        --audio-quality 0 \
        -o "$OUTPUT_TEMPLATE" \
        "${urls[@]}"
fi

echo "Done. Saved to: $OUTPUT_DIR"
