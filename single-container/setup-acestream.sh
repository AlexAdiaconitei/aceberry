#!/usr/bin/env bash
#
# setup-acestream.sh
# Instalación guiada de AceStream + Docker + Tailscale en Raspberry Pi
#
# Uso: chmod +x setup-acestream.sh && sudo ./setup-acestream.sh
#

set -euo pipefail

# ─────────────────────────────────────────────
# Colores y utilidades
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOGFILE="/var/log/setup-acestream.log"

paso_actual=0
total_pasos=6

info()    { echo -e "${CYAN}ℹ ${NC} $*"; }
ok()      { echo -e "${GREEN}✔ ${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠ ${NC} $*"; }
error()   { echo -e "${RED}✖ ${NC} $*"; }
header()  {
    paso_actual=$((paso_actual + 1))
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  PASO ${paso_actual}/${total_pasos}: $*${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

log_cmd() {
    "$@" >> "$LOGFILE" 2>&1
}

fail() {
    error "$1"
    error "Revisa el log completo en: ${LOGFILE}"
    echo ""
    echo -e "${RED}─── Últimas 20 líneas del log ───${NC}"
    tail -20 "$LOGFILE" 2>/dev/null || true
    echo -e "${RED}─────────────────────────────────${NC}"
    exit 1
}

preguntar_si_no() {
    local respuesta
    while true; do
        read -rp "$(echo -e "${YELLOW}? ${NC}$1 [s/n]: ")" respuesta
        case "$respuesta" in
            [sS]|[sS][iI]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
            *) warn "Responde 's' o 'n'" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Seleccionar imagen Docker según arquitectura
# ─────────────────────────────────────────────
seleccionar_imagen() {
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64)
            # Raspberry Pi 3/4/5 con OS 64-bit
            DOCKER_IMAGE="jopsis/acestream:arm64-latest"
            DOCKER_IMAGE_ALT="futebas/acestream-engine-arm:latest"
            ;;
        armv7l)
            # Raspberry Pi 2/3/4 con OS 32-bit
            DOCKER_IMAGE="jopsis/acestream:arm32-latest"
            DOCKER_IMAGE_ALT=""
            ;;
        x86_64)
            DOCKER_IMAGE="jopsis/acestream:amd64-latest"
            DOCKER_IMAGE_ALT="blaiseio/acelink:latest"
            ;;
        *)
            DOCKER_IMAGE="jopsis/acestream:arm64-latest"
            DOCKER_IMAGE_ALT=""
            ;;
    esac
    info "Arquitectura detectada: ${BOLD}${ARCH}${NC}"
    info "Imagen Docker seleccionada: ${BOLD}${DOCKER_IMAGE}${NC}"
}

# ─────────────────────────────────────────────
# Comprobaciones iniciales
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   INSTALACIÓN: AceStream + Docker + Tailscale   ║${NC}"
echo -e "${BOLD}║            para Raspberry Pi                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

echo "=== Setup AceStream - $(date) ===" > "$LOGFILE"

# Verificar root
if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse con sudo."
    echo "  Ejecuta: sudo ./setup-acestream.sh"
    exit 1
fi

# Detectar usuario real
REAL_USER="${SUDO_USER:-$USER}"
if [[ "$REAL_USER" == "root" ]]; then
    warn "No se pudo detectar el usuario real. Se usará 'pi'."
    REAL_USER="pi"
fi
info "Usuario detectado: ${BOLD}${REAL_USER}${NC}"

# Seleccionar imagen según arquitectura
seleccionar_imagen

# Verificar conexión a internet
info "Comprobando conexión a internet..."
if ! ping -c 1 -W 5 google.com >> "$LOGFILE" 2>&1; then
    fail "No hay conexión a internet. Conéctate y vuelve a ejecutar el script."
fi
ok "Conexión a internet OK"

