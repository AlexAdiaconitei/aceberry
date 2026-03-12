# 🍓 AceBerry

**Servidor AceStream en Raspberry Pi con acceso remoto por VPN.**

Un script instala todo. Después, pegas una URL en VLC y funciona desde cualquier lugar.

---

## ¿Qué es?

AceBerry convierte tu Raspberry Pi en un servidor de streaming P2P basado en AceStream, accesible de forma remota a través de Tailscale. Incluye un smart proxy con Web UI, gestión automática de sesiones y soporte para listas IPTV.

---

## Arquitectura

```
iPhone / PC (VLC)
      │
 Tailscale VPN
      │
 Raspberry Pi
      │
 ┌────┴───────────────────────────────┐
 │  Docker bridge network             │
 │  DNS: 1.1.1.1 (no Tailscale DNS)  │
 │                                    │
 │  :8080  Smart Proxy + Web UI       │ ← Punto de entrada
 │              │                     │
 │              ▼                     │
 │  :6878  AceStream Engine           │ ← Motor P2P
 │                                    │
 │  :8888  HTTPAceProxy               │ ← Listas IPTV
 │                                    │
 └────────────────────────────────────┘
```

| Puerto | Servicio | Función |
|--------|----------|---------|
| **8080** | **Smart Proxy + Web UI** | Punto de entrada. Auto-limpia sesiones al cambiar canal |
| 6878 | AceStream Engine | Motor P2P (uso interno) |
| 8888 | HTTPAceProxy | Listas IPTV y estadísticas |

---

## Requisitos

- Raspberry Pi 3/4/5 con **Raspberry Pi OS Lite 64-bit** (recomendado 4 GB RAM)
- Conexión a internet (Ethernet recomendado)
- Cuenta de [Tailscale](https://tailscale.com/start) creada previamente
- Acceso SSH a la Raspberry Pi

---

## Instalación

```bash
scp proxy-setup/setup-acestream.sh pi@raspberrypi.local:~/
ssh pi@raspberrypi.local
chmod +x setup-acestream.sh
sudo ./setup-acestream.sh
```

Lo único manual: autenticarte en Tailscale cuando el script lo pida. Todo lo demás es automático (~10 min). El script es re-ejecutable si algo falla.

---

## Uso

### Reproducir un canal

```
http://<TU_IP_TAILSCALE>:8080/ace/getstream?id=<HASH_ACESTREAM>
```

Pega esa URL en VLC → *Abrir ubicación de red*. Cambia el `id` para cambiar de canal. Al hacerlo, el proxy para la sesión anterior automáticamente, sin bloqueos.

### Web UI

Abre `http://<TU_IP>:8080` en el navegador. Pega el ID, copia la URL o ábrela directamente en VLC.

### Listas IPTV

| URL | Contenido |
|-----|-----------|
| `http://<IP>:8888/aio` | Todo combinado |
| `http://<IP>:8888/newera` | 322 canales deportivos |
| `http://<IP>:8888/elcano` | 71 canales seleccionados |
| `http://<IP>:8888/acepl` | 1000+ canales |

---

## CLI

```bash
acestream-ctl status      # Estado de servicios y sesiones activas
acestream-ctl url <ID>    # Genera URLs para un ID
acestream-ctl lists       # Muestra URLs de listas IPTV
acestream-ctl logs        # Logs en tiempo real
acestream-ctl restart     # Reiniciar el stack
acestream-ctl stop        # Parar el stream activo
```

---

## Gestión del stack

```bash
cd ~/acestream-stack

docker compose logs -f                        # Ver logs
docker compose restart                        # Reiniciar
docker compose down                           # Parar
docker compose up -d                          # Levantar
docker compose pull && docker compose up -d   # Actualizar imágenes
```

### Limpiar caché (problemas de calidad)

```bash
cd ~/acestream-stack && docker compose down
docker volume rm acestream-cache
docker compose up -d
```

---

## Ajustes

Edita `~/acestream-stack/docker-compose.yml` y aplica con `docker compose up -d`.

| Variable | Por defecto | Descripción |
|----------|-------------|-------------|
| `MAX_CONCURRENT_CHANNELS` | `3` | Bajar a 1-2 si hay lag |
| `SESSION_TIMEOUT` | `600` | Segundos hasta limpiar sesión inactiva |
| DNS en compose | `1.1.1.1` | Cloudflare. Puedes añadir `8.8.8.8` |

---

## Solución de problemas

**DNS falla dentro del contenedor**
```bash
docker exec aceserve cat /etc/resolv.conf
# Debe mostrar: nameserver 1.1.1.1
# Si muestra 100.100.100.100 → docker compose down && docker compose up -d
```

**Healthcheck `unhealthy`**
```bash
docker exec aceserve wget -q --spider http://127.0.0.1:6878/webui/api/service?method=get_version
```

**UPnP llena los logs**

Añade en `docker-compose.yml` bajo el servicio `aceserve`:
```yaml
command: ["--client-console", "--bind-all", "--disable-upnp"]
```

**No hay acceso desde fuera de casa**
```bash
tailscale status   # Verificar en ambos dispositivos
```

---

## Versiones

| Versión | Descripción |
|---------|-------------|
| [`proxy-setup/`](./proxy-setup/) | ✅ Recomendada — Stack completo con smart proxy, Web UI y CLI |
| [`single-container/`](./single-container/) | Instalación simple de un solo contenedor |
