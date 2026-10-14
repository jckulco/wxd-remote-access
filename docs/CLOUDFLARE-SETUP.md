# Guía de acceso remoto con Cloudflare Tunnel

Alternativa **100% gratuita** a ngrok para exponer los servicios de watsonx.data Developer Edition
a internet con URLs estables y TLS automático, usando tu cuenta gratuita de Cloudflare.

## Flujo completo

```
[1] setup-watsonx-data.sh  →  [2] install-cloudflare.sh  →  [3] wxd-tunnels-cf.sh
     (instala wxd)               (todo automático)              (uso diario)
```

> `install-cloudflare.sh` instala en una sola ejecución: el binario `cloudflared`, los servicios
> systemd de port-forward (`wxd-pf@ui/minio/presto`) si aún no están, crea el túnel, configura
> las URLs y registra el servicio `wxd-cloudflared`. No se requieren pasos manuales intermedios.

## Modos de URL disponibles

El script detecta automáticamente qué opciones tienes disponibles y te presenta un menú:

| Modo | URLs resultantes | Requisito |
|---|---|---|
| **Dominio propio** | `https://wxd-ui.tudominio.com` × 3 | Un dominio delegado a Cloudflare |
| **workers.dev** | `https://wxd-ui.<cuenta>.workers.dev` × 3 | Solo una cuenta Cloudflare gratuita |
| **UUID** (fallback) | `https://<uuid>.cfargotunnel.com` | Ninguno — pero solo expone Lakehouse UI |

> **Recomendación:** usa el modo **workers.dev** si no tienes dominio propio — es completamente
> gratuito y da 3 URLs separadas para los 3 servicios.

## 0. Antes de empezar

### Requisitos en la VM

| Concepto | Detalle |
|---|---|
| watsonx.data instalado | `kubectl -n wxd get pods` debe mostrar pods `Running` |
| port-forwards systemd | `wxd-pf@ui/minio/presto` — el script los instala automáticamente si no existen. Si ya los instalaste a mano no hace nada. |
| Paquetes | `curl`, `jq`, `openssl` — en RHEL: `dnf install -y curl jq openssl` |
| Arquitectura | `x86_64` o `aarch64` |

### Requisitos en Cloudflare