echo ""
info "Se va a instalar:"
echo "  1. Actualización del sistema"
echo "  2. Docker"
echo "  3. Tailscale"
echo "  4. AceStream Engine (${DOCKER_IMAGE})"
echo "  5. Verificación de servicios"
echo "  6. Generación de URLs de ejemplo"
echo ""

if ! preguntar_si_no "¿Comenzar la instalación?"; then
    info "Instalación cancelada."
    exit 0
fi

# ─────────────────────────────────────────────
# PASO 1: Actualizar sistema
# ─────────────────────────────────────────────
header "ACTUALIZAR SISTEMA"

info "Actualizando paquetes (puede tardar unos minutos)..."
if log_cmd apt-get update && log_cmd apt-get upgrade -y; then
    ok "Sistema actualizado"
else
    fail "Error al actualizar el sistema"
fi

info "Instalando dependencias básicas..."
if log_cmd apt-get install -y curl wget jq; then
    ok "Dependencias instaladas"
else
    fail "Error al instalar dependencias"
fi

# ─────────────────────────────────────────────
# PASO 2: Instalar Docker
# ─────────────────────────────────────────────
header "INSTALAR DOCKER"

if command -v docker &>/dev/null; then
    ok "Docker ya está instalado: $(docker --version)"
    if ! preguntar_si_no "¿Reinstalar Docker?"; then
        info "Saltando instalación de Docker"
    else
        info "Instalando Docker..."
        if curl -fsSL https://get.docker.com | sh >> "$LOGFILE" 2>&1; then
            ok "Docker instalado: $(docker --version)"
        else
            fail "Error al instalar Docker"
        fi
    fi
else
    info "Instalando Docker (puede tardar varios minutos)..."
    if curl -fsSL https://get.docker.com | sh >> "$LOGFILE" 2>&1; then
        ok "Docker instalado: $(docker --version)"
    else
        fail "Error al instalar Docker"
    fi
fi

info "Añadiendo '${REAL_USER}' al grupo docker..."
if usermod -aG docker "$REAL_USER" >> "$LOGFILE" 2>&1; then
    ok "Usuario '${REAL_USER}' añadido al grupo docker"
    warn "Necesitarás cerrar sesión SSH y volver a entrar para usarlo sin sudo."
else
    warn "No se pudo añadir al grupo docker. Hazlo manualmente con: sudo usermod -aG docker ${REAL_USER}"
fi

info "Habilitando Docker en el arranque..."
if log_cmd systemctl enable docker && log_cmd systemctl start docker; then
    ok "Docker habilitado y arrancado"
else
    fail "Error al habilitar Docker"
fi

# ─────────────────────────────────────────────
# PASO 3: Instalar Tailscale
# ─────────────────────────────────────────────
header "INSTALAR TAILSCALE"

if command -v tailscale &>/dev/null; then
    ok "Tailscale ya está instalado: $(tailscale version 2>/dev/null | head -1)"
else
    info "Instalando Tailscale..."
    if curl -fsSL https://tailscale.com/install.sh | sh >> "$LOGFILE" 2>&1; then
        ok "Tailscale instalado"
    else
        fail "Error al instalar Tailscale"
    fi
fi

# Comprobar si Tailscale está conectado
TAILSCALE_IP=""
if tailscale status >> "$LOGFILE" 2>&1; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
    if [[ -n "$TAILSCALE_IP" ]]; then
        ok "Tailscale ya está conectado. IP: ${BOLD}${TAILSCALE_IP}${NC}"
    fi
fi

if [[ -z "$TAILSCALE_IP" ]]; then
    echo ""
    warn "Tailscale necesita autenticación."
    info "Se va a ejecutar 'tailscale up'. Aparecerá un enlace que deberás"
    info "abrir en tu navegador para iniciar sesión con tu cuenta de Tailscale."
    echo ""
    if preguntar_si_no "¿Iniciar sesión en Tailscale ahora?"; then
        echo ""
        info "Ejecutando 'tailscale up'..."
        info "Abre el enlace que aparezca a continuación en tu navegador:"
        echo ""
        tailscale up 2>&1 | tee -a "$LOGFILE"
        echo ""

        sleep 3
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
        if [[ -n "$TAILSCALE_IP" ]]; then
            ok "Tailscale conectado. IP: ${BOLD}${TAILSCALE_IP}${NC}"
        else
            warn "No se pudo obtener la IP de Tailscale."
            warn "Ejecuta manualmente después: sudo tailscale up"
        fi
    else
        warn "Saltando autenticación de Tailscale."
        warn "Recuerda ejecutar después: sudo tailscale up"
    fi
