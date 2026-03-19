#!/usr/bin/env bash
#
# setup-acestream.sh — Instalación completa desde cero (o actualización rápida)
#
# Docker + Tailscale + AceStream Engine + HTTPAceProxy
# + Aceberry (web UI + stream resolver)
# + acestream-ctl (CLI opcional)
#
# Fixes aplicados:
#   - Bridge network con DNS explícito (1.1.1.1) para evitar
#     que Tailscale MagicDNS rompa la resolución dentro del contenedor
#   - Healthcheck con wget (curl no existe en la imagen aceserve)
#   - Sin mem_limit (kernels RPi no soportan cgroups memory)
#   - UPnP deshabilitado (evita bucle infinito de port mapping)
#
# Uso: scp -r proxy-setup/ pi@raspberry:~/ && sudo ./proxy-setup/setup-acestream.sh
#      sudo ./proxy-setup/setup-acestream.sh --quick   # saltar Docker/Tailscale
#      (modo personalizado disponible durante la instalación interactiva)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOGFILE="/var/log/setup-acestream.log"
paso_actual=0

info()   { echo -e "${CYAN}ℹ ${NC} $*"; }
ok()     { echo -e "${GREEN}✔ ${NC} $*"; }
warn()   { echo -e "${YELLOW}⚠ ${NC} $*"; }
error()  { echo -e "${RED}✖ ${NC} $*"; }
log_cmd(){ "$@" >> "$LOGFILE" 2>&1; }

header() {
    paso_actual=$((paso_actual + 1))
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  PASO ${paso_actual}/${total_pasos}: $*${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

fail() {
    error "$1"
    error "Log: ${LOGFILE}"
    echo -e "${RED}─── Últimas 20 líneas del log ───${NC}"
    tail -20 "$LOGFILE" 2>/dev/null || true
    echo -e "${RED}─────────────────────────────────${NC}"
    exit 1
}

preguntar() {
    local r
    while true; do
        read -rp "$(echo -e "${YELLOW}? ${NC}$1 [s/n]: ")" r
        case "$r" in [sS]|[sS][iI]) return 0;; [nN]|[nN][oO]) return 1;; *) warn "s/n";; esac
    done
}

# ── Modo de instalación ────────────────────────────
QUICK=false
SHOW_STREAM_LISTS=false
ARCH=$(uname -m)
for arg in "$@"; do
    [[ "$arg" == "--quick" || "$arg" == "-q" ]] && QUICK=true
done

echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        ACEBERRY — Instalación / Actualización          ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Diagnóstico del sistema ────────────────────────
echo -e "  ${BOLD}Sistema:${NC}"
echo -e "  Arquitectura  : ${BOLD}${ARCH}${NC}"

# Docker
if command -v docker &>/dev/null; then
    _DOCKER_VER=$(docker --version 2>/dev/null | sed 's/Docker version //' | sed 's/,.*//' || echo "?")
    if docker info &>/dev/null 2>&1; then
        echo -e "  Docker        : ${GREEN}✔${NC} ${_DOCKER_VER} (daemon activo)"
    else
        echo -e "  Docker        : ${YELLOW}⚠${NC} ${_DOCKER_VER} (daemon no activo)"
    fi
else
    echo -e "  Docker        : ${RED}✖${NC} no instalado  → usa [1] Instalación completa"
fi

# Tailscale
if command -v tailscale &>/dev/null; then
    _TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [[ -n "${_TS_IP}" ]]; then
        echo -e "  Tailscale     : ${GREEN}✔${NC} conectado (${_TS_IP})"
    else
        echo -e "  Tailscale     : ${YELLOW}⚠${NC} instalado, no conectado"
    fi
else
    echo -e "  Tailscale     : ${RED}✖${NC} no instalado  → usa [1] Instalación completa"
fi
echo ""
# ──────────────────────────────────────────────────

if ! $QUICK; then
    echo -e "  ${BOLD}[1]${NC} Instalación completa (Docker + Tailscale + stack)"
    echo -e "  ${BOLD}[2]${NC} Actualizar/reiniciar contenedores (saltar Docker/Tailscale)"
    echo ""
    read -rp "$(echo -e "${YELLOW}? ${NC}Elige [1/2]: ")" MODE_CHOICE
    [[ "$MODE_CHOICE" == "2" ]] && QUICK=true
fi

