#!/usr/bin/env bash
# =============================================================================
# build_mysql.sh
# Extracts, configures (CMake), and builds all MySQL .tar.gz archives in a folder.
# Usage: ./build_mysql.sh [SOURCE_DIR]
#   SOURCE_DIR   Directory containing mysql-*.tar.gz files
#                (defaults to current directory)
#
# Prerequisites:
#   macOS:  brew install cmake bison openssl ncurses pkg-config
#   Debian: apt install cmake bison libssl-dev libncurses-dev pkg-config build-essential
#   RHEL:   dnf install cmake bison openssl-devel ncurses-devel pkg-config gcc-c++
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }

# ── Arguments ─────────────────────────────────────────────────────────────────
SOURCE_DIR="${1:-.}"

# ── Config knobs (edit as needed) ─────────────────────────────────────────────
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Extra CMake flags you want applied to every build
EXTRA_CMAKE_FLAGS="-DWITH_DEBUG=1 -DWITH_ZLIB=bundled -DWITHOUT_SERVER=ON -DWITH_BOOST=./boost_1_59_0"

# ── Check for cmake ───────────────────────────────────────────────────────────
if ! command -v cmake &>/dev/null; then
  error "cmake not found. Install it first:"
  error "  macOS:  brew install cmake"
  error "  Debian: apt install cmake"
  error "  RHEL:   dnf install cmake"
  exit 1
fi
info "CMake version: $(cmake --version | head -1)"

# ── Check for bison (required by MySQL's parser) ──────────────────────────────
if ! command -v bison &>/dev/null; then
  warn "bison not found -- MySQL build may fail."
  warn "  macOS:  brew install bison  (then add to PATH: /usr/local/opt/bison/bin)"
  warn "  Debian: apt install bison"
  warn "  RHEL:   dnf install bison"
else
  info "Bison version: $(bison --version | head -1)"
fi

# ── Rosetta detection (Apple Silicon + arch -x86_64) ─────────────────────────
IS_ROSETTA=false
if [[ "$(uname)" == "Darwin" ]] && [[ "$(uname -m)" == "x86_64" ]]; then
  if sysctl -n sysctl.proc_translated 2>/dev/null | grep -q "1"; then
    IS_ROSETTA=true
    info "Rosetta detected -- preferring x86_64 Homebrew at /usr/local/bin"
  fi
fi

# ── Auto-detect OpenSSL ───────────────────────────────────────────────────────
OPENSSL_DIR=""
if $IS_ROSETTA; then
  OPENSSL_CANDIDATES=(
    /usr/local/opt/openssl
    /usr/local/ssl
    "$(arch -x86_64 /usr/local/bin/brew --prefix openssl 2>/dev/null)"
    /usr
  )
else
  OPENSSL_CANDIDATES=(
    "$(brew --prefix openssl 2>/dev/null)"
    /opt/homebrew/opt/openssl
    /usr/local/opt/openssl
    /usr/local/ssl
    /usr
  )
fi

for candidate in "${OPENSSL_CANDIDATES[@]}"; do
  if [[ -n "$candidate" ]] && \
     [[ -f "${candidate}/lib/libcrypto.a"     || \
        -f "${candidate}/lib/libcrypto.so"    || \
        -f "${candidate}/lib/libcrypto.dylib" ]]; then
    OPENSSL_DIR="$candidate"
    break
  fi
done

if [[ -n "$OPENSSL_DIR" ]]; then
  info "Found OpenSSL at: $OPENSSL_DIR"
else
  warn "OpenSSL not found -- building without SSL support."
  warn "  macOS:  brew install openssl"
  warn "  Debian: apt install libssl-dev"
  warn "  RHEL:   dnf install openssl-devel"
fi