fi

# ─────────────────────────────────────────────
# PASO 4: Ejecutar AceStream Engine
# ─────────────────────────────────────────────
header "INSTALAR ACESTREAM ENGINE"

CONTAINER_NAME="acestream"

# Comprobar si ya existe el contenedor
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    warn "Ya existe un contenedor '${CONTAINER_NAME}' (estado: ${CONTAINER_STATUS})"
    if preguntar_si_no "¿Eliminar y recrear el contenedor?"; then
        info "Eliminando contenedor existente..."
        docker stop "$CONTAINER_NAME" >> "$LOGFILE" 2>&1 || true
        docker rm "$CONTAINER_NAME" >> "$LOGFILE" 2>&1 || true
        ok "Contenedor eliminado"
    else
        if [[ "$CONTAINER_STATUS" != "running" ]]; then
            info "Arrancando contenedor existente..."
            docker start "$CONTAINER_NAME" >> "$LOGFILE" 2>&1
        fi
        ok "Usando contenedor existente"
    fi
fi

# Crear contenedor si no existe
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then

    # Intentar con la imagen principal
    info "Descargando imagen ${BOLD}${DOCKER_IMAGE}${NC}..."
    PULL_OK=false

    if docker pull "$DOCKER_IMAGE" >> "$LOGFILE" 2>&1; then
        PULL_OK=true
        ok "Imagen descargada: ${DOCKER_IMAGE}"
    else
        warn "No se pudo descargar ${DOCKER_IMAGE}"

        # Intentar imagen alternativa si existe
        if [[ -n "${DOCKER_IMAGE_ALT:-}" ]]; then
            info "Intentando imagen alternativa: ${BOLD}${DOCKER_IMAGE_ALT}${NC}..."
            if docker pull "$DOCKER_IMAGE_ALT" >> "$LOGFILE" 2>&1; then
                DOCKER_IMAGE="$DOCKER_IMAGE_ALT"
                PULL_OK=true
                ok "Imagen alternativa descargada: ${DOCKER_IMAGE}"
            else
                warn "Tampoco se pudo descargar ${DOCKER_IMAGE_ALT}"
            fi
        fi

        # Último recurso: intentar sin tag de arquitectura
        if ! $PULL_OK; then
            DOCKER_IMAGE_GENERIC="jopsis/acestream:latest"
            info "Último intento con: ${BOLD}${DOCKER_IMAGE_GENERIC}${NC}..."
            if docker pull "$DOCKER_IMAGE_GENERIC" >> "$LOGFILE" 2>&1; then
                DOCKER_IMAGE="$DOCKER_IMAGE_GENERIC"
                PULL_OK=true
                ok "Imagen descargada: ${DOCKER_IMAGE}"
            fi
        fi
    fi

    if ! $PULL_OK; then
        fail "No se pudo descargar ninguna imagen de AceStream compatible con ${ARCH}.
  Imágenes intentadas:
    - ${DOCKER_IMAGE}
    - ${DOCKER_IMAGE_ALT:-ninguna}
    - jopsis/acestream:latest
  Comprueba tu conexión y que Docker funciona: docker pull hello-world"
    fi

    info "Creando y arrancando contenedor con ${BOLD}${DOCKER_IMAGE}${NC}..."
    if docker run -d \
        --name "$CONTAINER_NAME" \
        -p 6878:6878 \
        -p 8621:8621 \
        -p 62062:62062 \
        --restart unless-stopped \
        "$DOCKER_IMAGE" >> "$LOGFILE" 2>&1; then
        ok "Contenedor '${CONTAINER_NAME}' creado y arrancado"
    else
        echo "--- Docker logs ---" >> "$LOGFILE"
        docker logs "$CONTAINER_NAME" >> "$LOGFILE" 2>&1 || true
        fail "Error al crear el contenedor. Puede que los puertos estén ocupados.
  Comprueba con: sudo lsof -i :6878"
    fi
