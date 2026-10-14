# Guía de instalación y exposición remota

Flujo completo, de una VM RHEL limpia a las interfaces de watsonx.data accesibles por internet:

```
[1] setup-watsonx-data.sh  →  [2] install-deps.sh  →  [3] dominios ngrok  →  [4] systemd  →  [5] wxd-tunnels.sh
     (instala wxd)              (instala ngrok)         (reserva 3)          (port-forward)      (uso diario)
```

> Atajo: `sudo ./scripts/setup-watsonx-data.sh --remote-access` ejecuta los pasos 1, 2, 4 y 5
> (instalación de los archivos). Los pasos 3 y el `authtoken` de ngrok siempre son manuales
> porque dependen de tu cuenta.

## 0. Requisitos de la VM

| Concepto | Detalle |
|---|---|
| SO | RHEL 8/9 o derivado (Rocky, Alma, CentOS Stream). El `installer.sh` de IBM usa `dnf`/`yum`. |
| Arquitectura | `x86_64` o `aarch64` (el instalador descarga el binario de `kind` correspondiente). |
| Permisos | `root` o `sudo`. |
| Red | Salida a internet: `download.docker.com`, `pkgs.k8s.io`, `kind.sigs.k8s.io`, `raw.githubusercontent.com` e `icr.io` (imágenes de watsonx.data). |
| Instalador | `installer/watsonx.data-developer-edition-installer.tar` (ver `installer/README.md`). |
| Recursos | El Developer Edition despliega ~20 pods en un solo nodo KIND. La guía oficial de IBM indica como mínimo 4+ núcleos, 16+ GB de RAM (≥ 4 GB libres en ejecución) y 500+ GB de disco con ≥ 150 GB libres, pero esas cifras están publicadas para Mac Apple silicon y Windows; **IBM no publica requisitos específicos para RHEL**. Ver Troubleshooting si el disco es lento. |

## 1. Instalar watsonx.data Developer Edition

```bash
sudo ./scripts/setup-watsonx-data.sh
```

El script automatiza los pasos de la guía oficial de IBM "Installing watsonx.data developer version" (RHEL):

| # | Paso oficial IBM | Qué hace el script |
|---|---|---|
| 1 | `rm -rf ./wxd-dev-edition-installer; tar -xvf watsonx.data-developer-edition-installer.tar` | Borra el directorio previo y extrae el `.tar` en `installer/`. |
| 2 | `cd wxd-dev-edition-installer` | Entra al directorio extraído (detecta su nombre real desde el `.tar`). |
| 3 | `chmod 777 ./installer.sh` | `chmod 755 ./installer.sh` (suficiente, sin permisos de escritura globales). |
| 4 | `./installer.sh` | Ejecuta el instalador de IBM y guarda la salida en `installer/setup-watsonx-data.log`. |
| 5 | `kubectl get po -n spark -w` | Muestra los pods del namespace **`wxd`** y avisa si alguno no está `Running`/`Completed`. |
| 6 | `kubectl port-forward ... 6443:443` | Verifica que el port-forward de la consola esté activo; si no, lo levanta. |
| 7 | Abrir `https://<vmhost>:6443/` | Imprime la URL y las credenciales. |
| 8 | `uninstaller.sh` (opcional) | `--uninstall`, ver sección 8. |

Qué hace internamente el `installer.sh` de IBM (versión incluida en el `.tar`):

1. Instala `docker-ce`, `kubectl` (repo `pkgs.k8s.io`, v1.33), `helm` y `kind` (v0.30.0).
2. Crea el cluster KIND `kind-wxd`.
3. Ejecuta `helm upgrade --install wxd . -f values.yaml -f values-secret.yaml -n wxd --create-namespace --timeout 120m`.
4. Espera (hasta 120 × 20 s) a que todos los pods estén `Running`/`Completed`.
5. Lanza 3 `kubectl port-forward` con `nohup`: UI `6443→443`, MinIO `9001→9001` y MDS Thrift `8381→8381`.

> **Nota sobre el namespace:** la guía oficial vigente de IBM usa el namespace **`wxd`**
> (`kubectl get po -n wxd`). Algunas versiones/capturas antiguas mencionan `-n spark`; el chart
> actual se instala en `wxd`, que es lo que usan el script y esta documentación.

Opciones del script:

```bash
sudo ./scripts/setup-watsonx-data.sh --tar /ruta/al/instalador.tar   # tar en otra ubicación (o env WXD_TAR)
sudo ./scripts/setup-watsonx-data.sh --remote-access                 # además instala ngrok + systemd + wxd-tunnels.sh
sudo ./scripts/setup-watsonx-data.sh --help
```

Más opciones:

