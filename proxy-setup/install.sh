#!/usr/bin/env bash
set -Eeuo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
declare -r REPO="AlexAdiaconitei/aceberry"
declare -r BRANCH="main"
declare -r RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}/proxy-setup"
declare -r CLONE_URL="https://github.com/${REPO}.git"
STAGE_DIR=""

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "  ${CYAN}${1}${NC}"; }
success() { echo -e "  ${GREEN}✔${NC} ${1}"; }
error()   { echo -e "  ${RED}✖ ERROR:${NC} ${1}" >&2; }
warn()    { echo -e "  ${YELLOW}⚠${NC} ${1}"; }

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    [[ -n "${STAGE_DIR:-}" ]] && rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# ─── Phase 1: Pre-flight checks ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root."
    echo -e "  Reejecutar con: ${BOLD}sudo bash${NC} o añadir ${BOLD}sudo${NC} al one-liner."
    exit 1
fi

if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    error "Se requiere curl o wget para descargar los archivos."
    echo -e "  Instala uno con: ${BOLD}apt-get install -y curl${NC}"
    exit 1
fi

# ─── Banner ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║        ACEBERRY — Instalación / Actualización          ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
echo

# ─── Download helpers ─────────────────────────────────────────────────────────
download_file() {
    local rel_path="$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    if command -v curl &>/dev/null; then
        curl -fsSL "${RAW_BASE}/${rel_path}" -o "$dest" 2>/dev/null
    else
        wget -q "${RAW_BASE}/${rel_path}" -O "$dest" 2>/dev/null
    fi
}

try_git_clone() {
    command -v git &>/dev/null || return 1
    git clone --depth=1 --filter=blob:none --sparse \
        "$CLONE_URL" "$STAGE_DIR/repo" &>/dev/null \
    && git -C "$STAGE_DIR/repo" sparse-checkout set proxy-setup &>/dev/null
}

# ─── File list (relative to proxy-setup/) ─────────────────────────────────────
FILES=(
    "setup-aceberry.sh"
    "docker-compose.yml"
    ".env"
    "aceberry-ctl"
    "aceberry/proxy.py"
    "aceberry/index.html"
    "aceberry/logo.png"
    "aceberry/Dockerfile"
)

# ─── Phase 2 & 3: Staging ─────────────────────────────────────────────────────
STAGE_DIR=$(mktemp -d)
SETUP_DIR=""

info "Descargando archivos de GitHub..."

if try_git_clone; then
    SETUP_DIR="$STAGE_DIR/repo/proxy-setup"
    success "Archivos descargados (git clone)"
else
    # Fallback: download file by file
    SETUP_DIR="$STAGE_DIR/proxy-setup"
    mkdir -p "$SETUP_DIR"
    failed=0
    for rel in "${FILES[@]}"; do
        dest="${SETUP_DIR}/${rel}"
        if ! download_file "$rel" "$dest"; then
            warn "No se pudo descargar: ${rel}"
            failed=1
        fi
    done
    if [[ $failed -eq 1 ]]; then
        warn "Algunas descargas fallaron; continuando si setup-aceberry.sh está disponible."
    fi
    success "Archivos descargados (curl/wget)"
fi

# ─── Phase 3: Validate ────────────────────────────────────────────────────────
if [[ ! -s "${SETUP_DIR}/setup-aceberry.sh" ]]; then
    error "Descarga fallida: setup-aceberry.sh está vacío o no existe."
    exit 1
fi

# ─── Phase 4: Permissions & exec ──────────────────────────────────────────────
chmod +x "${SETUP_DIR}/setup-aceberry.sh"
[[ -f "${SETUP_DIR}/aceberry-ctl" ]] && chmod +x "${SETUP_DIR}/aceberry-ctl"

info "Ejecutando instalación..."
echo

exec bash "${SETUP_DIR}/setup-aceberry.sh" "$@" </dev/tty
