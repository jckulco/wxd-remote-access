# Resumen de la guía oficial de IBM: watsonx.data Developer Edition (New version)

Resumen en español de la guía de IBM *"watsonx.data developer edition documentation"*
(capítulo 1, "Setting up watsonx.data developer edition (New version)").

> **Alcance y avisos**
> - Es un **resumen propio**, no una copia de la guía. El documento original es material con
>   copyright de IBM y por eso **no se incluye** en este repositorio. Ante cualquier duda, manda
>   la guía oficial vigente de IBM.
> - Refleja la versión del PDF revisado; IBM puede cambiarla sin aviso.
> - **Credenciales:** siguiendo la convención de este repo (ver [`CREDENTIALS.md`](CREDENTIALS.md)),
>   no se escribe el password. Usuario: `ibmlhadmin`; el password es el *default* que publica IBM en la guía.
> - Este repo se centra en **Linux (RHEL)**. Las secciones de Mac y Windows se resumen solo
>   como contexto.

## 1. Qué es

Entorno **autocontenido** para experimentar, evaluar y construir pruebas de concepto con
watsonx.data. Incluye herramientas integradas y motores preconfigurados. Novedades de la
"New version" según IBM:

- **Instalación simplificada** respecto a versiones anteriores.
- **Entorno listo para usar**, orientado a experimentación y POCs.
- **Motores y herramientas preconfigurados**, sin configuración compleja.

Disponible para **macOS, Linux (RHEL) y Windows**.

## 2. Requisitos (planning)

IBM publica requisitos solo para **Mac con Apple silicon** y **Windows**:

| Recurso | Requisito |
|---|---|
| CPU | 4+ núcleos |
| RAM | 16+ GB (≥ 4 GB libres en ejecución) |
| Disco | 500+ GB, con al menos 150 GB libres |
| SO | macOS 12+ (Monterey o posterior) / Windows 10 u 11 de 64 bits |
| Red | Conectividad a internet para descargar imágenes de contenedores |

> **Para RHEL la guía no publica requisitos específicos.** Las cifras de arriba son las únicas
> de referencia que da IBM.

## 3. Instalación

Todas las rutas empiezan igual: registrarse en la página de descarga de IBM ("Signup page") y
bajar el instalador de la plataforma elegida.

### 3.1 Mac (Apple silicon)

1. Abrir el `.dmg` y arrastrarlo a *Applications* (reemplazando una versión anterior si existe).
2. Abrir **Dev Edition Installer**, expandir la sección *Pods*, leer y aceptar la licencia.
3. Pulsar **Setup watsonx.data Dev Edition** y confirmar. El progreso se ve en *Installation log*
   y *Setup progress* (con el estado de cada pod).
4. Al terminar aparece *Setup process completed* y una etiqueta verde *Installed `<version>`*.
5. Continuar con "Completar la instalación" (sección 4).

### 3.2 Windows 10/11

Mismo flujo gráfico que Mac, con un `.exe`. Particularidades:

- Se pide permiso de instalador al ejecutarlo.
- **Podman requiere WSL.** Si WSL no está instalado, el instalador lo inicia durante la
  inicialización de Podman. Windows pedirá **reiniciar (obligatorio)**; después hay que volver a
  abrir *Dev Edition Installer* y continuar.

### 3.3 Linux (RHEL) — el caso de este repo

1. Descargar el instalador de Linux.
2. Extraer el `.tar` (borrando antes el directorio extraído previo):
   ```bash
   rm -rf ./watsonx.data-developer-edition-installer
   tar -xvf watsonx.data-developer-edition-installer.tar
   cd watsonx.data-developer-edition-installer
   ```
3. Dar permiso de ejecución (la guía usa `chmod 777`; el script de este repo usa `755`, que es suficiente):
   ```bash
   chmod 777 ./installer.sh
   ```
4. Ejecutar el instalador. Según la guía, instala los prerrequisitos y watsonx.data:
   ```bash
   ./installer.sh
   ```
5. Exponer la consola con un port-forward y **esperar a que todos los pods estén `Running` o `Completed`**:
   ```bash
   nohup kubectl port-forward -n wxd service/lhconsole-ui-svc 6443:443 --address 0.0.0.0 >/dev/null 2>&1 &
   ```
6. Entrar a la UI en `https://<vmhost>:6443/` con el usuario `ibmlhadmin` y el password default de IBM.

> El **namespace** que usa la guía es `wxd`; el release de Helm y el cluster KIND se llaman `wxd` y `kind-wxd`.

Todo esto lo automatiza [`scripts/setup-watsonx-data.sh`](../scripts/setup-watsonx-data.sh)
(ver [`SETUP.md`](SETUP.md)).