```bash
sudo ./scripts/setup-watsonx-data.sh --etcd-dir /var/lib/mi-etcd     # fuerza etcd en ese directorio (disco rápido)
sudo ./scripts/setup-watsonx-data.sh --no-etcd-relocate              # nunca mover etcd
```

### Robustez del script

| Comportamiento | Detalle |
|---|---|
| **`Ctrl+C` seguro** | `installer.sh` corre en su propia sesión (`setsid`). Al interrumpir, el script mata `installer.sh` y `helm upgrade` en vez de dejarlos huérfanos, y guarda un diagnóstico. |
| **Verificación real** | `installer.sh` devuelve 0 aunque falle `helm`/`kind`. `verify_install` comprueba herramientas, cluster `kind-wxd`, release `deployed` y pods. |
| **Diagnóstico automático** | Si la instalación falla, se interrumpe o se desinstala, guarda `installer/diagnostics-<fecha>.log` (eventos, logs de `kube-apiserver` y `etcd`, `kubelet`, `dmesg`) antes de que se pierdan al borrar el cluster. |
| **etcd en disco rápido** | Mide la latencia de `fsync` del disco de Docker. Si supera 10 ms (`WXD_FSYNC_MAX_MS`) y `/var/lib/kind-wxd-etcd` es al menos 2× más rápido, crea el cluster con `/var/lib/etcd` del nodo montado en ese directorio. |

> **Por qué lo de etcd.** En una VM de prueba, el directorio de Docker estaba en un disco de datos
> secundario con `fsync` de ~21 ms (el disco del SO: ~3,6 ms). Con ese disco, el `kube-apiserver`
> se reinició y la instalación no convergió en dos intentos (síntomas: `EOF`,
> `connection reset by peer`, `failed to sync configmap cache`, pods en `ContainerCreating`).
> La reubicación de etcd es la mitigación que adopta el script; **está implementada pero aún no
> se ha comprobado de extremo a extremo que resuelva el problema.** Si tu disco de Docker es
> rápido, no se aplica.
>
> El script modifica la copia extraída de `installer.sh` (`kind create cluster ... --config`),
> no el `.tar` original. Al desinstalar, borra el subdirectorio `member/` de `--etcd-dir`:
> no uses como `--etcd-dir` un directorio con otros datos.


Verificación manual posterior:

```bash
kubectl -n wxd get pods
kubectl -n wxd get svc
```

Acceso local: `https://<host-de-la-VM>:6443/` — usuario `ibmlhadmin`, password `password`.

## 2. Instalar dependencias de acceso remoto

```bash
sudo ./scripts/install-deps.sh
```

Instala únicamente `ngrok` (docker, kubectl, helm y kind ya los instaló el paso 1). Luego:

```bash
ngrok config add-authtoken <TU_TOKEN>
```

(Consigue tu token en https://dashboard.ngrok.com/get-started/your-authtoken — requiere cuenta,
el plan gratuito no permite 3 dominios fijos simultáneos; se usó un plan Hobby de pago.)

## 3. Reservar dominios fijos en ngrok

En https://dashboard.ngrok.com/domains, crea 3 **Agent Endpoints** con dominio fijo
(uno por servicio: UI, MinIO, Presto). ngrok asigna un subdominio del tipo
`algo-aleatorio.ngrok.app` a cada uno (el plan Hobby no permite elegir el nombre).

Anota los 3 dominios y actualiza las variables al inicio de `scripts/wxd-tunnels.sh`
(si ya lo instalaste en `/usr/local/bin`, edita esa copia):

```bash
DOMAIN_UI="tu-dominio-ui.ngrok.app"
DOMAIN_MINIO="tu-dominio-minio.ngrok.app"
DOMAIN_PRESTO="tu-dominio-presto.ngrok.app"
```

## 4. Instalar los servicios systemd de port-forward

```bash
sudo cp systemd/wxd-pf@.service /etc/systemd/system/
sudo mkdir -p /etc/wxd-tunnels
sudo cp systemd/ui.env systemd/minio.env systemd/presto.env /etc/wxd-tunnels/

sudo systemctl daemon-reload
sudo systemctl enable wxd-pf@ui wxd-pf@minio wxd-pf@presto
```

> El unit template usa `Environment=KUBECONFIG=/root/.kube/config` — correcto si instalaste con
> `sudo` (kind escribe el kubeconfig en el `$HOME` de root). Ajusta la ruta si es otra.

Estos servicios usan los puertos **9443 / 9101 / 9200**, distintos de los **6443 / 9001 / 8381**
que abre `installer.sh`, por lo que ambos pueden coexistir.

## 5. Instalar el script de gestión

