# AceStream en Raspberry Pi — Guía de instalación

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

Comprueba que puedes conectarte:

```bash
ssh pi@raspberrypi.local
```

Si no funciona con el nombre, usa la IP directa (mírala en tu router o con un escáner de red).

---

## Subir el script a la Raspberry Pi

### Opción A — Desde macOS / Linux

```bash
scp setup-acestream.sh pi@raspberrypi.local:~/
```

### Opción B — Desde Windows (PowerShell)

```powershell
scp setup-acestream.sh pi@raspberrypi.local:~/
```

### Opción C — Desde Windows (con PuTTY/pscp)

```cmd
pscp setup-acestream.sh pi@raspberrypi.local:/home/pi/
```

> Sustituye `raspberrypi.local` por la IP de tu Raspberry si es necesario.  
> Sustituye `pi` por tu usuario si lo cambiaste al configurar el sistema.

---

## Ejecutar el script

Conéctate por SSH:

```bash
ssh pi@raspberrypi.local
```

Dale permisos de ejecución y ejecuta con sudo:

```bash
chmod +x setup-acestream.sh
sudo ./setup-acestream.sh
```

El script te guiará paso a paso. En cada fase verás:

- **ℹ** Información de lo que está haciendo
- **✔** Paso completado correctamente
- **⚠** Advertencia (no es un error, pero necesita tu atención)
- **✖** Error (se detiene y muestra las últimas líneas del log)

### Durante la instalación

- **Docker**: se instala automáticamente. No requiere input.
- **Tailscale**: te mostrará un enlace. Ábrelo en tu navegador, inicia sesión con tu cuenta y autoriza el dispositivo.
- **AceStream**: se descarga la imagen Docker adecuada para tu arquitectura y se crea el contenedor. No requiere input.

### Si algo falla

El script guarda un log detallado en `/var/log/setup-acestream.log`. Si un paso falla:

1. Se muestra qué paso falló
2. Se muestran las últimas 20 líneas del log
3. Puedes revisar el log completo:

```bash
cat /var/log/setup-acestream.log
```

Puedes **volver a ejecutar el script** sin problema. Detecta lo que ya está instalado y te pregunta si quieres reinstalarlo.

---

## Después de la instalación

### Verificar que todo funciona

Abre en un navegador:

```
http://<IP_TAILSCALE>:6878/webui/
```

Si ves el panel de AceStream, todo está funcionando. También puedes comprobar la versión del engine:

```
http://<IP_TAILSCALE>:6878/webui/api/service?method=get_version
```

### Reproducir un stream

1. Consigue un AceStream ID (ejemplo: `acestream://dd1e67078381739d14beca697356ab76d49d1a2d`)
2. Copia solo el hash: `dd1e67078381739d14beca697356ab76d49d1a2d`
3. Abre en VLC → "Abrir ubicación de red" → pega la URL:

```
http://<IP_TAILSCALE>:6878/ace/getstream?id=dd1e67078381739d14beca697356ab76d49d1a2d
```

Si tu versión del engine soporta HLS, también puedes usar:

```
http://<IP_TAILSCALE>:6878/ace/manifest.m3u8?id=dd1e67078381739d14beca697356ab76d49d1a2d
```

> Si `manifest.m3u8` no funciona, usa `getstream`. Ambos funcionan en VLC.

### Crear una playlist IPTV

Crea un archivo `canales.m3u` en tu ordenador:

```
#EXTM3U

#EXTINF:-1,Canal 1
http://<IP_TAILSCALE>:6878/ace/getstream?id=ID_DEL_CANAL_1

#EXTINF:-1,Canal 2
http://<IP_TAILSCALE>:6878/ace/getstream?id=ID_DEL_CANAL_2
```

Abre el archivo `.m3u` con VLC.

### Consultar tus IPs

```bash
# IP de Tailscale
tailscale ip -4

# IP local
hostname -I
```

### Archivo de referencia

El script deja un resumen en `~/acestream-info.txt` con las IPs y URLs.

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
| Actualizar imagen | Ver sección "Actualizar AceStream" |

### Actualizar AceStream

```bash
docker pull jopsis/acestream:arm64-latest
docker stop acestream
docker rm acestream
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

El script selecciona automáticamente la imagen según tu arquitectura:

| Arquitectura | Imagen principal | Alternativa |
|---|---|---|
| **aarch64** (RPi 3/4/5 64-bit) | `jopsis/acestream:arm64-latest` | `futebas/acestream-engine-arm` |
| **armv7l** (RPi 2/3/4 32-bit) | `jopsis/acestream:arm32-latest` | — |
| **x86_64** | `jopsis/acestream:amd64-latest` | `blaiseio/acelink` |

---

## Rendimiento esperado

- La Raspberry Pi 4 (4 GB) puede gestionar **1–2 streams 1080p** simultáneos.
- Uso típico de CPU: **20–40%**.
- Se recomienda conexión Ethernet para mejor estabilidad.

---

## Solución de problemas

### El panel web no carga

```bash
# ¿Está el contenedor corriendo?
docker ps

# Si no aparece "acestream":
docker start acestream

# Ver errores del contenedor:
docker logs acestream
```

### No puedo acceder desde fuera de casa

```bash
# Verificar que Tailscale está conectado
tailscale status

# Si no está conectado:
sudo tailscale up
```

Asegúrate de que el dispositivo desde donde accedes también tiene Tailscale instalado y conectado a la misma red.

### El stream tarda en empezar

Es normal. AceStream necesita conectarse a la red P2P y hacer buffering. Los primeros 10–30 segundos pueden ser lentos. Si no arranca pasado un minuto, verifica que el AceStream ID es válido y tiene peers activos.

### Error "no matching manifest for linux/arm64"

Esto ocurre si se intenta usar una imagen Docker que no soporta ARM. El script ya maneja esto automáticamente seleccionando `jopsis/acestream` que sí tiene builds para ARM64. Si ves este error al ejecutar el script, comprueba tu conexión a internet y vuelve a ejecutarlo.

### VLC muestra error al abrir la URL

Prueba primero con la URL de stream directo en lugar de `.m3u8`:

```
http://<IP>:6878/ace/getstream?id=TU_ID
```

Si esa funciona pero `.m3u8` no, tu versión del engine puede no soportar HLS. Usa `getstream` directamente, que es compatible con todas las versiones.