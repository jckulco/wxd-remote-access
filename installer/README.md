# installer/

Coloca aquí el archivo `watsonx.data-developer-edition-installer.tar` descargado desde IBM antes de correr `scripts/setup-watsonx-data.sh`.

Este archivo **no se incluye en el repositorio** (ver `.gitignore` en la raíz) porque:

- Es un binario propietario de IBM sujeto a licencia — no debe redistribuirse vía Git.
- Puede incluir credenciales de pull de imágenes (`values-secret.yaml`) que no deben versionarse.

## Dónde conseguirlo

Descárgalo desde la guía oficial de IBM "Installing watsonx.data developer version" (versión RHEL) o desde tu cuenta de IBM, y colócalo en esta carpeta con el nombre exacto:

```
installer/watsonx.data-developer-edition-installer.tar
```

## Cómo se usa

```bash
sudo ./scripts/setup-watsonx-data.sh
```

El script extrae el `.tar` **aquí mismo** (se crea `installer/watsonx.data-developer-edition-installer/`, ignorado por Git), ejecuta su `installer.sh` y deja el log en `installer/setup-watsonx-data.log` (también ignorado).

Si guardas el `.tar` en otro lugar: `sudo ./scripts/setup-watsonx-data.sh --tar /ruta/instalador.tar`, o exporta `WXD_TAR`.

## Contenido del .tar (referencia)

| Elemento | Descripción |
|---|---|
| `installer.sh` | Instala docker, kubectl, helm y kind; crea el cluster `kind-wxd`; despliega el chart `wxd` y levanta los port-forwards. |
| `install-tools.sh` / `.ps1` | Alternativa genérica con Minikube (Linux/macOS/Windows); **no** la usa este kit. |
| `values.yaml`, `values-arm.yaml`, `values-secret.yaml` | Valores del chart Helm (imágenes en `icr.io/wxd_dev_edition`). |
| `templates/`, `charts/`, `Chart.yaml` | Chart Helm de watsonx.data. |