# ── Auto-detect ncurses ───────────────────────────────────────────────────────
CURSES_DIR=""
if $IS_ROSETTA; then
  CURSES_CANDIDATES=(
    /usr/local/opt/ncurses
    "$(arch -x86_64 /usr/local/bin/brew --prefix ncurses 2>/dev/null)"
    /usr
  )
else
  CURSES_CANDIDATES=(
    "$(brew --prefix ncurses 2>/dev/null)"
    /opt/homebrew/opt/ncurses
    /usr/local/opt/ncurses
    /usr
  )
fi

for candidate in "${CURSES_CANDIDATES[@]}"; do
  if [[ -n "$candidate" ]] && \
     [[ -f "${candidate}/lib/libncurses.a"     || \
        -f "${candidate}/lib/libncurses.so"    || \
        -f "${candidate}/lib/libncurses.dylib" ]]; then
    CURSES_DIR="$candidate"
    break
  fi
done

if [[ -n "$CURSES_DIR" ]]; then
  info "Found ncurses at: $CURSES_DIR"
else
  warn "ncurses not found -- mysql client may fail to build."
  warn "  macOS:  brew install ncurses"
  warn "  Debian: apt install libncurses-dev"
  warn "  RHEL:   dnf install ncurses-devel"
fi

# ── Validate source dir ───────────────────────────────────────────────────────
if [[ ! -d "$SOURCE_DIR" ]]; then
  error "Directory '$SOURCE_DIR' does not exist."
  exit 1
fi

SOURCE_DIR="$(realpath "$SOURCE_DIR")"
LOG_BASE="${SOURCE_DIR}/logs"
trap 'echo -e "\nLogs saved to: $LOG_BASE"' EXIT

info "Source dir : $SOURCE_DIR"
info "Build dir  : $SOURCE_DIR"
info "Jobs       : $JOBS"

# ── Collect archives ──────────────────────────────────────────────────────────
ARCHIVES=()
while IFS= read -r f; do
  ARCHIVES+=("$f")
done < <(find "$SOURCE_DIR" -maxdepth 1 -name "mysql-*.tar.gz" | sort -V)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
  error "No mysql-*.tar.gz files found in '$SOURCE_DIR'."
  exit 1
fi

info "Found ${#ARCHIVES[@]} archive(s):"
for a in "${ARCHIVES[@]}"; do echo "    $(basename "$a")"; done

# ── Track results ─────────────────────────────────────────────────────────────
BUILT=(); FAILED=()