# ── Modo de configuración ──────────────────────────
CUSTOM=false
if ! $QUICK; then
    echo ""
    echo -e "  ${BOLD}[1]${NC} Instalación por defecto (valores recomendados)"
    echo -e "  ${BOLD}[2]${NC} Instalación personalizada (configurar opciones)"
    echo ""
    read -rp "$(echo -e "${YELLOW}? ${NC}Modo de configuración [1/2]: ")" CFG_CHOICE
    [[ "${CFG_CHOICE:-1}" == "2" ]] && CUSTOM=true
fi

if $CUSTOM; then
    echo ""
    info "Configuración personalizada:"
    preguntar "¿Mostrar listas de streams en la interfaz web?" && SHOW_STREAM_LISTS=true || SHOW_STREAM_LISTS=false
    echo ""
fi

if $QUICK; then
    total_pasos=5
    info "Modo rápido: se omiten Docker y Tailscale."
else
    total_pasos=8
fi

echo "=== Setup $(date) ===" > "$LOGFILE"

[[ $EUID -ne 0 ]] && { error "Ejecuta con: sudo ./setup-acestream.sh"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" == "root" ]] && REAL_USER="pi"
STACK_DIR="/home/${REAL_USER}/acestream-stack"

info "Usuario: ${BOLD}${REAL_USER}${NC}   Arch: ${BOLD}${ARCH}${NC}"

if ! $QUICK; then
    if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
        warn "Script pensado para Raspberry Pi (detectado: ${ARCH})."
        preguntar "¿Continuar?" || exit 0
    fi

    info "Comprobando internet..."
    ping -c 1 -W 5 google.com >> "$LOGFILE" 2>&1 || fail "Sin conexión a internet."
    ok "Internet OK"

    echo ""
    info "Se va a instalar:"
    echo "  1. Sistema + dependencias      5. Desplegar stack (3 servicios)"
    echo "  2. Docker + Compose            6. acestream-ctl (CLI)"
    echo "  3. Tailscale (VPN)             7. Verificar servicios"
    echo "  4. Generar archivos del stack  8. Resumen"
    echo ""
    preguntar "¿Comenzar?" || { info "Cancelado."; exit 0; }
fi

if ! $QUICK; then
    # ══════════════════════════════════════════════
    # PASO 1
    # ══════════════════════════════════════════════
    header "SISTEMA Y DEPENDENCIAS"

    info "Actualizando paquetes..."
    log_cmd apt-get update && log_cmd apt-get upgrade -y || fail "Error al actualizar"
    ok "Sistema actualizado"

    info "Instalando dependencias..."
    log_cmd apt-get install -y curl wget jq python3 || fail "Error en dependencias"
    ok "Dependencias OK"

    # ══════════════════════════════════════════════
    # PASO 2
    # ══════════════════════════════════════════════
    header "DOCKER + DOCKER COMPOSE"

    if command -v docker &>/dev/null; then
        ok "Docker ya instalado: $(docker --version)"
        if preguntar "¿Reinstalar Docker?"; then
            curl -fsSL https://get.docker.com | sh >> "$LOGFILE" 2>&1 || fail "Error Docker"
            ok "Docker reinstalado"
        fi
    else
        info "Instalando Docker (puede tardar)..."
        curl -fsSL https://get.docker.com | sh >> "$LOGFILE" 2>&1 || fail "Error Docker"
        ok "Docker instalado: $(docker --version)"
    fi

    usermod -aG docker "$REAL_USER" >> "$LOGFILE" 2>&1 || true
    log_cmd systemctl enable docker && log_cmd systemctl start docker || fail "Error arrancando Docker"
    ok "Docker habilitado"
    warn "Cierra y reabre SSH para usar docker sin sudo."

    # ══════════════════════════════════════════════
    # PASO 3
    # ══════════════════════════════════════════════
    header "TAILSCALE"

    if command -v tailscale &>/dev/null; then
        ok "Tailscale ya instalado"
    else
        info "Instalando Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh >> "$LOGFILE" 2>&1 || fail "Error Tailscale"
        ok "Tailscale instalado"
    fi

    TAILSCALE_IP=""
    if tailscale status >> "$LOGFILE" 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
        [[ -n "$TAILSCALE_IP" ]] && ok "Tailscale conectado: ${BOLD}${TAILSCALE_IP}${NC}"
    fi

    if [[ -z "$TAILSCALE_IP" ]]; then
        warn "Tailscale necesita autenticación."
        info "Abre el enlace en tu navegador."
        echo ""
        if preguntar "¿Iniciar sesión ahora?"; then
            tailscale up 2>&1 | tee -a "$LOGFILE"; echo ""; sleep 3
            TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
            [[ -n "$TAILSCALE_IP" ]] && ok "IP: ${BOLD}${TAILSCALE_IP}${NC}" || warn "Ejecuta después: sudo tailscale up"
        else
            warn "Ejecuta después: sudo tailscale up"
        fi
    fi
fi

# ══════════════════════════════════════════════
# PASO — GENERAR ARCHIVOS DEL STACK
# ══════════════════════════════════════════════
header "GENERAR ARCHIVOS DEL STACK"

# Detectar compose command (modo rápido puede no haber pasado por el check)
COMPOSE_CMD=""
if docker compose version >> "$LOGFILE" 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    fail "Docker Compose no encontrado. Ejecuta la instalación completa primero."
fi

# Limpiar contenedores antiguos
for C in acestream acelink aceserve httpaceproxy acestream-proxy aceberry-ui; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${C}$"; then
        info "Eliminando contenedor antiguo '${C}'..."
        docker stop "$C" >> "$LOGFILE" 2>&1 || true
        docker rm "$C" >> "$LOGFILE" 2>&1 || true
    fi
done

mkdir -p "${STACK_DIR}"

info "Copiando archivos del stack..."
cp "${SCRIPT_DIR}/docker-compose.yml" "${STACK_DIR}/docker-compose.yml"
[ ! -f "${STACK_DIR}/.env" ] && cp "${SCRIPT_DIR}/.env" "${STACK_DIR}/.env"
if $CUSTOM; then
    sed -i "s/^SHOW_STREAM_LISTS=.*/SHOW_STREAM_LISTS=${SHOW_STREAM_LISTS}/" "${STACK_DIR}/.env"
fi
ok "Archivos copiados en ${STACK_DIR}"

# ══════════════════════════════════════════════
# PASO — DESCARGAR IMÁGENES Y LEVANTAR STACK
# ══════════════════════════════════════════════
header "DESCARGAR IMÁGENES Y LEVANTAR STACK"

info "Descargando jopsis/aceserve:latest..."
log_cmd docker pull jopsis/aceserve:latest || fail "Error descargando aceserve"
ok "aceserve"

info "Descargando jopsis/httpaceproxy:latest..."
log_cmd docker pull jopsis/httpaceproxy:latest || fail "Error descargando httpaceproxy"
ok "httpaceproxy"

info "Descargando ghcr.io/alexadiaconitei/aceberry:latest..."
log_cmd docker pull ghcr.io/alexadiaconitei/aceberry:latest || fail "Error descargando aceberry"
ok "aceberry"

cd "$STACK_DIR"
$COMPOSE_CMD down >> "$LOGFILE" 2>&1 || true

info "Levantando stack..."
if $COMPOSE_CMD up -d >> "$LOGFILE" 2>&1; then
    ok "Stack levantado"
else
    $COMPOSE_CMD logs >> "$LOGFILE" 2>&1 || true
    fail "Error al levantar stack"
fi

# ══════════════════════════════════════════════
# PASO — INSTALAR ACESTREAM-CTL
# ══════════════════════════════════════════════
header "INSTALAR ACESTREAM-CTL"

CTL="/usr/local/bin/acestream-ctl"
cp "${SCRIPT_DIR}/acestream-ctl" "$CTL"
chmod +x "$CTL"
ok "acestream-ctl instalado"

# ══════════════════════════════════════════════
# PASO — VERIFICAR SERVICIOS
# ══════════════════════════════════════════════
header "VERIFICAR SERVICIOS"

ERRORES=0
TAILSCALE_IP="${TAILSCALE_IP:-}"

info "Esperando al engine (hasta 120s)..."
ENGINE_OK=false
for i in $(seq 1 24); do
    c=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:6878/webui/api/service?method=get_version 2>/dev/null || echo 000)
    [[ "$c" == "200" ]] && { ENGINE_OK=true; break; }
    printf "."; sleep 5
