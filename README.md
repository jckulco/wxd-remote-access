# watsonx.data Developer Edition — Install & Remote Access Kit

Herramientas para **instalar IBM watsonx.data Developer Edition** de forma automática en una VM RHEL (cluster KIND local) y exponer sus interfaces web (Lakehouse UI, MinIO Console, Presto UI) a internet de forma estable mediante túneles con dominios fijos, más `kubectl port-forward` gestionado por **systemd** para que sobreviva a caídas de conexión y reinicios.

Soporta dos backends de túnel:
- **Cloudflare Tunnel** (recomendado) — gratuito, servicio systemd, supervivencia automática a reinicios
- **ngrok** — alternativa, requiere plan de pago para dominios fijos

## Contenido

```
.
├── installer/                      # Coloca aquí el .tar del instalador de IBM (ver installer/README.md)
├── scripts/
│   ├── setup-watsonx-data.sh        # Instala (y desinstala) watsonx.data Developer Edition
│   ├── install-cloudflare.sh        # Configura acceso remoto con Cloudflare Tunnel (recomendado, gratis)
│   ├── install-deps.sh              # Instala ngrok (alternativa de pago)
│   ├── wxd-tunnels-cf.sh            # Menú interactivo: gestión de túneles Cloudflare
│   └── wxd-tunnels.sh               # Menú interactivo: gestión de túneles ngrok
├── systemd/
│   ├── wxd-pf@.service              # Unit template de kubectl port-forward (uno por servicio, via %i)
│   ├── wxd-cloudflared.service      # Unit de systemd para Cloudflare Tunnel
│   ├── ui.env                       # Config del port-forward para la Lakehouse UI
│   ├── minio.env                    # Config del port-forward para MinIO Console
│   └── presto.env                   # Config del port-forward para Presto UI
└── docs/
    ├── ARCHITECTURE.md              # Cómo encajan las piezas (KIND, port-forward, túneles)
    ├── CLOUDFLARE-SETUP.md          # Guía completa de acceso remoto con Cloudflare Tunnel
    ├── SETUP.md                     # Guía de acceso remoto con ngrok (alternativa)
    ├── CREDENTIALS.md               # Dónde viven las credenciales default (sin valores reales)
    └── IBM-DEVELOPER-EDITION-RESUMEN.md  # Resumen propio de la guía oficial de IBM (Developer Edition)
```

## Quickstart

### 1. Instalar watsonx.data

```bash
sudo ./scripts/setup-watsonx-data.sh
```

Al terminar, la consola queda en `https://<host>:6443/` (`ibmlhadmin` / `password`).

### 2. Configurar acceso remoto — Cloudflare Tunnel (recomendado, gratis)

Necesitas:
- Cuenta de Cloudflare gratuita ([dash.cloudflare.com](https://dash.cloudflare.com))
- Un [API Token](https://dash.cloudflare.com/profile/api-tokens) con permisos `Cloudflare Tunnel:Edit` + `DNS:Edit`
- Tu Account ID (panel derecho del dashboard de CF)
- (Opcional) Un dominio delegado a Cloudflare para URLs amigables

```bash
sudo ./scripts/install-cloudflare.sh
```

El script instala todo automáticamente: `cloudflared`, los servicios systemd de port-forward (`wxd-pf@ui/minio/presto`) si no existen, el túnel, los registros DNS y el servicio `wxd-cloudflared`. Te guía interactivamente y al final muestra las URLs listas para usar.

Ver `docs/CLOUDFLARE-SETUP.md` para la guía completa.

### Uso diario (Cloudflare)

```bash
sudo wxd-tunnels-cf.sh
```

### 2 (alternativa). Acceso remoto con ngrok (requiere plan de pago)

```bash
sudo ./scripts/setup-watsonx-data.sh --remote-access    # instala ngrok + systemd + wxd-tunnels.sh
ngrok config add-authtoken <TOKEN>
# Reserva 3 dominios fijos en https://dashboard.ngrok.com/domains y ajusta DOMAIN_* en wxd-tunnels.sh
sudo wxd-tunnels.sh
```

Ver `docs/SETUP.md` para la guía completa de ngrok.

## Scripts

| Script | Descripción |
|---|---|
| `setup-watsonx-data.sh` | Extrae el `.tar`, ejecuta el `installer.sh` de IBM (docker, kubectl, helm, kind, cluster `kind-wxd`, chart `wxd`), verifica el resultado real, asegura el port-forward de la consola (6443) y muestra URL/credenciales. Opciones: `--tar`, `--remote-access`, `--etcd-dir`, `--no-etcd-relocate`, `--uninstall`, `--yes`, `--help`. |
| `install-cloudflare.sh` | Instala `cloudflared`, autentica con la API de Cloudflare, crea el túnel, detecta zonas DNS (o usa URL UUID automática), crea registros CNAME e instala el servicio systemd `wxd-cloudflared`. Opción `--uninstall` elimina todo. |
| `wxd-tunnels-cf.sh` | Gestiona port-forwards (systemd) y túnel Cloudflare. Menú: levantar / detener / estado / reiniciar / logs. |
| `install-deps.sh` | Instala `ngrok` (x86_64/aarch64). Alternativa a Cloudflare. |
| `wxd-tunnels.sh` | Gestiona port-forwards (systemd) y túneles ngrok. |

## ⚠️ Seguridad

- Este kit expone interfaces de administración a internet público. Las credenciales default de watsonx.data developer edition (`ibmlhadmin` / `password`) y del MinIO de este entorno (`dummyvalue` / `dummyvalue`) son públicas y conocidas — **cámbialas** si vas a dejar el entorno expuesto más allá de pruebas puntuales.
- `installer.sh` abre port-forwards con `--address 0.0.0.0` (6443, 9001, 8381): cualquiera con acceso de red a la VM los alcanza. Restringe con firewall/security groups.
- El API Token de Cloudflare y el archivo `/etc/cloudflared/tunnel-creds.json` son secretos — no los subas al repo ni los compartas.
- No subas al repo ningún archivo con credenciales reales, tokens de ngrok o Cloudflare, kubeconfigs, ni el instalador de IBM (con licencia propietaria ni su contenido extraído, que incluye `values-secret.yaml`).
- Revisa `.gitignore` antes de tu primer commit.
