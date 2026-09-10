# installer/

Coloca aquí el archivo `watsonx.data-developer-edition-installer.tar` descargado desde IBM antes de correr `setup-watsonx-data.sh`.

Este archivo **no se incluye en el repositorio** (ver `.gitignore` en la raíz) porque:

- Es un binario propietario de IBM sujeto a licencia — no debe redistribuirse vía Git.
- Pesa varios cientos de MB, lo cual no es apto para un repo de Git normal.

## Dónde conseguirlo

Descárgalo desde tu cuenta de IBM (TechZone / Entitled Registry / portal de descargas de watsonx.data), y colócalo en esta carpeta con el nombre exacto:

```
installer/watsonx.data-developer-edition-installer.tar
```

El script `scripts/setup-watsonx-data.sh` (o el que uses de tu pipeline de instalación) espera encontrarlo en esta ruta.