done; echo ""
if $ENGINE_OK; then
    ok "Engine :6878"
    # Verificar DNS dentro del contenedor
    info "Verificando DNS del contenedor..."
    DNS_OK=false
    if docker exec aceserve wget -q --spider --timeout=5 https://www.google.com >> "$LOGFILE" 2>&1; then
        DNS_OK=true
    elif docker exec aceserve getent hosts www.google.com >> "$LOGFILE" 2>&1; then
        DNS_OK=true
    fi
    if $DNS_OK; then
        ok "DNS del contenedor funciona (bridge + dns:1.1.1.1)"
    else
        warn "DNS del contenedor podría no funcionar."
        warn "El engine debería funcionar igualmente para streams."
        warn "Comprueba: docker exec aceserve wget -q --spider https://www.google.com"
    fi
else
    warn "Engine no responde aún"
    warn "Comprueba: docker logs aceserve"
    ERRORES=$((ERRORES+1))
fi

info "Verificando Aceberry..."
sleep 5
c=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/health 2>/dev/null || echo 000)
[[ "$c" == "200" ]] && ok "Aceberry :8080" || { warn "Aceberry arrancando"; ERRORES=$((ERRORES+1)); }

info "Verificando HTTPAceProxy..."
sleep 2
c=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:8888/stat 2>/dev/null || echo 000)
[[ "$c" == "200" ]] && ok "HTTPAceProxy :8888" || { warn "HTTPAceProxy esperando healthcheck"; ERRORES=$((ERRORES+1)); }