# ══════════════════════════════════════════════════════════════════════════════
# Main loop
# ══════════════════════════════════════════════════════════════════════════════
for ARCHIVE in "${ARCHIVES[@]}"; do
  BASENAME="$(basename "$ARCHIVE")"
  VERSION="$(echo "$BASENAME" | sed -E 's/mysql-([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
  LOG_DIR="${LOG_BASE}/${VERSION}"
  mkdir -p "$LOG_DIR"

  header "Building MySQL $VERSION"

  # ── 1. Extract ──────────────────────────────────────────────────────────────
  info "Extracting $BASENAME..."
  tar -xzf "$ARCHIVE" -C "$SOURCE_DIR"

  EXTRACT_DIR="${SOURCE_DIR}/mysql-${VERSION}"
  if [[ ! -d "$EXTRACT_DIR" ]]; then
    EXTRACT_DIR="$(find "$SOURCE_DIR" -maxdepth 1 -type d -name "mysql-${VERSION%%.*}*" | sort -V | tail -1)"
  fi

  if [[ ! -d "$EXTRACT_DIR" ]]; then
    error "Could not find extracted directory for $BASENAME. Skipping."
    FAILED+=("$VERSION"); continue
  fi
  success "Extracted -> $EXTRACT_DIR"



  # MySQL builds out-of-tree -- keeps source clean and avoids CMake cache bleed
  BUILD_DIR="${EXTRACT_DIR}/build"
  mkdir -p "$BUILD_DIR"

  #Set install dir
  INSTALL_DIR="${EXTRACT_DIR}/dist"
  mkdir -p "$INSTALL_DIR"

  # ── 2. Assemble CMake flags ──────────────────────────────────────────────────
  CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    -DDOWNLOAD_BOOST=1
    -DWITH_BOOST="${EXTRACT_DIR}/boost"
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    $EXTRA_CMAKE_FLAGS
  )

  if [[ -n "$OPENSSL_DIR" ]]; then
    CMAKE_FLAGS+=(
      -DWITH_SSL="${OPENSSL_DIR}"
    )
  else
    CMAKE_FLAGS+=(-DWITH_SSL=bundled)
  fi

  if [[ -n "$CURSES_DIR" ]]; then
    CMAKE_FLAGS+=(
      -DCURSES_LIBRARY="${CURSES_DIR}/lib/libncurses.a"
      -DCURSES_INCLUDE_PATH="${CURSES_DIR}/include"
    )
  fi

  # On macOS under Rosetta, tell CMake to target x86_64 explicitly
  if $IS_ROSETTA; then
    CMAKE_FLAGS+=(-DCMAKE_OSX_ARCHITECTURES=x86_64)
  fi

  # ── 3. CMake configure ───────────────────────────────────────────────────────
  info "Running cmake..."
  if ! cmake -S "$EXTRACT_DIR" -B "$BUILD_DIR" "${CMAKE_FLAGS[@]}" \
       > "$LOG_DIR/cmake.log" 2>&1; then
    error "cmake failed -- see $LOG_DIR/cmake.log"
    FAILED+=("$VERSION"); continue
  fi
  success "CMake configure done."

  # ── 4. Build ─────────────────────────────────────────────────────────────────
  info "Running cmake --build with $JOBS jobs..."
  if ! cmake --build "$BUILD_DIR" --parallel "$JOBS" \
       > "$LOG_DIR/make.log" 2>&1; then
    error "Build failed -- see $LOG_DIR/make.log"
    FAILED+=("$VERSION"); continue
  fi
  success "Build complete."

#install the files
  info "Installing binaries to $INSTALL_DIR..."
  if ! cmake --install "$BUILD_DIR" > "$LOG_DIR/install.log" 2>&1; then
    error "Install failed -- see $LOG_DIR/install.log"
    FAILED+=("$VERSION"); continue
  fi

success "Binaries available in: $INSTALL_DIR/bin"

  # ── 5. Fix dylib rpaths (macOS only) ─────────────────────────────────────────
  if [[ "$(uname)" == "Darwin" ]]; then
    info "Patching dylib rpaths for portability..."

    while IFS= read -r dylib; do
      LIBNAME="$(basename "$dylib")"
      install_name_tool -id "@rpath/${LIBNAME}" "$dylib" 2>/dev/null || true
    done < <(find "$BUILD_DIR" -name "*.dylib" ! -path "*/CMakeFiles/*")

    while IFS= read -r bin; do
      while IFS= read -r dep; do
        case "$dep" in
          */mysql*/build/*|*/mysql*/lib/*)
            LIBNAME="$(basename "$dep")"
            install_name_tool \
              -change "$dep" "@executable_path/../lib/${LIBNAME}" \
              "$bin" 2>/dev/null || true
            ;;
        esac
      done < <(otool -L "$bin" 2>/dev/null | awk 'NR>1{print $1}')
    done < <(find "$BUILD_DIR/bin" -type f -perm +111 2>/dev/null)

    success "Rpath patching done."
  fi

  BUILT+=("$VERSION")
done

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
header "Summary"

[[ ${#BUILT[@]}  -gt 0 ]] && success "Built  (${#BUILT[@]}):  ${BUILT[*]}"
[[ ${#FAILED[@]} -gt 0 ]] && error   "Failed (${#FAILED[@]}): ${FAILED[*]}"

[[ ${#FAILED[@]} -gt 0 ]] && exit 1
echo ""
success "All versions built successfully."