fi

# ─────────────────────────────────────────────
# PASO 5: Verificar servicios
# ─────────────────────────────────────────────
header "VERIFICAR SERVICIOS"

ERRORES=0

# Docker
info "Comprobando Docker..."
if docker info >> "$LOGFILE" 2>&1; then
    ok "Docker funcionando"
else
    error "Docker no responde"
    ERRORES=$((ERRORES + 1))
fi

# Contenedor
info "Comprobando contenedor AceStream..."
sleep 2
CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not found")
if [[ "$CONTAINER_STATUS" == "running" ]]; then
    ok "Contenedor '${CONTAINER_NAME}' está corriendo"
    USED_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "desconocida")
    info "Imagen: ${USED_IMAGE}"
else
    error "Contenedor '${CONTAINER_NAME}' no está corriendo (estado: ${CONTAINER_STATUS})"
    warn "Logs del contenedor:"
    docker logs --tail 10 "$CONTAINER_NAME" 2>&1 || true
    ERRORES=$((ERRORES + 1))
fi

# Esperar a que el engine responda
info "Esperando a que AceStream Engine esté listo (hasta 90s)..."
ENGINE_READY=false
for i in $(seq 1 18); do
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:6878/webui/api/service?method=get_version 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        ENGINE_READY=true
        break
    fi
    if curl -sf http://localhost:6878/webui/ >> "$LOGFILE" 2>&1; then
        ENGINE_READY=true
        break
    fi
    printf "."
    sleep 5
done
echo ""

if $ENGINE_READY; then
    ok "AceStream Engine está listo y respondiendo en el puerto 6878"
else
    warn "AceStream Engine aún no responde en el puerto 6878."
    warn "Puede necesitar más tiempo de arranque (especialmente la primera vez)."
    warn "Verifica manualmente con:"
    echo "  curl http://localhost:6878/webui/api/service?method=get_version"
    echo "  docker logs ${CONTAINER_NAME}"
    ERRORES=$((ERRORES + 1))
fi

# Tailscale
info "Comprobando Tailscale..."
if [[ -z "$TAILSCALE_IP" ]]; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
fi
if [[ -n "$TAILSCALE_IP" ]]; then
    ok "Tailscale conectado: ${TAILSCALE_IP}"
else
    warn "Tailscale no está conectado. Ejecuta: sudo tailscale up"
    ERRORES=$((ERRORES + 1))
fi

if [[ $ERRORES -gt 0 ]]; then
    echo ""
    warn "Se encontraron ${ERRORES} problema(s). Revisa los mensajes anteriores."
fi

# ─────────────────────────────────────────────
# PASO 6: Resumen y URLs de ejemplo
# ─────────────────────────────────────────────
header "RESUMEN E INSTRUCCIONES DE USO"

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          INSTALACIÓN COMPLETADA                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}📡 Direcciones del servidor:${NC}"
echo ""
if [[ -n "$LOCAL_IP" ]]; then
    echo "  Red local (LAN):  ${BOLD}${LOCAL_IP}${NC}"
fi
if [[ -n "$TAILSCALE_IP" ]]; then
    echo "  Tailscale (VPN):  ${BOLD}${TAILSCALE_IP}${NC}"
fi
echo "  Puerto AceStream:  ${BOLD}6878${NC}"
echo ""

echo -e "${BOLD}🌐 Panel web de AceStream:${NC}"
echo ""
if [[ -n "$LOCAL_IP" ]]; then
    echo "  http://${LOCAL_IP}:6878/webui/"
