# watsonx.data Developer Edition — Remote Access Kit

Herramientas para instalar **IBM watsonx.data Developer Edition** en una VM (cluster KIND local) y exponer sus interfaces web (Lakehouse UI, MinIO Console, Presto UI) a internet de forma estable mediante túneles **ngrok** con dominios fijos, más `kubectl port-forward` gestionado por **systemd** para que sobreviva a caídas de conexión y reinicios.

## Contenido

```
.
├── installer/              # Coloca aquí el .tar del instalador antes de correr setup (ver installer/README.md)
├── scripts/
│   └── wxd-tunnels.sh       # Script interactivo: levantar / detener / ver estado de los túneles
├── systemd/
│   ├── wxd-pf@.service      # Unit template de kubectl port-forward (uno por servicio, via %i)
│   ├── ui.env                # Config del port-forward para la Lakehouse UI
│   ├── minio.env             # Config del port-forward para MinIO Console
│   └── presto.env            # Config del port-forward para Presto UI
└── docs/
    ├── ARCHITECTURE.md      # Cómo encajan las piezas (KIND, port-forward, ngrok)
    ├── SETUP.md              # Guía paso a paso de instalación y exposición
    └── CREDENTIALS.md        # Dónde viven las credenciales default (sin valores reales)
```

## Quickstart

1. Instala watsonx.data Developer Edition siguiendo `docs/SETUP.md` (necesitas el `.tar` del instalador en `installer/`, no incluido en este repo).
2. Instala `ngrok` y reserva 3 dominios fijos en tu cuenta (ver `docs/SETUP.md`).
3. Copia los archivos de `systemd/` a `/etc/systemd/system/` y `/etc/wxd-tunnels/` según se indica en `docs/SETUP.md`.
4. Copia `scripts/wxd-tunnels.sh` a `/usr/local/bin/` (o donde prefieras) y dale permisos de ejecución.
5. Corre:
   ```bash
   sudo /usr/local/bin/wxd-tunnels.sh
   ```
   y elige la opción **1) Levantar túneles**.

## ⚠️ Seguridad

- Este kit expone interfaces de administración a internet público. Las credenciales default de watsonx.data developer edition (`ibmlhadmin` / `password`) y del MinIO de este entorno (`dummyvalue` / `dummyvalue`) son públicas y conocidas — **cámbialas** si vas a dejar el entorno expuesto más allá de pruebas puntuales.
- No subas al repo ningún archivo con credenciales reales, tokens de ngrok, kubeconfigs, ni el instalador de IBM (con licencia propietaria).
- Revisa `.gitignore` antes de tu primer commit.