```bash
sudo cp scripts/wxd-tunnels.sh /usr/local/bin/wxd-tunnels.sh
sudo chmod +x /usr/local/bin/wxd-tunnels.sh
```

## 6. Uso diario

```bash
sudo /usr/local/bin/wxd-tunnels.sh
```

```
1) Levantar tuneles     → arranca port-forwards (systemd) + 3 túneles ngrok
2) Detener tuneles       → detiene todo (systemctl stop + kill de ngrok)
3) Ver estado            → status de servicios, puertos, procesos ngrok
4) Reiniciar             → detener + levantar
```

## 7. Recuperación tras reinicio de la VM

Si la VM se reinicia:

1. Verifica que el cluster KIND siga corriendo:
   ```bash
   docker ps | grep kind-wxd
   kubectl -n wxd get pods
   ```
   Docker queda habilitado (`systemctl enable docker` lo hace `installer.sh`), pero el contenedor
   `kind-wxd-control-plane` puede quedar detenido. En ese caso (comando de la guía oficial de IBM):
   ```bash
   docker start kind-wxd-control-plane
   ```
   Para detener el entorno y liberar recursos sin desinstalar (también oficial):
   ```bash
   docker stop kind-wxd-control-plane
   ```
   Si el cluster no se recupera, reinstala con `sudo ./scripts/setup-watsonx-data.sh`
   (`helm upgrade --install` es idempotente; `kind create cluster` fallará si ya existe, ver Troubleshooting).

2. Una vez el cluster esté sano, simplemente corre de nuevo:
   ```bash
   sudo /usr/local/bin/wxd-tunnels.sh
   ```
   y elige **1) Levantar túneles**. Los servicios systemd ya quedaron habilitados
   (`systemctl enable`), así que sobreviven al reinicio por sí solos; ngrok se relanza
   manualmente vía el script (no corre como servicio systemd en esta versión).

   Los port-forwards de `installer.sh` (6443/9001/8381) **no** se recuperan solos; si los necesitas,
   relánzalos:
   ```bash
   export KUBECONFIG=~/.kube/config
   nohup kubectl port-forward -n wxd service/lhconsole-ui-svc 6443:443 --address 0.0.0.0 >/dev/null 2>&1 &
   ```

## 8. Desinstalar

```bash
sudo ./scripts/setup-watsonx-data.sh --uninstall                # pide confirmación
sudo ./scripts/setup-watsonx-data.sh --uninstall --yes          # sin confirmación
sudo ./scripts/setup-watsonx-data.sh --uninstall --purge --yes  # además desinstala Docker
```

Hace `helm uninstall wxd -n wxd`, detiene los port-forwards del instalador y ejecuta
`kind delete cluster --name kind-wxd`. Sin `--purge` **no** desinstala docker, kubectl, helm ni kind,
ni toca el kit de acceso remoto (para eso: `systemctl disable --now wxd-pf@ui wxd-pf@minio wxd-pf@presto`).

`--purge` añade `dnf remove -y docker-ce docker-ce-cli containerd.io`, igual que el "Cleaning up"
de la guía oficial de IBM para Linux (que además lista `kubectl delete namespace wxd`; es redundante
porque borrar el cluster KIND ya elimina el namespace). Es destructivo: quita Docker de la VM.
`--purge` solo es válido junto con `--uninstall`.

## Troubleshooting

| Síntoma | Causa / solución |
|---|---|
| `No se encontró el instalador` | El `.tar` no está en `installer/`; descárgalo o usa `--tar`. |
| `kind create cluster` falla con "node(s) already exist" | Quedó un cluster previo: `sudo ./scripts/setup-watsonx-data.sh --uninstall` y reinstala. |
| Pods en `ContainerCreating` durante mucho tiempo, `kube-apiserver` con reinicios, `EOF` / `connection reset by peer` en helm | Disco lento para etcd. Revisa `installer/diagnostics-*.log` y mide: `dd if=/dev/zero of=<dir-docker>/t bs=8k count=1000 oflag=dsync` (más de ~10 s en total es lento). Usa `--etcd-dir` hacia un disco más rápido o una VM con mejor almacenamiento. |
| `Ctrl+C` y siguen procesos | Usa el script más reciente. Comprueba con `pgrep -af 'installer.sh\|helm upgrade'`. |
| Pods en `ImagePullBackOff` | Sin acceso a `icr.io` o credenciales de `values-secret.yaml` inválidas; revisa red/proxy. |
| Instalación interrumpida | Revisa `installer/setup-watsonx-data.log`; el script se puede relanzar (es re-ejecutable). |
| Consola no abre en `:6443` | Puerto bloqueado en firewall (`firewall-cmd --add-port=6443/tcp`) o port-forward caído. |