## 4. Completar la instalación y operar el entorno

La guía describe el panel **watsonx.data Control** del instalador gráfico (sección *After setup*).
Tras abrir la UI se ven estas áreas:

| Sección de la UI | Para qué sirve |
|---|---|
| Infrastructure Manager | Definir y asociar motores, catálogos y almacenamiento. Muestra los componentes configurados por defecto. |
| Data Manager | Ingerir, previsualizar y gestionar datos. |
| Query Workspace | Editor SQL para escribir, ejecutar y guardar consultas. |
| Pods and Containers | Unidades de despliegue Kubernetes que ejecutan los servicios de la plataforma. |

Nota de IBM: el motor **Presto** se puede usar con catálogos **Hive** e **Iceberg**.

### Arrancar y parar (sin reinstalar)

| Acción | Comando en Linux | Efecto |
|---|---|---|
| Arrancar el cluster KIND | `docker start kind-wxd-control-plane` | Reactiva el entorno tras reiniciar la máquina. |
| Detener el cluster KIND | `docker stop kind-wxd-control-plane` | Detiene el Kubernetes interno para ahorrar recursos. |

En el instalador gráfico (Mac/Windows) existen además *Start/Stop watsonx.data*, que arrancan o
paran los servicios y la máquina virtual que los aloja, para liberar CPU y memoria.

## 5. Exposición opcional de MinIO y MDS

Ambos se exponen con `kubectl port-forward` hacia `0.0.0.0`:

| Servicio | Puerto | Comando (resumido) | Uso |
|---|---|---|---|
| MinIO (object store embebido) | 9001 | `kubectl port-forward -n wxd service/ibm-lh-minio-svc 9001:9001 --address 0.0.0.0` | Cargar o almacenar datos de prueba; consola web en `http://<host>:<puerto-consola>`. |
| Metadata Service (MDS, Thrift) | 8381 | `kubectl port-forward -n wxd service/ibm-lh-mds-thrift-svc 8381:8381 --address 0.0.0.0` | Permite que apps externas (Db2, Netezza, Spark) se conecten, sobre todo si corren fuera de Docker/Podman. |

Detalles:

- Los comandos de la guía se lanzan con `nohup ... >/dev/null 2>&1 &`.
- Si se pierde la conexión, se restablece volviendo a ejecutar el comando (o el paso *Expose* del instalador).
- Credenciales de MinIO publicadas por IBM: usuario `dummyvalue` y password `dummyvalue`.
- Para **restablecer credenciales y dejar de exponer los puertos**: `bin/start_service ibm-lh-minio`.
- Según [`SETUP.md`](SETUP.md), el `installer.sh` de la versión incluida en el `.tar` ya lanza por sí
  mismo los port-forwards de 6443, 9001 y 8381.

## 6. Desinstalar

Hay dos niveles:

1. **Uninstall dev edition** (desde el panel *Control*): quita watsonx.data pero **conserva los prerrequisitos** instalados.
2. **Cleanup** (limpiar componentes): elimina prerrequisitos y componentes instalados en el setup.

| Plataforma | Cleanup |
|---|---|
| Mac | Descargar y ejecutar el script de desinstalación de las instrucciones de instalación. |
| Windows | Quitar Podman, Kind, Helm, kubectl (y opcionalmente Docker) con `winget`, y desinstalar WSL (`wsl --unregister podman-wxd` / `wsl --uninstall`). El comando `winget` aparece **truncado en el PDF** (`Kubernetes.kubect`). |
| **Linux** | Los 3 comandos siguientes, en orden. |

```bash
kubectl delete namespace wxd
kind delete cluster --name kind-wxd
dnf remove -y docker-ce docker-ce-cli containerd.io
```

Equivalencia en este repo: `sudo ./scripts/setup-watsonx-data.sh --uninstall --purge`
(el borrado del namespace es redundante porque `kind delete cluster` lo elimina).

## 7. APIs de watsonx.data

La API del Developer Edition usa un **bearer token**. Valores fijos del entorno local:

| Dato | Valor |
|---|---|
| Base URL | `https://localhost:6443` (usar `-k`, certificado autofirmado) |
| `instance_id` | `0000-0000-0000-0000` |
| Usuario | `ibmlhadmin` |

### 7.1 Generar el token

`POST /lakehouse/api/v3/auth/authenticate` con `Content-Type: application/json` y un cuerpo con
`username`, `password`, `instance_id` e `instance_name` (vacío):

```bash
curl --location -k 'https://localhost:6443/lakehouse/api/v3/auth/authenticate' \
  --header 'Content-Type: application/json' \
  --data '{"username":"ibmlhadmin","password":"<password default de IBM>","instance_id":"0000-0000-0000-0000","instance_name":""}'
```

