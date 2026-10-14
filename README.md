# watsonx.data Developer Edition — Install & Remote Access Kit

Herramientas para **instalar IBM watsonx.data Developer Edition** de forma automática en una VM RHEL (cluster KIND local) y exponer sus interfaces web (Lakehouse UI, MinIO Console, Presto UI) a internet de forma estable mediante túneles **ngrok** con dominios fijos, más `kubectl port-forward` gestionado por **systemd** para que sobreviva a caídas de conexión y reinicios.

## Contenido

```
.
├── installer/                    # Coloca aquí el .tar del instalador de IBM (ver installer/README.md)
├── scripts/
│   ├── setup-watsonx-data.sh      # Instala (y desinstala) watsonx.data Developer Edition
│   ├── install-deps.sh            # Instala ngrok (dependencia del acceso remoto)
│   └── wxd-tunnels.sh             # Menú interactivo: levantar / detener / ver estado de los túneles
├── systemd/
│   ├── wxd-pf@.service            # Unit template de kubectl port-forward (uno por servicio, via %i)
│   ├── ui.env                     # Config del port-forward para la Lakehouse UI
│   ├── minio.env                  # Config del port-forward para MinIO Console
│   └── presto.env                 # Config del port-forward para Presto UI
└── docs/
    ├── ARCHITECTURE.md            # Cómo encajan las piezas (KIND, port-forward, ngrok)
    ├── SETUP.md                   # Guía paso a paso de instalación, exposición y troubleshooting
    └── CREDENTIALS.md             # Dónde viven las credenciales default (sin valores reales)
```

## Quickstart

1. Descarga el instalador de IBM y colócalo en `installer/watsonx.data-developer-edition-installer.tar` (no incluido en el repo).
2. Instala watsonx.data (y, opcionalmente, el kit de acceso remoto) en la VM RHEL:
   ```bash
   sudo ./scripts/setup-watsonx-data.sh                    # solo watsonx.data
   sudo ./scripts/setup-watsonx-data.sh --remote-access    # + ngrok, systemd y wxd-tunnels.sh
   ```
   Al terminar, la consola queda en `https://<host>:6443/` (`ibmlhadmin` / `password`).
3. Para acceso remoto: `ngrok config add-authtoken <TOKEN>`, reserva 3 dominios fijos y ajusta `DOMAIN_*` en `wxd-tunnels.sh` (ver `docs/SETUP.md`, secciones 2–5).
4. Corre:
   ```bash
   sudo /usr/local/bin/wxd-tunnels.sh
   ```
   y elige la opción **1) Levantar túneles**.

Para desinstalar: `sudo ./scripts/setup-watsonx-data.sh --uninstall` (añade `--purge` para quitar también Docker).

## Scripts

| Script | Descripción |
|---|---|
| `setup-watsonx-data.sh` | Extrae el `.tar`, ejecuta el `installer.sh` de IBM (docker, kubectl, helm, kind, cluster `kind-wxd`, chart `wxd`), verifica el resultado real, asegura el port-forward de la consola (6443) y muestra URL/credenciales. `Ctrl+C` seguro, diagnóstico automático en `installer/diagnostics-*.log` y mueve etcd a un disco rápido si el de Docker es lento. Opciones: `--tar`, `--remote-access`, `--etcd-dir`, `--no-etcd-relocate`, `--uninstall`, `--yes`, `--help`. |
| `install-deps.sh` | Instala `ngrok` (x86_64/aarch64) y recuerda los pasos manuales de ngrok. |
| `wxd-tunnels.sh` | Gestiona port-forwards (systemd) y túneles ngrok. |

## ⚠️ Seguridad

- Este kit expone interfaces de administración a internet público. Las credenciales default de watsonx.data developer edition (`ibmlhadmin` / `password`) y del MinIO de este entorno (`dummyvalue` / `dummyvalue`) son públicas y conocidas — **cámbialas** si vas a dejar el entorno expuesto más allá de pruebas puntuales.
- `installer.sh` abre port-forwards con `--address 0.0.0.0` (6443, 9001, 8381): cualquiera con acceso de red a la VM los alcanza. Restringe con firewall/security groups.
- No subas al repo ningún archivo con credenciales reales, tokens de ngrok, kubeconfigs, ni el instalador de IBM (con licencia propietaria ni su contenido extraído, que incluye `values-secret.yaml`).
- Revisa `.gitignore` antes de tu primer commit.
