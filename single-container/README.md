<p align="center">
  <img src="../proxy-setup/aceberry/logo.png" alt="AceBerry" width="180">
</p>

# AceStream en Raspberry Pi — Contenedor simple

> **¿Buscas la versión completa?** El directorio [`proxy-setup/`](../proxy-setup/README.md) incluye AceBerry con limpieza automática de sesiones, Web UI y CLI. Es la versión recomendada.

Servidor de AceStream con Docker y Tailscale en una Raspberry Pi.
Reproduce streams AceStream como URLs en VLC desde cualquier lugar.

---

## Qué hace el script

El script `setup-acestream.sh` instala y configura automáticamente:

1. **Actualización del sistema** (apt update/upgrade)
2. **Docker** — para ejecutar AceStream como contenedor
3. **Tailscale** — VPN para acceder desde fuera de casa sin abrir puertos
4. **AceStream Engine** — imagen Docker compatible con ARM64 (jopsis/acestream)
5. **Verificación** de que todo funciona
6. **Resumen** con las URLs listas para usar

El script detecta automáticamente la arquitectura de tu Raspberry Pi y selecciona la imagen Docker correcta. Si la imagen principal falla, intenta alternativas automáticamente.

---

## Requisitos previos

### Hardware

- Raspberry Pi 4 (2 GB mínimo, 4 GB recomendado)
- Tarjeta microSD con **Raspberry Pi OS Lite 64-bit** instalado
- Conexión a internet (Ethernet recomendado para streams estables)

### Cuentas necesarias

| Servicio | Para qué | Dónde crearla |
|----------|----------|---------------|
| **Tailscale** | Acceder al servidor desde fuera de casa | [tailscale.com/start](https://tailscale.com/start) |

> Crea tu cuenta de Tailscale **antes** de ejecutar el script. Durante la instalación se te pedirá iniciar sesión.

### Acceso SSH

Necesitas poder conectarte por SSH a tu Raspberry Pi. Si usas Raspberry Pi Imager, activa SSH en las opciones avanzadas al flashear la tarjeta SD.

---

## Instalación

Copia el script a la Raspberry Pi y ejecútalo:

```bash
scp setup-acestream.sh pi@raspberrypi.local:~/
ssh pi@raspberrypi.local "chmod +x setup-acestream.sh && sudo ./setup-acestream.sh"
```

> Sustituye `raspberrypi.local` por la IP de tu Raspberry si es necesario.

Lo único manual: autenticarte en Tailscale. Todo lo demás automático. Re-ejecutable si algo falla.

---

## Después de la instalación

### Verificar que todo funciona

Abre en un navegador:

```
http://<IP_TAILSCALE>:6878/webui/
```

Si ves el panel de AceStream, todo está funcionando.

### Reproducir un stream

1. Consigue un AceStream ID (ejemplo: `acestream://dd1e67078381739d14beca697356ab76d49d1a2d`)
2. Copia solo el hash: `dd1e67078381739d14beca697356ab76d49d1a2d`
3. Abre en VLC → "Abrir ubicación de red" → pega la URL:

```
http://<IP_TAILSCALE>:6878/ace/getstream?id=dd1e67078381739d14beca697356ab76d49d1a2d
```

> Si `manifest.m3u8` no funciona, usa `getstream`. Ambos funcionan en VLC.

---

## Comandos de mantenimiento

| Acción | Comando |
|--------|---------|
| Ver logs del engine | `docker logs -f acestream` |
| Reiniciar engine | `docker restart acestream` |
| Parar engine | `docker stop acestream` |
| Arrancar engine | `docker start acestream` |
| Estado de Tailscale | `tailscale status` |
| Ver IP de Tailscale | `tailscale ip -4` |

### Actualizar AceStream

```bash
docker pull jopsis/acestream:arm64-latest
docker stop acestream && docker rm acestream
docker run -d \
  --name acestream \
  -p 6878:6878 \
  -p 8621:8621 \
  -p 62062:62062 \
  --restart unless-stopped \
  jopsis/acestream:arm64-latest
```

---

## Imágenes Docker compatibles

| Arquitectura | Imagen principal | Alternativa |
|---|---|---|
| **aarch64** (RPi 3/4/5 64-bit) | `jopsis/acestream:arm64-latest` | `futebas/acestream-engine-arm` |
| **armv7l** (RPi 2/3/4 32-bit) | `jopsis/acestream:arm32-latest` | — |
| **x86_64** | `jopsis/acestream:amd64-latest` | `blaiseio/acelink` |

---

## Solución de problemas

### El panel web no carga

```bash
docker ps                  # ¿Está el contenedor corriendo?
docker start acestream     # Si no aparece
docker logs acestream      # Ver errores
```

### No puedo acceder desde fuera de casa

```bash
tailscale status    # Verificar que está conectado
sudo tailscale up   # Si no está conectado
```

Asegúrate de que el dispositivo desde donde accedes también tiene Tailscale instalado y conectado a la misma red.

### El stream tarda en empezar

Es normal. AceStream necesita conectarse a la red P2P y hacer buffering. Los primeros 10–30 segundos pueden ser lentos.