### 7.2 Ingestion API (ejemplo de la guía)

`POST /lakehouse/api/v3/lhingestion/api/v1/ingestions`, con las cabeceras `Accept` y
`Content-Type: application/json`, `Authinstanceid: 0000-0000-0000-0000` y
`Authorization: Bearer <token>`.

Estructura del cuerpo del ejemplo:

| Campo | Valor en el ejemplo |
|---|---|
| `target` | `catalog: iceberg_data`, `schema: schema1`, `table: test1` |
| `source.file_paths` | `s3://hive-bucket/wxd-local-ingestion/2/jsonFile.json` |
| `source.file_type` | `json` |
| `source.bucket_details` | `bucket_name: hive-bucket`, `bucket_type: minio` |
| `job_id` | `ingestion-test-01` |
| `engine_id` | `spark158` (motor Spark; el id **depende de tu instalación**) |
| `execute_config` | `driver_memory: 0G`, `driver_cores: 0`, `executor_memory: 4G`, `executor_cores: 2`, `num_executors: 1` |

La respuesta de ejemplo devuelve `status: "starting"`, un `application_id` y, en `details`, los
parámetros resueltos. De ahí se desprenden **endpoints internos** del cluster:

| Componente | Endpoint interno (visto en la respuesta) |
|---|---|
| MinIO (S3) | `http://ibm-lh-minio-svc:9000` |
| MDS | `https://ibm-lh-mds-thrift-svc:8381/mds/thrift?catalog=iceberg_data` |
| Spark engines API | `https://lhconsole-ui-svc:443/lakehouse/api/v3/spark_engines/<engine>/applications` |
| Buckets por defecto | `hive-bucket` (catálogo asociado `hive_data`) e `iceberg-bucket` |

## 8. CLI `cpdctl`

Permite operar el Developer Edition por línea de comandos en macOS, Linux (RHEL) y Windows 10/11.
Se descarga como `.tar.gz` desde el enlace de instalación de IBM.

**Mac / Linux:**

```bash
tar -xzf cpdctl-mac.tar.gz          # el nombre del archivo depende de tu plataforma
./cpdctl --help                      # verificar
openssl rand -hex 32 > key.txt       # clave de cifrado (solo la primera vez)
export CPDCTL_ENCRYPTION_KEY_PATH=key.txt
./cpdctl config profile set cpdctl_dev --username ibmlhadmin --password <password> \
  --url "https://localhost:6443" --env "WATSONX_DATA_INSTANCE_ID=0000-0000-0000-0000"
./cpdctl config profile use cpdctl_dev
export CPDCTL_ENABLE_DEV_EDITION_AUTODETECT=true   # detector de Developer Edition
```

**Windows (PowerShell):** mismos pasos con `.\cpdctl.exe`, `Out-File -Encoding ASCII key.txt` y
`$env:CPDCTL_ENCRYPTION_KEY_PATH` / `$env:CPDCTL_ENABLE_DEV_EDITION_AUTODETECT="true"`.

Comandos de ejemplo de la guía:

```bash
./cpdctl wx-data bucket list                         # listar almacenamiento
./cpdctl wx-data ingestion create \
  --source-data-files s3://<bucket>/<archivo>.csv \
  --engine-id <id-del-motor-spark> \
  --driver-cores 0 --driver-memory "0G" \
  --executor-cores 2 --executor-memory "4G" --num-executors 1 \
  --target-table iceberg_data.<schema>.<tabla> --sync-status
```

## 9. Observaciones sobre la guía

Puntos que conviene saber al leer el original (observados en el PDF revisado):

- La sección de **Windows** conserva un paso copiado de Mac ("Command + Spacebar").
- El comando de `winget` de la limpieza en Windows aparece **truncado**.
- El texto menciona "`wxd-dev-edition.tar`" pero el comando usa `watsonx.data-developer-edition-installer.tar`.
- La guía sugiere `chmod 777`; basta `chmod 755`.
- En Linux, el paso "revisar el progreso" muestra el comando de port-forward de la consola, no un comando de seguimiento de pods; para ver el estado usa `kubectl get po -n wxd -w`.
- Los `engine_id` (`spark158`, `spark804`) son **ejemplos de instalaciones concretas**; consulta el tuyo en la UI.

## 10. Mapa hacia el resto de la documentación

| Tema | Dónde |
|---|---|
| Instalar con un solo comando, opciones y troubleshooting | [`SETUP.md`](SETUP.md) |
| Arquitectura del acceso remoto | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Dónde viven las credenciales | [`CREDENTIALS.md`](CREDENTIALS.md) |
| Dónde poner el `.tar` del instalador | [`../installer/README.md`](../installer/README.md) |
