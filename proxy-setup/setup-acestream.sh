#!/usr/bin/env bash
#
# setup-acestream.sh — Instalación completa desde cero
#
# Docker + Tailscale + AceStream Engine + HTTPAceProxy
# + Smart Proxy (auto-limpieza de sesiones + Web UI)
# + acestream-ctl (CLI opcional)
#
# Fixes aplicados:
#   - Bridge network con DNS explícito (1.1.1.1) para evitar
#     que Tailscale MagicDNS rompa la resolución dentro del contenedor
#   - Healthcheck con wget (curl no existe en la imagen aceserve)
#   - Sin mem_limit (kernels RPi no soportan cgroups memory)
#   - UPnP deshabilitado (evita bucle infinito de port mapping)
#
# Uso: chmod +x setup-acestream.sh && sudo ./setup-acestream.sh
#

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOGFILE="/var/log/setup-acestream.log"
paso_actual=0; total_pasos=8

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

# ── Comprobaciones iniciales ──────────────────
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   ACESTREAM STACK — Instalación completa desde cero   ║${NC}"
echo -e "${BOLD}║   Engine + Proxy + Smart Proxy (Web UI) + CLI         ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

echo "=== Setup $(date) ===" > "$LOGFILE"

[[ $EUID -ne 0 ]] && { error "Ejecuta con: sudo ./setup-acestream.sh"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" == "root" ]] && REAL_USER="pi"
STACK_DIR="/home/${REAL_USER}/acestream-stack"
ARCH=$(uname -m)

info "Usuario: ${BOLD}${REAL_USER}${NC}   Arch: ${BOLD}${ARCH}${NC}"

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

COMPOSE_CMD=""
if docker compose version >> "$LOGFILE" 2>&1; then
    COMPOSE_CMD="docker compose"
    ok "Docker Compose OK"
else
    info "Instalando Docker Compose..."
    if log_cmd apt-get install -y docker-compose-plugin; then
        COMPOSE_CMD="docker compose"
    elif log_cmd apt-get install -y docker-compose; then
        COMPOSE_CMD="docker-compose"
    else
        fail "No se pudo instalar Docker Compose"
    fi
    ok "Docker Compose instalado"
fi

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

# ══════════════════════════════════════════════
# PASO 4
# ══════════════════════════════════════════════
header "GENERAR ARCHIVOS DEL STACK"

# Limpiar contenedores antiguos
for C in acestream acelink aceserve httpaceproxy acestream-proxy; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${C}$"; then
        info "Eliminando contenedor antiguo '${C}'..."
        docker stop "$C" >> "$LOGFILE" 2>&1 || true
        docker rm "$C" >> "$LOGFILE" 2>&1 || true
    fi
done

mkdir -p "${STACK_DIR}/proxy"

# ── docker-compose.yml ──
info "Generando docker-compose.yml..."
cat > "${STACK_DIR}/docker-compose.yml" << 'DCEOF'
## AceStream Stack para Raspberry Pi
##
## Bridge network con DNS explícito (Cloudflare 1.1.1.1).
## Tailscale reescribe /etc/resolv.conf con MagicDNS (100.100.100.100)
## que no resuelve dominios externos. Con bridge + dns:, Docker crea
## su propio resolv.conf dentro del contenedor, evitando el problema.
##
## Puertos mapeados al host:
##   6878  → AceStream Engine HTTP
##   8621  → AceStream P2P
##   62062 → AceStream API legacy
##   8888  → HTTPAceProxy (listas IPTV, stats)
##   8080  → Smart Proxy (web UI, auto-limpieza)

services:

  aceserve:
    image: jopsis/aceserve:latest
    container_name: aceserve
    ports:
      - "6878:6878"
      - "8621:8621"
      - "62062:62062"
    dns:
      - 1.1.1.1
      - 1.0.0.1
      - 8.8.8.8
    restart: unless-stopped
    volumes:
      - acestream-cache:/root/.ACEStream
    ## La imagen aceserve NO tiene curl, usamos wget para el healthcheck
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "--timeout=5", "http://127.0.0.1:6878/webui/api/service?method=get_version"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  httpaceproxy:
    image: jopsis/httpaceproxy:latest
    container_name: httpaceproxy
    ports:
      - "8888:8888"
    dns:
      - 1.1.1.1
      - 1.0.0.1
    restart: unless-stopped
    environment:
      ## En bridge, los servicios se encuentran por nombre Docker
      - ACESTREAM_HOST=aceserve
      - ACESTREAM_API_PORT=62062
      - ACESTREAM_HTTP_PORT=6878
      - MAX_CONNECTIONS=10
      - MAX_CONCURRENT_CHANNELS=3
    depends_on:
      aceserve:
        condition: service_healthy

  smartproxy:
    image: python:3-alpine
    container_name: acestream-proxy
    ports:
      - "8080:8080"
    restart: unless-stopped
    volumes:
      - ./proxy/proxy.py:/app/proxy.py:ro
    working_dir: /app
    command: python3 -u proxy.py
    environment:
      - ENGINE_HOST=aceserve
      - ENGINE_PORT=6878
      - PROXY_PORT=8080
      - HTTPACEPROXY_PORT=8888
      - SESSION_TIMEOUT=600
    depends_on:
      aceserve:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

volumes:
  acestream-cache:
    name: acestream-cache
DCEOF
ok "docker-compose.yml"

# ── proxy.py ──
info "Generando proxy.py (smart proxy + web UI)..."
cat > "${STACK_DIR}/proxy/proxy.py" << 'PYEOF'
#!/usr/bin/env python3
"""
acestream-smart-proxy
Proxy transparente con limpieza automática de sesiones y Web UI.
Pega http://<IP>:8080/ace/getstream?id=XXX en VLC y funciona.
Al cambiar de canal, para la sesión anterior automáticamente.
"""

import http.server
import json
import urllib.request
import urllib.parse
import socketserver
import threading
import time
import os

ENGINE_HOST = os.environ.get('ENGINE_HOST', 'aceserve')
ENGINE_PORT = int(os.environ.get('ENGINE_PORT', 6878))
PROXY_PORT = int(os.environ.get('PROXY_PORT', 8080))
HTTPACEPROXY_PORT = int(os.environ.get('HTTPACEPROXY_PORT', 8888))
SESSION_TIMEOUT = int(os.environ.get('SESSION_TIMEOUT', 600))

ENGINE_URL = f"http://{ENGINE_HOST}:{ENGINE_PORT}"

sessions = {}
sessions_lock = threading.Lock()


WEB_UI = r"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AceStream</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,system-ui,sans-serif;background:#0f1117;color:#e1e4e8;min-height:100vh;padding:16px}
.c{max-width:520px;margin:0 auto}
h1{font-size:1.5rem;margin-bottom:20px;color:#fff}
h1 span{color:#58a6ff}
.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:16px;margin-bottom:16px}
.card h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.5px;color:#8b949e;margin-bottom:12px}
input[type=text]{width:100%;padding:12px;background:#0d1117;border:1px solid #30363d;border-radius:8px;color:#e1e4e8;font-size:16px;margin-bottom:12px;outline:none}
input[type=text]:focus{border-color:#58a6ff}
input[type=text]::placeholder{color:#484f58}
.btn{display:inline-block;padding:10px 20px;background:#238636;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;text-decoration:none;text-align:center;width:100%;font-weight:600}
.btn:active{background:#2ea043}
.btn-outline{background:transparent;border:1px solid #30363d;color:#58a6ff}
.btn-outline:active{background:#161b22}
.url-box{background:#0d1117;border:1px solid #30363d;border-radius:8px;padding:12px;margin:12px 0;word-break:break-all;font-family:monospace;font-size:13px;color:#79c0ff;position:relative}
.url-box .copy{position:absolute;top:8px;right:8px;background:#30363d;border:none;color:#e1e4e8;padding:4px 10px;border-radius:6px;cursor:pointer;font-size:12px}
.url-box .copy:active{background:#58a6ff}
.hidden{display:none}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
.dot-green{background:#3fb950}
.dot-red{background:#f85149}
.dot-yellow{background:#d29922}
.status-row{display:flex;align-items:center;padding:6px 0;font-size:14px}
.status-label{color:#8b949e;min-width:80px}
.lists a{display:block;padding:10px 12px;color:#58a6ff;text-decoration:none;border-bottom:1px solid #21262d;font-size:14px}
.lists a:last-child{border-bottom:none}
.lists a:active{background:#1c2128}
.lists small{color:#8b949e;float:right}
.mt{margin-top:12px}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#238636;color:#fff;padding:10px 24px;border-radius:8px;font-size:14px;opacity:0;transition:opacity .3s;pointer-events:none;z-index:99}
.toast.show{opacity:1}
</style>
</head>
<body>
<div class="c">
<h1><span>&#9654;</span> AceStream</h1>

<div class="card">
<h2>Reproducir stream</h2>
<input type="text" id="sid" placeholder="Pega el AceStream ID o acestream://..." autofocus>
<button class="btn" onclick="genUrl()">Generar URL</button>
<div id="res" class="hidden">
<div class="url-box">
<span id="url"></span>
<button class="copy" onclick="copyUrl()">Copiar</button>
</div>
<div class="mt" style="display:flex;gap:8px">
<a class="btn btn-outline" style="flex:1" onclick="openVlc()">Abrir en VLC</a>
<a class="btn btn-outline" style="flex:1" onclick="stopStream()">Parar stream</a>
</div>
</div>
</div>

<div class="card">
<h2>Listas IPTV para VLC</h2>
<div class="lists" id="lists"></div>
</div>

<div class="card">
<h2>Estado</h2>
<div id="st">Cargando...</div>
</div>

</div>
<div class="toast" id="toast"></div>
<script>
const H='{{HOST}}',PP={{PROXY_PORT}},EP={{ENGINE_PORT}},AP={{HTTPACEPROXY_PORT}};
let curId='';

function genUrl(){
  let id=document.getElementById('sid').value.trim();
  if(id.startsWith('acestream://'))id=id.slice(12);
  if(!id){toast('Pega un ID primero');return}
  curId=id;
  const u='http://'+H+':'+PP+'/ace/getstream?id='+id;
  document.getElementById('url').textContent=u;
  document.getElementById('res').classList.remove('hidden');
}

function copyUrl(){
  const u=document.getElementById('url').textContent;
  if(navigator.clipboard)navigator.clipboard.writeText(u).then(()=>toast('Copiado'));
  else{const t=document.createElement('textarea');t.value=u;document.body.appendChild(t);t.select();document.execCommand('copy');document.body.removeChild(t);toast('Copiado')}
}

function openVlc(){
  const u=document.getElementById('url').textContent;
  window.location.href='vlc://'+u.replace('http://','');
}

async function stopStream(){
  try{await fetch('/stop');toast('Stream parado')}catch(e){toast('Error al parar')}
}

function toast(m){
  const t=document.getElementById('toast');t.textContent=m;t.classList.add('show');
  setTimeout(()=>t.classList.remove('show'),2000);
}

const iptvLists=[
  ['Todo combinado','aio','Todas las fuentes'],
  ['Deportes (NewEra)','newera','322 canales'],
  ['Seleccion (Elcano)','elcano','71 canales'],
  ['AceStream API','acepl','1000+ canales'],
];
const ld=document.getElementById('lists');
iptvLists.forEach(([n,p,d])=>{
  const a=document.createElement('a');
  a.href='http://'+H+':'+AP+'/'+p;
  a.innerHTML=n+'<small>'+d+'</small>';
  ld.appendChild(a);
});

async function loadStatus(){
  try{
    const r=await fetch('/status');const d=await r.json();
    let h='';
    h+='<div class="status-row"><span class="dot '+(d.engine.online?'dot-green':'dot-red')+'"></span>';
    h+='<span class="status-label">Engine</span>';
    h+=d.engine.online?(d.engine.version||'online'):'offline';
    h+='</div>';
    const sk=Object.keys(d.sessions);
    h+='<div class="status-row"><span class="dot '+(sk.length?'dot-green':'dot-yellow')+'"></span>';
    h+='<span class="status-label">Streams</span>';
    h+=sk.length?sk.length+' activo(s)':'ninguno';
    h+='</div>';
    sk.forEach(ip=>{
      const s=d.sessions[ip];
      h+='<div style="padding:4px 0 4px 14px;font-size:13px;color:#8b949e">';
      h+=ip+' &rarr; '+s.id.substring(0,12)+'... ('+s.started+')';
      h+='</div>';
    });
    document.getElementById('st').innerHTML=h;
  }catch(e){document.getElementById('st').textContent='Sin conexion'}
}
loadStatus();setInterval(loadStatus,10000);

document.getElementById('sid').addEventListener('keydown',e=>{if(e.key==='Enter')genUrl()});
</script>
</body>
</html>"""


def engine_request(path, timeout=10):
    try:
        req = urllib.request.Request(f"{ENGINE_URL}{path}")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def stop_session(client_key):
    with sessions_lock:
        session = sessions.pop(client_key, None)
    if session and session.get('command_url'):
        try:
            cmd = session['command_url']
            # Rewrite to internal engine address
            parsed = urllib.parse.urlparse(cmd)
            internal = f"http://{ENGINE_HOST}:{ENGINE_PORT}{parsed.path}"
            req = urllib.request.Request(f"{internal}?method=stop")
            urllib.request.urlopen(req, timeout=5)
            print(f"[stop] Session {session.get('id','?')[:12]} stopped for {client_key}")
        except Exception as e:
            print(f"[stop] Failed for {client_key}: {e}")


class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {self.client_address[0]} {fmt % args}")

    def get_client_host(self):
        h = self.headers.get('Host', '')
        return h.split(':')[0] if h else '127.0.0.1'

    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        path = p.path.rstrip('/')

        if path in ('', '/'):
            self.serve_ui()
        elif path in ('/ace/getstream', '/ace/manifest.m3u8'):
            self.handle_stream(p)
        elif path == '/status':
            self.handle_status()
        elif path == '/stop':
            self.handle_stop()
        elif path == '/health':
            self.send_json({'status': 'ok'})
        else:
            self.send_error(404)

    def handle_stream(self, parsed):
        params = urllib.parse.parse_qs(parsed.query)
        sid = params.get('id', [None])[0]
        if not sid:
            self.send_error(400, "Missing 'id' parameter")
            return

        sid = sid.strip().removeprefix('acestream://')
        client_ip = self.client_address[0]
        client_host = self.get_client_host()
        endpoint = parsed.path

        # Stop previous session for this client
        with sessions_lock:
            had_previous = client_ip in sessions
        if had_previous:
            stop_session(client_ip)
            time.sleep(1.5)

        # Start session via format=json to get control URLs
        data = engine_request(f"{endpoint}?id={sid}&format=json", timeout=30)

        playback_url = ''
        command_url = ''
        stat_url = ''

        if data and not data.get('error') and data.get('response'):
            resp = data['response']
            playback_url = resp.get('playback_url', '')
            command_url = resp.get('command_url', '')
            stat_url = resp.get('stat_url', '')

        # Rewrite playback URL: engine returns internal addresses,
        # we need the client-facing host but keep engine port (6878)
        # because the client connects to the engine port mapped on the host
        if playback_url:
            for old_host in [f"{ENGINE_HOST}:{ENGINE_PORT}",
                             f"127.0.0.1:{ENGINE_PORT}",
                             f"localhost:{ENGINE_PORT}"]:
                playback_url = playback_url.replace(
                    old_host, f"{client_host}:{ENGINE_PORT}")

        # Fallback if format=json didn't work
        if not playback_url:
            playback_url = f"http://{client_host}:{ENGINE_PORT}{endpoint}?id={sid}"

        # Save session
        with sessions_lock:
            sessions[client_ip] = {
                'id': sid,
                'command_url': command_url,
                'stat_url': stat_url,
                'playback_url': playback_url,
                'started': time.time(),
                'started_str': time.strftime('%H:%M:%S'),
            }

        print(f"[play] {sid[:16]}... -> {client_ip}")

        # Redirect VLC to the engine stream
        self.send_response(302)
        self.send_header('Location', playback_url)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

    def handle_status(self):
        ver = engine_request('/webui/api/service?method=get_version')
        with sessions_lock:
            active = {
                ip: {'id': s['id'], 'started': s['started_str'],
                     'playback_url': s.get('playback_url', '')}
                for ip, s in sessions.items()
            }
        self.send_json({
            'engine': {
                'url': ENGINE_URL,
                'online': ver is not None,
                'version': ver.get('result', {}).get('version') if ver else None,
            },
            'sessions': active,
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
        })

    def handle_stop(self):
        client_ip = self.client_address[0]
        stop_session(client_ip)
        self.send_json({'status': 'stopped', 'client': client_ip})

    def serve_ui(self):
        ch = self.get_client_host()
        page = WEB_UI.replace('{{HOST}}', ch)
        page = page.replace('{{ENGINE_PORT}}', str(ENGINE_PORT))
        page = page.replace('{{PROXY_PORT}}', str(PROXY_PORT))
        page = page.replace('{{HTTPACEPROXY_PORT}}', str(HTTPACEPROXY_PORT))
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(page.encode())

    def send_json(self, data):
        body = json.dumps(data, indent=2, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def cleanup_thread():
    while True:
        time.sleep(60)
        now = time.time()
        with sessions_lock:
            stale = [ip for ip, s in sessions.items()
                     if now - s.get('started', 0) > SESSION_TIMEOUT]
        for ip in stale:
            stop_session(ip)
            print(f"[cleanup] Stale session for {ip}")


if __name__ == '__main__':
    threading.Thread(target=cleanup_thread, daemon=True).start()
    print(f"Smart proxy :{PROXY_PORT} -> engine {ENGINE_URL}")
    server = ThreadedServer(('0.0.0.0', PROXY_PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
PYEOF
ok "proxy.py"

ok "Archivos generados en ${STACK_DIR}"

# ══════════════════════════════════════════════
# PASO 5
# ══════════════════════════════════════════════
header "DESCARGAR IMÁGENES Y LEVANTAR STACK"

info "Descargando jopsis/aceserve:latest..."
log_cmd docker pull jopsis/aceserve:latest || fail "Error descargando aceserve"
ok "aceserve"

info "Descargando jopsis/httpaceproxy:latest..."
log_cmd docker pull jopsis/httpaceproxy:latest || fail "Error descargando httpaceproxy"
ok "httpaceproxy"

info "Descargando python:3-alpine..."
log_cmd docker pull python:3-alpine || fail "Error descargando python:3-alpine"
ok "python:3-alpine (smart proxy)"

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
# PASO 6
# ══════════════════════════════════════════════
header "INSTALAR ACESTREAM-CTL"

CTL="/usr/local/bin/acestream-ctl"
cat > "$CTL" << 'CTLEOF'
#!/usr/bin/env bash
set -euo pipefail
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'; R='\033[0;31m'
EP="${ACESTREAM_PORT:-6878}"; PP="${ACESTREAM_PROXY_PORT:-8080}"; AP="${ACESTREAM_LISTS_PORT:-8888}"

get_ip(){ tailscale ip -4 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }

case "${1:-help}" in
status)
    echo -e "${B}Estado AceStream${N}"; echo ""
    code=$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${EP}/webui/api/service?method=get_version" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && echo -e "  ${G}●${N} Engine :${EP}" || echo -e "  ${R}●${N} Engine :${EP} offline"
    code=$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PP}/health" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && echo -e "  ${G}●${N} Smart Proxy :${PP}" || echo -e "  ${R}●${N} Smart Proxy :${PP} offline"
    code=$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AP}/stat" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && echo -e "  ${G}●${N} HTTPAceProxy :${AP}" || echo -e "  ${R}●${N} HTTPAceProxy :${AP} offline"
    echo ""
    sessions=$(curl -sf "http://127.0.0.1:${PP}/status" 2>/dev/null || echo "")
    if [[ -n "$sessions" ]]; then
        echo -e "  ${B}Sesiones:${N}"
        echo "$sessions" | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=d.get('sessions',{})
if not s: print('    Ninguna')
for ip,v in s.items(): print(f'    {ip} -> {v[\"id\"][:16]}... ({v[\"started\"]})')
" 2>/dev/null || echo "    (no disponible)"
    fi
    echo ""
    echo -e "  ${B}Contenedores:${N}"
    docker ps --filter "name=aceserve" --filter "name=httpaceproxy" --filter "name=acestream-proxy" \
        --format "    {{.Names}}  {{.Status}}" 2>/dev/null || echo "    (docker no disponible)"
    echo ""
    ;;
url)
    id="${2:-}"; [[ -z "$id" ]] && { echo "Uso: acestream-ctl url <ID>"; exit 1; }
    id="${id#acestream://}"; ip=$(get_ip)
    echo ""
    echo -e "${B}URLs:${N}"
    echo "  VLC:     http://${ip}:${PP}/ace/getstream?id=${id}"
    echo "  Engine:  http://${ip}:${EP}/ace/getstream?id=${id}"
    echo "  Web UI:  http://${ip}:${PP}/"
    echo ""
    ;;
lists)
    ip=$(get_ip)
    echo ""
    echo -e "${B}Listas IPTV (abre en VLC):${N}"
    echo "  http://${ip}:${AP}/aio          Todo combinado"
    echo "  http://${ip}:${AP}/newera       322 canales deportivos"
    echo "  http://${ip}:${AP}/elcano       71 canales seleccionados"
    echo "  http://${ip}:${AP}/acepl        1000+ canales"
    echo ""
    ;;
web)  ip=$(get_ip); echo "http://${ip}:${PP}/" ;;
logs) cd ~/acestream-stack && docker compose logs -f --tail 50 ;;
restart) cd ~/acestream-stack && docker compose restart ;;
stop) curl -sf "http://127.0.0.1:${PP}/stop" > /dev/null 2>&1 && echo "Stream parado" || echo "Sin stream activo" ;;
help|--help|-h|*)
    echo ""
    echo -e "${B}acestream-ctl${N} — Control de AceStream (opcional)"
    echo ""
    echo "  status     Estado de servicios y sesiones"
    echo "  url <ID>   Generar URLs"
    echo "  lists      Listas IPTV"
    echo "  web        URL de la Web UI"
    echo "  stop       Parar stream activo"
    echo "  logs       Logs en tiempo real"
    echo "  restart    Reiniciar stack"
    echo "  help       Esta ayuda"
    echo ""
    ;;
esac
CTLEOF
chmod +x "$CTL"
ok "acestream-ctl instalado"

# ══════════════════════════════════════════════
# PASO 7
# ══════════════════════════════════════════════
header "VERIFICAR SERVICIOS"

ERRORES=0

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
    # Probar con wget ya que la imagen no tiene curl
    if docker exec aceserve wget -q --spider --timeout=5 https://www.google.com >> "$LOGFILE" 2>&1; then
        DNS_OK=true
    # Fallback: probar resolución con getent si existe
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

info "Verificando Smart Proxy..."
sleep 5
c=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/health 2>/dev/null || echo 000)
[[ "$c" == "200" ]] && ok "Smart Proxy :8080" || { warn "Smart Proxy arrancando"; ERRORES=$((ERRORES+1)); }

info "Verificando HTTPAceProxy..."
sleep 2
c=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:8888/stat 2>/dev/null || echo 000)
[[ "$c" == "200" ]] && ok "HTTPAceProxy :8888" || { warn "HTTPAceProxy esperando healthcheck"; ERRORES=$((ERRORES+1)); }

[[ -z "$TAILSCALE_IP" ]] && TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
[[ -n "$TAILSCALE_IP" ]] && ok "Tailscale: ${TAILSCALE_IP}" || { warn "Tailscale no conectado"; ERRORES=$((ERRORES+1)); }

[[ $ERRORES -gt 0 ]] && warn "${ERRORES} servicio(s) aún arrancando. Espera 1-2 min."

# ══════════════════════════════════════════════
# PASO 8
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
echo -e "${BOLD}📺 Listas IPTV (abre en VLC):${NC}"
echo ""
echo "  http://${IP}:8888/aio          Todo combinado"
echo "  http://${IP}:8888/newera       Deportes (322 canales)"
echo "  http://${IP}:8888/elcano       Selección (71 canales)"
echo "  http://${IP}:8888/acepl        API (1000+ canales)"
echo ""
echo -e "${BOLD}🌐 Paneles:${NC}"
echo ""
echo "  Web UI:           http://${IP}:8080"
echo "  Engine settings:  http://${IP}:6878/webui/app/dobrinkos/server"
echo "  Proxy stats:      http://${IP}:8888/stat"
echo ""
echo -e "${BOLD}🔧 Gestión:${NC}"
echo ""
echo "  acestream-ctl status        Estado de todo"
echo "  acestream-ctl lists         Listas IPTV"
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
=== AceStream Stack ===
Instalado: $(date)
Directorio: ${STACK_DIR}

IP Local:     ${LOCAL_IP:-?}
IP Tailscale: ${TAILSCALE_IP:-no conectado}

== URL para VLC ==
http://<IP>:8080/ace/getstream?id=<ID>

== Web UI ==
http://<IP>:8080

== Listas IPTV ==
http://<IP>:8888/aio
http://<IP>:8888/newera
http://<IP>:8888/elcano
http://<IP>:8888/acepl

== Paneles ==
Engine:  http://<IP>:6878/webui/app/dobrinkos/server
Stats:   http://<IP>:8888/stat

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