| Concepto | Detalle |
|---|---|
| Cuenta Cloudflare | Gratuita — [dash.cloudflare.com](https://dash.cloudflare.com) |
| Account ID | Panel derecho de la página principal de tu cuenta |
| API Token | Ver sección 1 abajo |
| Dominio | Opcional — si no tienes, el script usa workers.dev (gratuito) o UUID |

## 1. Crear el API Token de Cloudflare

1. Ve a [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Clic en **Create Token** → **Create Custom Token**
3. Asigna los siguientes permisos:

   | Tipo | Recurso | Permiso | Cuándo se usa |
   |---|---|---|---|
   | Account | Cloudflare Tunnel | Edit | Siempre |
   | Account | Workers Scripts | Edit | Modo workers.dev |
   | Account | Workers Routes | Edit | Modo workers.dev |
   | Zone | DNS | Edit | Solo si usas dominio propio |

   > Para workers.dev sin dominio propio: solo necesitas los 3 permisos de Account.
   > El permiso de DNS es opcional si no tienes zona en Cloudflare.

4. En **Account Resources**: selecciona tu cuenta
5. En **Zone Resources**: si tienes dominio, selecciona la zona; si no, puedes dejar "All zones"
6. Clic en **Continue to summary** → **Create Token**
7. Copia el token — solo se muestra una vez

## 2. Ejecutar el script de instalación

```bash
sudo ./scripts/install-cloudflare.sh
```

El script te pedirá interactivamente el token y el Account ID, luego detectará tus opciones:

### Si tienes zonas DNS en tu cuenta

```
  Zonas activas encontradas en tu cuenta:

    1) tudominio.com
    w) Usar workers.dev gratuito (3 subdominios <cuenta>.workers.dev)
    0) Usar URL automática UUID (solo Lakehouse UI, sin subdominios)

  Elige una zona [0-1 / w]:
```

### Si NO tienes zonas DNS

```
  No hay zonas DNS en tu cuenta.
  Opciones:
    w) Usar workers.dev gratuito (3 subdominios <cuenta>.workers.dev)
    0) Usar URL UUID (solo Lakehouse UI)

  Elige [w/0]:
```

### Resultado modo workers.dev

```
  ✅  Cloudflare Tunnel configurado exitosamente

  Lakehouse UI  : https://wxd-ui.micuenta.workers.dev
  MinIO Console : https://wxd-minio.micuenta.workers.dev
  Presto UI     : https://wxd-presto.micuenta.workers.dev

  (Modo workers.dev: si alguna URL tarda en responder espera ~30 s
   a que Cloudflare propague los Workers recién creados.)
```

### Resultado modo dominio propio

```
  ✅  Cloudflare Tunnel configurado exitosamente

  Lakehouse UI  : https://wxd-ui.tudominio.com
  MinIO Console : https://wxd-minio.tudominio.com
  Presto UI     : https://wxd-presto.tudominio.com
```

### Resultado modo UUID (fallback, sin dominio ni workers.dev)

```
  ✅  Cloudflare Tunnel configurado exitosamente

  URL base (UUID): https://a1b2c3d4-e5f6-7890-abcd-ef1234567890.cfargotunnel.com

  (Modo UUID: solo Lakehouse UI expuesta.)
```

### Modo no interactivo (scripting / CI)

Con dominio propio:
```bash
sudo ./scripts/install-cloudflare.sh \
  --token   "eyJhbGciOiJIUzI..." \
  --account "abc123def456" \
  --zone    "zone_id_aqui" \
  --domain  "tudominio.com" \
  --sub-ui    "wxd-ui" \
  --sub-minio "wxd-minio" \
  --sub-presto "wxd-presto" \
  --yes
```

Con workers.dev (sin dominio):
```bash
sudo ./scripts/install-cloudflare.sh \
  --token       "eyJhbGciOiJIUzI..." \
  --account     "abc123def456" \
  --workers-dev \
  --yes
```

## 3. Archivos generados

| Archivo | Descripción |
|---|---|
| `/etc/cloudflared/config.yml` | Configuración del túnel: 3 ingress rules |
| `/etc/cloudflared/tunnel-creds.json` | Credenciales del túnel (secreto — solo root) |
| `/etc/cloudflared/wxd-urls.env` | URLs generadas (leídas por `wxd-tunnels-cf.sh`) |
| `/etc/systemd/system/wxd-cloudflared.service` | Unit de systemd |
| `/usr/local/bin/cloudflared` | Binario de cloudflared |

## 4. Uso diario

```bash
sudo wxd-tunnels-cf.sh
```

```
════════════════════════════════════════════════════════
  watsonx.data — gestor de túneles Cloudflare
════════════════════════════════════════════════════════
1) Levantar túneles
2) Detener túneles
3) Ver estado
4) Reiniciar (detener + levantar)
5) Ver logs en tiempo real
0) Salir
```

O directamente con `systemctl`:

```bash
systemctl start   wxd-cloudflared    # levantar
systemctl stop    wxd-cloudflared    # detener
systemctl status  wxd-cloudflared    # estado
journalctl -u wxd-cloudflared -f     # logs en tiempo real
```

## 5. Supervivencia a reinicios de la VM

El servicio `wxd-cloudflared` queda habilitado con `systemctl enable`, por lo que:

- Al reiniciar la VM, Docker arranca primero, luego los port-forwards (`wxd-pf@*`) y finalmente
  el túnel Cloudflare — todo de forma automática, sin intervención manual.
- Si `cloudflared` se cae (timeout, error de red), systemd lo reinicia en 5 segundos.
- Si un port-forward se cae, systemd lo reinicia; cloudflared seguirá activo y reintentará
  las conexiones cuando el port-forward vuelva.

> **Diferencia vs ngrok:** ngrok no corría como servicio systemd — había que relanzarlo manualmente
> tras cada reinicio de la VM. Con Cloudflare Tunnel todo es automático.

## 6. Desinstalar

```bash
sudo ./scripts/install-cloudflare.sh --uninstall --token <CF_API_TOKEN>
```

Hace:
1. `systemctl stop --disable wxd-cloudflared`
2. Elimina el túnel en la API de Cloudflare (con `?cascade=true`, que también elimina los DNS CNAME)
3. Borra `/etc/cloudflared/` y el unit de systemd

> Para eliminar también el binario: `rm -f /usr/local/bin/cloudflared`
> Los DNS CNAME en tu zona se eliminan automáticamente via la flag `cascade=true` de la API.

## 7. Troubleshooting

| Síntoma | Causa / solución |
|---|---|
| `ERROR: El API Token no es válido` | Token incorrecto o sin permiso `Cloudflare Tunnel:Edit`. Créalo de nuevo en el dashboard. |
| El servicio arranca pero no hay conectividad | Verifica que los port-forwards estén activos: `systemctl status wxd-pf@ui`. |
| `origin certificate error` en el browser | Normal — cloudflared está configurado con `noTLSVerify: true` para el certificado self-signed de watsonx.data. El browser muestra el candado de Cloudflare (válido). |
| DNS no resuelve después de la instalación | Propagación DNS puede tardar hasta 60 s. Verifica con `dig wxd-ui.tudominio.com`. |
| `jq: command not found` | `dnf install -y jq` |
| Quiero cambiar los subdominios | Re-ejecuta `install-cloudflare.sh` con `--sub-ui`, `--sub-minio`, `--sub-presto` diferentes. El script actualiza el DNS y el `config.yml` en el mismo túnel. |
| Quiero usar otro dominio | Re-ejecuta sin `--zone` y `--domain` para que el script vuelva a detectar zonas interactivamente. |
| workers.dev no carga (timeout / error 1033) | Los Workers tardan ~30 s en propagarse. Si tras 1 min sigue fallando, verifica con `cf_get /accounts/<id>/workers/scripts/wxd-proxy-ui`. |
| `No se pudo subir el Worker ... Workers Scripts:Edit` | El token no tiene el permiso `Workers Scripts:Edit`. Regenera el token incluyendo ese permiso y los de `Workers Routes:Edit`. |
| `No se pudo obtener/activar el subdominio workers.dev` | Ve a [dash.cloudflare.com](https://dash.cloudflare.com) → **Workers & Pages** → activa tu subdominio manualmente y vuelve a ejecutar el script. |

## 8. Diferencias con el flujo ngrok

| Paso | ngrok (antes) | Cloudflare Tunnel (ahora) |
|---|---|---|
| Instalar herramienta | `install-deps.sh` | `install-cloudflare.sh` (incluye todo) |
| Autenticar | `ngrok config add-authtoken` (manual) | Automático vía API Token |
| Reservar URLs | Dashboard ngrok, manual | Automático vía API |
| Crear DNS | No aplica (subdominio `*.ngrok.app`) | Automático vía API |
| Iniciar túneles | `wxd-tunnels.sh` + 3 procesos ngrok | `wxd-tunnels-cf.sh` + 1 servicio systemd |
| Sobrevivir reinicio | ❌ Manual | ✅ Automático (systemd) |
| Costo | Plan Hobby (~$8/mes) | **Gratis** |
