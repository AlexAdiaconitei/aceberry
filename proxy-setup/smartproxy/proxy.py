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


def find_active_session(sid):
    """Return an existing session dict for sid that owns the engine session, or None."""
    with sessions_lock:
        for s in sessions.values():
            if s.get('id') == sid and s.get('command_url'):
                return dict(s)
    return None


def stop_session(client_key):
    with sessions_lock:
        session = sessions.pop(client_key, None)
    if session and session.get('command_url'):
        # Only stop engine if no other session is using the same stream ID
        sid = session.get('id')
        with sessions_lock:
            still_active = any(
                s.get('id') == sid and s.get('command_url')
                for s in sessions.values()
            )
        if still_active:
            print(f"[stop] Skip engine stop — {sid[:12]} still used by another client")
            return
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

        # Reuse existing engine session if this stream ID is already active
        existing = find_active_session(sid)
        if existing:
            with sessions_lock:
                sessions[client_ip] = {
                    'id': sid,
                    'command_url': None,  # sentinel: don't stop engine on cleanup
                    'stat_url': existing.get('stat_url', ''),
                    'playback_url': existing['playback_url'],
                    'started': time.time(),
                    'started_str': time.strftime('%H:%M:%S'),
                }
            print(f"[play] {sid[:16]}... -> {client_ip} (reused session)")
            self.send_response(302)
            self.send_header('Location', existing['playback_url'])
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            return

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
