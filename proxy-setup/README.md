<p align="center">
  <img src="aceberry/logo.png" alt="AceBerry" width="180">
</p>

# AceStream Stack para Raspberry Pi

Un script instala todo. Después, pegas una URL en VLC y funciona.

---

## Qué hace

Instala 3 servicios en Docker + herramienta CLI:

| Puerto | Servicio | Para qué |
|--------|----------|----------|
| **8080** | **AceBerry** | Tu punto de entrada. Auto-limpia sesiones al cambiar canal |
| 6878 | AceStream Engine | Motor P2P (lo usa el proxy internamente) |
| 8888 | HTTPAceProxy | Proxy de streams, estadísticas |

Cuando cambias de canal en VLC, AceBerry para la sesión anterior automáticamente via la API del engine. Sin bloqueos.

### Problemas conocidos que resuelve

- **DNS roto por Tailscale**: Tailscale reescribe `/etc/resolv.conf` con MagicDNS (`100.100.100.100`) que no resuelve dominios externos dentro de Docker. El stack usa bridge network con DNS explícito (Cloudflare `1.1.1.1`) que Docker inyecta directamente en el contenedor.
- **Healthcheck falla**: La imagen `jopsis/aceserve` no tiene `curl`. El healthcheck usa `wget`.
- **mem_limit no soportado**: Kernels de RPi típicos no soportan cgroups memory. Eliminado.
- **UPnP en bucle infinito**: No necesario con Tailscale. Se puede deshabilitar editando el compose.

---

## Requisitos

- Raspberry Pi 4 (4 GB recomendado) con **Raspberry Pi OS Lite 64-bit**
- Conexión a internet (Ethernet recomendado)
- Cuenta de **Tailscale** creada en [tailscale.com/start](https://tailscale.com/start)
- Acceso SSH

---

## Instalación

### Instalación con un comando (recomendado)

Desde tu PC, conectado por SSH a la Raspberry Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/AlexAdiaconitei/aceberry/main/proxy-setup/install.sh | sudo bash
```

Lo único manual: autenticarte en Tailscale. Todo lo demás automático (~10 min). Re-ejecutable si algo falla.

### Actualizar / reinstalar (sin reinstalar Docker ni Tailscale)

Si Docker y Tailscale ya están instalados, usa `--quick` para saltarlos:

```bash
curl -fsSL https://raw.githubusercontent.com/AlexAdiaconitei/aceberry/main/proxy-setup/install.sh | sudo bash -s -- --quick
```

---

## Uso diario

### Flujo principal

```
http://<TU_IP_TAILSCALE>:8080/ace/getstream?id=HASH_DEL_ACESTREAM
```

Pega en VLC → Abrir ubicación de red. Cambia el ID para cambiar de canal.

### Web UI (desde el móvil)

Abre `http://<TU_IP>:8080` en el navegador. Pega el ID, copia la URL, abre en VLC.

---

## CLI (opcional)

```bash
aceberry-ctl status      # Estado de servicios + sesiones
aceberry-ctl url <ID>    # Genera URLs
aceberry-ctl logs        # Logs en tiempo real
aceberry-ctl restart     # Reiniciar stack
aceberry-ctl stop        # Parar stream activo
```

---

## Gestión del stack

```bash
cd ~/acestream-stack
docker compose logs -f                        # Logs
docker compose restart                        # Reiniciar
docker compose down                           # Parar
docker compose up -d                          # Levantar
docker compose pull && docker compose up -d   # Actualizar
```

### Limpiar cache

```bash
cd ~/acestream-stack && docker compose down
docker volume rm acestream-cache
cd ~/acestream-stack && docker compose up -d
```

---

## Ajustes (docker-compose.yml)

Edita `~/acestream-stack/docker-compose.yml`, aplica con `docker compose up -d`.

**Canales simultáneos**: `MAX_CONCURRENT_CHANNELS=3` (bajar a 1-2 si notas lag)

**Timeout sesiones**: `SESSION_TIMEOUT=600` (AceBerry, en segundos)

**DNS**: Por defecto Cloudflare `1.1.1.1`. Puedes añadir o cambiar a Google `8.8.8.8`.

---

## Solución de problemas

### "No address associated with hostname" en logs

Si aún aparece, el DNS dentro del contenedor sigue fallando. Verifica:

```bash
docker exec aceserve cat /etc/resolv.conf
```

Debería mostrar `nameserver 1.1.1.1`. Si muestra `100.100.100.100`, Docker no está inyectando los DNS. Prueba `docker compose down && docker compose up -d`.

### Healthcheck falla (unhealthy)

```bash
# Comprobar si wget existe en la imagen
docker exec aceserve which wget

# Test manual
docker exec aceserve wget -q --spider http://127.0.0.1:6878/webui/api/service?method=get_version
```

### UPnP llena los logs

Añade al command de aceserve en docker-compose.yml:

```yaml
command: ["--client-console", "--bind-all", "--disable-upnp"]
```

### No accedo desde fuera de casa

Verifica Tailscale en ambos dispositivos: `tailscale status`.

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
 │                                     │
 │  :8080  AceBerry                     │ ← Pegas la URL aquí
 │              │                      │
 │              ▼                      │
 │  :6878  AceStream Engine            │ ← Motor P2P
 │                                     │
 │  :8888  HTTPAceProxy                │ ← Proxy de streams, stats
 │                                     │
 └─────────────────────────────────────┘
```

---

## Otros métodos de instalación

### Manual (scp)

Si prefieres copiar los archivos manualmente desde tu PC:

```bash
scp -r proxy-setup/ pi@raspberrypi.local:~/
ssh pi@raspberrypi.local "sudo ./proxy-setup/setup-aceberry.sh"
```
