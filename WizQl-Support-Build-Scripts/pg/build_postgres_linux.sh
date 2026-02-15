#!/usr/bin/env bash
# =============================================================================
# build_postgres.sh
# Extracts, configures, and builds all PostgreSQL .tar.gz archives in a folder.
# Usage: ./build_postgres.sh [SOURCE_DIR]
#   SOURCE_DIR   Directory containing postgresql-*.tar.gz files
#                (defaults to current directory)
# Prerequisites:
#   Debian/Ubuntu: apt install build-essential bison flex libssl-dev \
#                              libreadline-dev zlib1g-dev pkg-config \
#                              libicu-dev libncurses-dev
#   RHEL/Fedora:   dnf install gcc gcc-c++ make bison flex openssl-devel \
#                              readline-devel zlib-devel pkg-config \
#                              libicu-devel ncurses-devel
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
JOBS=$(nproc 2>/dev/null || echo 4)
CONFIGURE_FLAGS="--with-readline --with-zlib --enable-debug"

# ── Auto-detect OpenSSL ───────────────────────────────────────────────────────
OPENSSL_DIR=""
OPENSSL_CANDIDATES=(
  /usr
  /usr/local
)

# Prefer pkg-config when available
if command -v pkg-config &>/dev/null && pkg-config --exists openssl 2>/dev/null; then
  OPENSSL_DIR="$(pkg-config --variable=prefix openssl)"
fi

if [[ -z "$OPENSSL_DIR" ]]; then
  for candidate in "${OPENSSL_CANDIDATES[@]}"; do
    if [[ -n "$candidate" ]] && \
       [[ -f "${candidate}/lib/libcrypto.a"  || \
          -f "${candidate}/lib/libcrypto.so" || \
          -f "${candidate}/lib64/libcrypto.so" ]]; then
      OPENSSL_DIR="$candidate"
      break
    fi
  done
fi

if [[ -n "$OPENSSL_DIR" ]]; then
  info "Found OpenSSL at: $OPENSSL_DIR"
  CONFIGURE_FLAGS="$CONFIGURE_FLAGS --with-openssl"
  export PKG_CONFIG_PATH="${OPENSSL_DIR}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LDFLAGS="-L${OPENSSL_DIR}/lib${LDFLAGS:+ $LDFLAGS}"
  export CPPFLAGS="-I${OPENSSL_DIR}/include${CPPFLAGS:+ $CPPFLAGS}"
else
  warn "OpenSSL not found -- building without it."
  warn "  Debian/Ubuntu: apt install libssl-dev"
  warn "  RHEL/Fedora:   dnf install openssl-devel"
fi

# ── Auto-detect ICU (required by PostgreSQL >= 16) ────────────────────────────
ICU_DIR=""

# Try pkg-config first -- most reliable on Linux
if command -v pkg-config &>/dev/null && pkg-config --exists icu-uc icu-i18n 2>/dev/null; then
  ICU_DIR="$(pkg-config --variable=prefix icu-uc)"
fi

# Fall back to common Linux paths
if [[ -z "$ICU_DIR" ]]; then
  ICU_CANDIDATES=(
    /usr
    /usr/local
  )

  for candidate in "${ICU_CANDIDATES[@]}"; do
    if [[ -n "$candidate" ]] && \
       [[ -f "${candidate}/lib/libicuuc.a"    || \
          -f "${candidate}/lib/libicuuc.so"   || \
          -f "${candidate}/lib64/libicuuc.so" ]]; then
      ICU_DIR="$candidate"
      break
    fi
  done
fi

# ── Per-version ICU flag (only applied to pg16+) ──────────────────────────────
ICU_FLAGS=""
if [[ -n "$ICU_DIR" ]]; then
  info "Found ICU at: $ICU_DIR"
  ICU_FLAGS="--with-icu"
  export PKG_CONFIG_PATH="${ICU_DIR}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LDFLAGS="-L${ICU_DIR}/lib${LDFLAGS:+ $LDFLAGS}"
  export CPPFLAGS="-I${ICU_DIR}/include${CPPFLAGS:+ $CPPFLAGS}"
else
  warn "ICU not found -- pg16+ will build with --without-icu."
  warn "  Debian/Ubuntu: apt install libicu-dev"
  warn "  RHEL/Fedora:   dnf install libicu-devel"
  ICU_FLAGS="--without-icu"
fi

# ── Validate source dir ───────────────────────────────────────────────────────
if [[ ! -d "$SOURCE_DIR" ]]; then
  error "Directory '$SOURCE_DIR' does not exist."
  exit 1
fi

SOURCE_DIR="$(realpath "$SOURCE_DIR")"
WORK_DIR="$SOURCE_DIR/build"
LOG_BASE="${WORK_DIR}/logs"
mkdir -p "$WORK_DIR"
trap 'echo -e "\nLogs saved to: $LOG_BASE"' EXIT

info "Source dir : $SOURCE_DIR"
info "Build dir  : $WORK_DIR"
info "Jobs       : $JOBS"

# ── Collect archives ──────────────────────────────────────────────────────────
ARCHIVES=()
while IFS= read -r f; do
  ARCHIVES+=("$f")
done < <(find "$SOURCE_DIR" -maxdepth 1 -name "postgresql-*.tar.gz" | sort -V)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
  error "No postgresql-*.tar.gz files found in '$SOURCE_DIR'."
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
  VERSION="$(echo "$BASENAME" | sed -E 's/postgresql-([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
  MAJOR="$(echo "$VERSION" | cut -d. -f1)"
  LOG_DIR="${LOG_BASE}/${VERSION}"
  mkdir -p "$LOG_DIR"

  header "Building PostgreSQL $VERSION"

  # Apply ICU flag only for pg16+; older versions don't know --with/without-icu
  VERSION_FLAGS="$CONFIGURE_FLAGS"
  if [[ "$MAJOR" -ge 16 ]]; then
    VERSION_FLAGS="$VERSION_FLAGS $ICU_FLAGS"
    info "ICU flag applied: $ICU_FLAGS"
  fi

  # ── 1. Extract ──────────────────────────────────────────────────────────────
  info "Extracting $BASENAME..."
  tar -xzf "$ARCHIVE" -C "$WORK_DIR"

  EXTRACT_DIR="${WORK_DIR}/postgresql-${VERSION}"
  if [[ ! -d "$EXTRACT_DIR" ]]; then
    EXTRACT_DIR="$(find "$WORK_DIR" -maxdepth 1 -type d -name "postgresql-${VERSION%%.*}*" | sort -V | tail -1)"
  fi

  if [[ ! -d "$EXTRACT_DIR" ]]; then
    error "Could not find extracted directory for $BASENAME. Skipping."
    FAILED+=("$VERSION"); continue
  fi
  success "Extracted -> $EXTRACT_DIR"

  pushd "$EXTRACT_DIR" > /dev/null

  # ── 2. Configure ────────────────────────────────────────────────────────────
  info "Running ./configure..."
  # shellcheck disable=SC2086
  if ! ./configure $VERSION_FLAGS > "$LOG_DIR/configure.log" 2>&1; then
    error "configure failed -- see $LOG_DIR/configure.log"
    FAILED+=("$VERSION"); popd > /dev/null; continue
  fi
  success "Configure done."

  # ── 3. Make ─────────────────────────────────────────────────────────────────
  info "Running make -j${JOBS}..."
  if ! make -j"$JOBS" > "$LOG_DIR/make.log" 2>&1; then
    error "make failed -- see $LOG_DIR/make.log"
    FAILED+=("$VERSION"); popd > /dev/null; continue
  fi
  success "Build complete."

  popd > /dev/null
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