[[ -z "$TAILSCALE_IP" ]] && TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
[[ -n "$TAILSCALE_IP" ]] && ok "Tailscale: ${TAILSCALE_IP}" || { warn "Tailscale no conectado"; ERRORES=$((ERRORES+1)); }

[[ $ERRORES -gt 0 ]] && warn "${ERRORES} servicio(s) aún arrancando. Espera 1-2 min."

# ══════════════════════════════════════════════
# PASO — RESUMEN
# ══════════════════════════════════════════════
header "RESUMEN"

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP="${TAILSCALE_IP:-${LOCAL_IP:-<TU_IP>}}"

echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              INSTALACIÓN COMPLETADA                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Tu URL base para VLC:${NC}"
echo ""
echo -e "  ${BOLD}http://${IP}:8080/ace/getstream?id=TU_ID${NC}"
echo ""
echo "  Sustituye TU_ID por el hash del AceStream."
echo "  Cambia de canal cambiando la URL en VLC."
echo "  El proxy limpia la sesión anterior automáticamente."
echo ""
echo -e "${BOLD}📱 Web UI (desde el móvil):${NC}"
echo ""
echo "  http://${IP}:8080"
echo ""
echo -e "${BOLD}🌐 Paneles:${NC}"
echo ""
echo "  Web UI:      http://${IP}:8080"
echo "  Proxy stats: http://${IP}:8888/stat"
echo ""
echo -e "${BOLD}🔧 Gestión:${NC}"
echo ""
echo "  acestream-ctl status        Estado de todo"
echo "  acestream-ctl logs          Logs en tiempo real"
echo "  acestream-ctl restart       Reiniciar stack"
echo ""
echo "  cd ${STACK_DIR}"
echo "  ${COMPOSE_CMD} up -d        Levantar"
echo "  ${COMPOSE_CMD} down         Parar"
echo "  ${COMPOSE_CMD} pull && ${COMPOSE_CMD} up -d   Actualizar"
echo ""

# Guardar resumen
cat > "/home/${REAL_USER}/acestream-info.txt" << RESEOF
=== AceBerry Stack ===
Instalado: $(date)
Directorio: ${STACK_DIR}

IP Local:     ${LOCAL_IP:-?}
IP Tailscale: ${TAILSCALE_IP:-no conectado}

== URL para VLC ==
http://<IP>:8080/ace/getstream?id=<ID>

== Web UI ==
http://<IP>:8080

== Paneles ==
Stats: http://<IP>:8888/stat

== CLI ==
acestream-ctl status|lists|logs|restart|url|web|stop|help
RESEOF
chown "${REAL_USER}:${REAL_USER}" "/home/${REAL_USER}/acestream-info.txt" 2>/dev/null || true
chown -R "${REAL_USER}:${REAL_USER}" "$STACK_DIR" 2>/dev/null || true

ok "Resumen: ~/acestream-info.txt"
info "Log: ${LOGFILE}"
echo ""
echo -e "${GREEN}¡Listo! Abre http://${IP}:8080 desde tu móvil o PC.${NC}"
echo ""