fi
if [[ -n "$TAILSCALE_IP" ]]; then
    echo "  http://${TAILSCALE_IP}:6878/webui/"
fi
echo ""

echo -e "${BOLD}▶ Cómo reproducir un stream:${NC}"
echo ""
echo "  1. Consigue un AceStream ID, por ejemplo:"
echo "     acestream://dd1e67078381739d14beca697356ab76d49d1a2d"
echo ""
echo "  2. Extrae solo el ID (la parte después de acestream://):"
echo "     dd1e67078381739d14beca697356ab76d49d1a2d"
echo ""
echo "  3. Construye la URL y ábrela en VLC (Abrir ubicación de red):"
echo ""
IP_EJEMPLO="${TAILSCALE_IP:-${LOCAL_IP:-100.x.x.x}}"
echo "     ${BOLD}Stream directo (MPEG-TS) — más compatible:${NC}"
echo "     http://${IP_EJEMPLO}:6878/ace/getstream?id=TU_ID"
echo ""
echo "     ${BOLD}HLS (.m3u8) — si tu engine lo soporta:${NC}"
echo "     http://${IP_EJEMPLO}:6878/ace/manifest.m3u8?id=TU_ID"
echo ""
echo "  ${YELLOW}Nota:${NC} Si manifest.m3u8 no funciona, usa getstream."
echo "  Ambos funcionan en VLC."
echo ""

echo -e "${BOLD}📋 Ejemplo de playlist IPTV (.m3u):${NC}"
echo ""
echo '  #EXTM3U'
echo "  #EXTINF:-1,Canal 1"
echo "  http://${IP_EJEMPLO}:6878/ace/getstream?id=ID_CANAL_1"
echo "  #EXTINF:-1,Canal 2"
echo "  http://${IP_EJEMPLO}:6878/ace/getstream?id=ID_CANAL_2"
echo ""

echo -e "${BOLD}🔧 Comandos útiles:${NC}"
echo ""
echo "  Ver logs del engine:     docker logs -f ${CONTAINER_NAME}"
echo "  Reiniciar engine:        docker restart ${CONTAINER_NAME}"
echo "  Parar engine:            docker stop ${CONTAINER_NAME}"
echo "  Arrancar engine:         docker start ${CONTAINER_NAME}"
echo "  Estado Tailscale:        tailscale status"
echo "  IP Tailscale:            tailscale ip -4"
echo ""

# Guardar resumen en archivo
RESUMEN_PATH="/home/${REAL_USER}/acestream-info.txt"
{
    echo "=== AceStream Server Info ==="
    echo "Fecha de instalación: $(date)"
    echo "Imagen Docker: ${DOCKER_IMAGE}"
    echo "Contenedor: ${CONTAINER_NAME}"
    echo ""
    echo "IP Local: ${LOCAL_IP:-no detectada}"
    echo "IP Tailscale: ${TAILSCALE_IP:-no conectado}"
    echo "Puerto: 6878"
    echo ""
    echo "URL Stream:    http://<IP>:6878/ace/getstream?id=<ACESTREAM_ID>"
    echo "URL HLS:       http://<IP>:6878/ace/manifest.m3u8?id=<ACESTREAM_ID>"
    echo "Panel web:     http://<IP>:6878/webui/"
    echo "API versión:   http://<IP>:6878/webui/api/service?method=get_version"
    echo ""
    echo "Comandos:"
    echo "  docker logs -f ${CONTAINER_NAME}"
    echo "  docker restart ${CONTAINER_NAME}"
    echo "  tailscale status"
} > "$RESUMEN_PATH"
chown "${REAL_USER}:${REAL_USER}" "$RESUMEN_PATH" 2>/dev/null || true

ok "Resumen guardado en: ${RESUMEN_PATH}"
echo ""
info "Log completo de la instalación: ${LOGFILE}"
echo ""
echo -e "${GREEN}¡Todo listo! Abre VLC y prueba con una URL de AceStream.${NC}"
echo ""
