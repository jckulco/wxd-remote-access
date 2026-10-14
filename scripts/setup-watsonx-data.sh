#!/bin/bash
#
# setup-watsonx-data.sh
#
# Instala IBM watsonx.data Developer Edition de forma automática en una VM RHEL
# (RHEL / Rocky / Alma / CentOS Stream), siguiendo los pasos documentados por IBM:
#
#   1. Extraer el .tar del instalador        (rm -rf <dir>; tar -xvf <tar>)
#   2. Entrar al directorio extraído         (cd <dir>)
#   3. Hacer ejecutable installer.sh         (chmod +x installer.sh)
#   4. Correr el instalador                  (./installer.sh)
#   5. Revisar el avance de los pods         (kubectl get po -n wxd)
#   6. Exponer la consola (port-forward)     (6443 -> lhconsole-ui-svc:443)
#   7. Mostrar URL de acceso y credenciales
#   8. (opcional) Desinstalar                (--uninstall)
#
# El installer.sh incluido en el .tar de IBM se encarga de instalar docker,
# kubectl, helm y kind, crear el cluster KIND "kind-wxd" y desplegar el chart
# Helm "wxd" en el namespace "wxd".
#
# Mejoras sobre el flujo base de IBM:
#   - Ctrl+C detiene de verdad installer.sh y helm (no quedan procesos huérfanos).
#   - Mide la latencia de fsync del disco de Docker; si es lenta, mueve los datos de
#     etcd del cluster KIND a un disco más rápido (el API server se reinicia en
#     discos lentos y la instalación no converge).
#   - Verifica el resultado real (installer.sh devuelve 0 aunque falle helm/kind).
#   - Si algo falla, se interrumpe o se desinstala, guarda un diagnóstico en
#     installer/diagnostics-<fecha>.log antes de perder los logs del cluster.
#
# Uso:
#   sudo ./scripts/setup-watsonx-data.sh [opciones]
#
# Opciones:
#   --tar RUTA          Ruta al .tar del instalador
#                       (default: installer/watsonx.data-developer-edition-installer.tar,
#                        o la variable de entorno WXD_TAR)
#   --remote-access     Al terminar, instala también el kit de acceso remoto:
#                       ngrok, units systemd (wxd-pf@*) y wxd-tunnels.sh
#   --etcd-dir RUTA     Fuerza mover etcd a RUTA (directorio en un disco rápido)
#   --no-etcd-relocate  No mover etcd aunque el disco de Docker sea lento
#                       (default: automático según la latencia medida;
#                        umbral 10 ms, ajustable con WXD_FSYNC_MAX_MS)
#   --uninstall         Desinstala watsonx.data (helm uninstall + borra el cluster KIND)
#   -y, --yes           No pedir confirmación (solo aplica a --uninstall)
#   -h, --help          Muestra esta ayuda

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALLER_DIR="$REPO_DIR/installer"
TAR_FILE="${WXD_TAR:-$INSTALLER_DIR/watsonx.data-developer-edition-installer.tar}"
LOG_FILE="$INSTALLER_DIR/setup-watsonx-data.log"

NAMESPACE="wxd"
HELM_RELEASE="wxd"
KIND_CLUSTER="kind-wxd"
UI_SVC="lhconsole-ui-svc"
UI_LOCAL_PORT=6443
UI_REMOTE_PORT=443
# Puertos de los port-forwards que lanza installer.sh de IBM
IBM_PF_PORTS_REGEX='6443:443|9001:9001|8381:8381'

# Reubicación de etcd: auto (según fsync medido) | forced (--etcd-dir) | off
ETCD_DIR="/var/lib/kind-wxd-etcd"
ETCD_MODE="auto"
FSYNC_MAX_US=$(( ${WXD_FSYNC_MAX_MS:-10} * 1000 ))
ETCD_RELOCATED=false

INSTALLER_PID=""
TAIL_PID=""

WITH_REMOTE_ACCESS=false
DO_UNINSTALL=false
ASSUME_YES=false

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
log()   { echo ">> $*"; }
warn()  { echo "AVISO: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tar)              [ $# -ge 2 ] || die "--tar requiere una ruta"; TAR_FILE="$2"; shift 2 ;;
    --remote-access)    WITH_REMOTE_ACCESS=true; shift ;;
    --etcd-dir)         [ $# -ge 2 ] || die "--etcd-dir requiere una ruta"; ETCD_DIR="$2"; ETCD_MODE="forced"; shift 2 ;;
    --no-etcd-relocate) ETCD_MODE="off"; shift ;;
    --uninstall)        DO_UNINSTALL=true; shift ;;
    -y|--yes)           ASSUME_YES=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

case "$ETCD_DIR" in
  /|"") die "--etcd-dir inválido: '$ETCD_DIR'" ;;
  /*)   ;;
  *)    die "--etcd-dir debe ser una ruta absoluta: '$ETCD_DIR'" ;;
esac

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Este script debe correr como root (usa sudo): el instalador de IBM instala paquetes con dnf/yum."
}

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# installer.sh de IBM instala helm y kind en /usr/local/bin, que no siempre está
# en el PATH de root (sudo secure_path); sin esto "helm/kind: command not found".
export PATH="$PATH:/usr/local/bin"

# El .tar fue creado en macOS: GNU tar avisa de cabeceras 'LIBARCHIVE.xattr.*' (inofensivo).
TAR_OPTS=(--warning=no-unknown-keyword)

# ---------------------------------------------------------------------------
# Utilidades de disco
# ---------------------------------------------------------------------------

# Primer ancestro existente de una ruta (para medir aunque el directorio aún no exista).
existing_ancestor() {
  local d="$1"
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  echo "$d"
}

# Directorio raíz de datos de Docker (o el default si docker aún no está instalado).
docker_root_dir() {
  local d=""
  if command -v docker >/dev/null 2>&1; then
    d="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  fi
  [ -n "$d" ] || d="/var/lib/docker"
  existing_ancestor "$d"
}

# Latencia media de una escritura síncrona (8 KB + fsync) en el disco que contiene DIR,
# en microsegundos. Es el patrón de escritura de etcd (sano: < ~10 ms).
# Imprime vacío si no se pudo medir.
fsync_us() {
  local dir="$1" n=200 f t0 t1
  f="$dir/.wxd-fsync-test.$$"
  t0="$(date +%s%N)"
  dd if=/dev/zero of="$f" bs=8k count="$n" oflag=dsync 2>/dev/null || { rm -f "$f"; return 0; }
  t1="$(date +%s%N)"
  rm -f "$f"
  echo $(( (t1 - t0) / 1000 / n ))
}

fmt_ms() { awk -v u="$1" 'BEGIN{printf "%.1f ms", u/1000}'; }

# ---------------------------------------------------------------------------
# Diagnóstico (se guarda antes de que se pierdan los logs del cluster)
# ---------------------------------------------------------------------------
diag_run() { echo ""; echo "--- $*"; timeout 20 "$@" 2>&1 || true; }

collect_diagnostics() {
  local reason="$1" node="${KIND_CLUSTER}-control-plane" names out
  command -v docker >/dev/null 2>&1 || return 0
  names="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
  grep -qx "$node" <<<"$names" || return 0

  out="$INSTALLER_DIR/diagnostics-$(date +%Y%m%d-%H%M%S).log"
  log "Guardando diagnóstico del cluster en $out ..."
  {
    echo "=== Diagnóstico: $reason ($(date)) ==="
    diag_run uptime
    diag_run free -m
    diag_run df -h
    diag_run docker ps -a
    diag_run kubectl --request-timeout=10s get pods -n "$NAMESPACE"
    diag_run kubectl --request-timeout=10s get events -n "$NAMESPACE" --sort-by=.lastTimestamp
    diag_run docker exec "$node" sh -c 'crictl ps -a | grep -E "kube-apiserver|etcd"'
    diag_run docker exec "$node" sh -c 'id=$(crictl ps -a --name kube-apiserver --state exited -q | head -1); [ -n "$id" ] && crictl logs "$id" 2>&1 | tail -40 | cut -c1-250'
    diag_run docker exec "$node" sh -c 'id=$(crictl ps -a --name etcd -q | head -1); crictl logs "$id" 2>&1 | grep -iE "slow|took too long|fdatasync|overloaded" | tail -15 | cut -c1-250'
    diag_run docker exec "$node" sh -c 'journalctl -u kubelet --no-pager | grep kube-apiserver | grep -iE "probe|killing|unhealthy" | tail -15 | cut -c1-250'
    diag_run sh -c 'dmesg -T | grep -iE "out of memory|killed process|blocked for more" | tail -10'
  } >"$out" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Detener installer.sh / helm (Ctrl+C o fallo)
# ---------------------------------------------------------------------------
stop_installer() {
  if [ -n "$INSTALLER_PID" ] && kill -0 "$INSTALLER_PID" 2>/dev/null; then
    # installer.sh corre en su propia sesión (setsid): se mata todo su grupo.
    kill -TERM -- "-$INSTALLER_PID" 2>/dev/null || kill -TERM "$INSTALLER_PID" 2>/dev/null || true
    sleep 2
    kill -KILL -- "-$INSTALLER_PID" 2>/dev/null || true
  fi
  pkill -f "helm upgrade --install $HELM_RELEASE" 2>/dev/null || true
  [ -z "$TAIL_PID" ] || kill "$TAIL_PID" 2>/dev/null || true
}

on_interrupt() {
  trap - INT TERM
  echo "" >&2
  warn "Interrumpido: deteniendo installer.sh y helm..."
  # Primero se detiene todo (así un segundo Ctrl+C no deja procesos vivos) y después
  # se recolecta el diagnóstico, que puede tardar si el API server no responde.
  stop_installer
  collect_diagnostics "interrupcion del usuario" || true
  warn "Detenido. El cluster pudo quedar a medias; para limpiar: sudo $0 --uninstall --yes"
  exit 130
}

# ---------------------------------------------------------------------------
# Desinstalación (paso 8, opcional)
# ---------------------------------------------------------------------------
uninstall() {
  require_root
  if [ "$ASSUME_YES" != true ]; then
    read -r -p "Se desinstalará el release '$HELM_RELEASE' y se borrará el cluster KIND '$KIND_CLUSTER'. ¿Continuar? [s/N] " ans
    case "$ans" in s|S|y|Y) ;; *) echo "Cancelado."; exit 0 ;; esac
  fi

  collect_diagnostics "antes de desinstalar" || true

  if command -v helm >/dev/null 2>&1 && helm status "$HELM_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Desinstalando release Helm '$HELM_RELEASE' (namespace $NAMESPACE)..."
    helm uninstall "$HELM_RELEASE" -n "$NAMESPACE" || warn "helm uninstall falló, se continúa."
  else
    log "No hay release Helm '$HELM_RELEASE' instalado."
  fi

  log "Deteniendo procesos del instalador y port-forwards..."
  pkill -f "helm upgrade --install $HELM_RELEASE" 2>/dev/null || true
  pkill -f "kubectl port-forward.*($IBM_PF_PORTS_REGEX)" 2>/dev/null || true

  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    log "Borrando cluster KIND '$KIND_CLUSTER'..."
    kind delete cluster --name "$KIND_CLUSTER"
  else
    log "No existe el cluster KIND '$KIND_CLUSTER'."
  fi

  # Datos de etcd en el host (solo si se reubicaron): el cluster ya no existe.
  if [ -d "$ETCD_DIR/member" ]; then
    log "Limpiando datos de etcd en $ETCD_DIR ..."
    rm -rf "$ETCD_DIR/member"
    rmdir "$ETCD_DIR" 2>/dev/null || true
  fi

  echo "OK: watsonx.data desinstalado. (docker, kubectl, helm y kind se dejan instalados.)"
}

# ---------------------------------------------------------------------------
# Pre-chequeos
# ---------------------------------------------------------------------------
preflight() {
  log "Verificando prerrequisitos..."
  require_root

  command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 \
    || die "No se encontró dnf/yum. El instalador de IBM solo soporta RHEL y derivados."

  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "Arquitectura no soportada: $(uname -m) (solo x86_64 y aarch64)." ;;
  esac

  for c in tar curl setsid timeout; do
    command -v "$c" >/dev/null 2>&1 || die "Falta el comando '$c'."
  done

  [ -f "$TAR_FILE" ] || die "No se encontró el instalador: $TAR_FILE
   Descárgalo desde IBM y colócalo ahí (ver installer/README.md), o usa --tar RUTA."

  # (se evita 'tar | grep -q': con pipefail, grep -q cierra el pipe y tar muere por SIGPIPE)
  local listing
  listing="$(tar "${TAR_OPTS[@]}" -tf "$TAR_FILE" 2>/dev/null)" || die "No se pudo leer $TAR_FILE (¿tar corrupto?)."
  grep -qE '(^|/)installer\.sh$' <<<"$listing" \
    || die "El archivo $TAR_FILE no parece el instalador de watsonx.data (no contiene installer.sh)."

  getent hosts icr.io >/dev/null 2>&1 \
    || warn "No se resuelve icr.io; las imágenes de watsonx.data se descargan de ese registro."

  if command -v helm >/dev/null 2>&1 && helm status "$HELM_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "Ya existe el release Helm '$HELM_RELEASE' en '$NAMESPACE'; installer.sh hará 'helm upgrade --install'."
  fi
}

# ---------------------------------------------------------------------------
# etcd en un disco rápido
#
# El cluster KIND guarda etcd dentro del disco donde vive el directorio de datos de
# Docker. Si ese disco tiene fsync lento (típico de discos de datos secundarios en
# nubes), etcd responde tarde, el API server se reinicia y helm/kubelet fallan con
# 'EOF', 'connection reset by peer' y 'failed to sync configmap cache'.
# Solución: crear el cluster con un bind mount de /var/lib/etcd hacia otro directorio.
# installer.sh de IBM crea el cluster sin opciones, así que se le añade --config a una
# COPIA extraída del instalador (el .tar original no se toca).
# ---------------------------------------------------------------------------
setup_etcd_relocation() {
  local extract_dir="$1" cfg="$1/kind-wxd-config.yaml"

  if [ "$ETCD_MODE" = off ]; then
    log "Reubicación de etcd desactivada (--no-etcd-relocate)."
    return 0
  fi

  local docker_dir docker_us etcd_us
  docker_dir="$(docker_root_dir)"
  docker_us="$(fsync_us "$docker_dir")"
  etcd_us="$(fsync_us "$(existing_ancestor "$ETCD_DIR")")"

  if [ -z "$docker_us" ]; then
    warn "No se pudo medir la latencia de fsync en $docker_dir; no se reubica etcd."
    [ "$ETCD_MODE" = forced ] || return 0
  else
    log "Latencia fsync — disco de Docker ($docker_dir): $(fmt_ms "$docker_us"); destino etcd ($ETCD_DIR): $(fmt_ms "${etcd_us:-0}")"
  fi

  if [ "$ETCD_MODE" = auto ]; then
    if [ "$docker_us" -le "$FSYNC_MAX_US" ]; then
      log "Disco de Docker con latencia aceptable (<= $(fmt_ms "$FSYNC_MAX_US")); etcd queda donde lo pone KIND."
      return 0
    fi
    # Solo vale la pena si el destino es claramente más rápido (al menos 2x).
    if [ -z "$etcd_us" ] || [ $(( etcd_us * 2 )) -gt "$docker_us" ]; then
      warn "El disco de Docker es lento ($(fmt_ms "$docker_us")) y $ETCD_DIR no es claramente más rápido. No se reubica etcd.
         La instalación puede fallar (API server reiniciándose). Considera una VM con mejor disco
         o usa --etcd-dir con un directorio en un disco más rápido."
      return 0
    fi
    warn "Disco de Docker lento ($(fmt_ms "$docker_us") por fsync). Se mueve etcd a $ETCD_DIR."
  fi

  # Si el cluster ya existe, la configuración no se aplica.
  local clusters=""
  if command -v kind >/dev/null 2>&1; then clusters="$(kind get clusters 2>/dev/null || true)"; fi
  if grep -qx "$KIND_CLUSTER" <<<"$clusters"; then
    warn "El cluster '$KIND_CLUSTER' ya existe; no se puede reubicar etcd en caliente.
         Para aplicarlo: sudo $0 --uninstall --yes y vuelve a instalar."
    return 0
  fi

  # kubeadm exige que /var/lib/etcd esté vacío: se borra solo 'member' (datos de un cluster anterior).
  mkdir -p "$ETCD_DIR"
  rm -rf "$ETCD_DIR/member"
  # Con SELinux en Enforcing, etiqueta el directorio para que el contenedor pueda escribir.
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    chcon -Rt container_file_t "$ETCD_DIR" 2>/dev/null || warn "No se pudo etiquetar $ETCD_DIR para SELinux."
  fi

  cat > "$cfg" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: $ETCD_DIR
    containerPath: /var/lib/etcd
EOF

  if grep -q 'kind create cluster --name kind-wxd' "$extract_dir/installer.sh"; then
    sed -i "s|kind create cluster --name kind-wxd|kind create cluster --name kind-wxd --config $cfg|g" "$extract_dir/installer.sh"
    ETCD_RELOCATED=true
    log "installer.sh ajustado para crear el cluster con etcd en $ETCD_DIR (config: $cfg)."
  else
    warn "No se encontró 'kind create cluster --name kind-wxd' en installer.sh (¿cambió la versión del instalador?). No se reubica etcd."
  fi
}

# ---------------------------------------------------------------------------
# Pasos 1-4: extraer, chmod y correr installer.sh
# ---------------------------------------------------------------------------
run_installer() {
  # Directorio raíz que crea el .tar (varía según la versión del paquete)
  local listing top extract_dir
  listing="$(tar "${TAR_OPTS[@]}" -tf "$TAR_FILE")"
  top="${listing%%/*}"
  [ -n "$top" ] || die "No se pudo determinar el directorio raíz del .tar."
  extract_dir="$INSTALLER_DIR/$top"

  log "[1/4] Extrayendo $TAR_FILE en $INSTALLER_DIR ..."
  rm -rf "$extract_dir"
  tar "${TAR_OPTS[@]}" -xf "$TAR_FILE" -C "$INSTALLER_DIR"
  [ -f "$extract_dir/installer.sh" ] || die "installer.sh no está en $extract_dir"

  log "[2/4] Entrando a $extract_dir"
  cd "$extract_dir"

  log "[3/4] Haciendo ejecutable installer.sh"
  chmod 755 ./installer.sh
  setup_etcd_relocation "$extract_dir"

  log "[4/4] Ejecutando installer.sh (puede tardar bastante; log: $LOG_FILE)"
  log "      Ctrl+C lo detiene limpiamente. Avance en otra terminal: kubectl get po -n $NAMESPACE -w"
  # No se usa 'cmd | tee': installer.sh deja kubectl port-forward en background
  # heredando stdout, lo que dejaría el pipe abierto y colgaría a tee.
  : > "$LOG_FILE"
  trap on_interrupt INT TERM
  local rc=0
  # setsid: installer.sh queda en su propia sesión/grupo; así se puede matar completo
  # (installer.sh + helm) desde el trap. Sin esto, Ctrl+C lo dejaba huérfano.
  setsid ./installer.sh </dev/null >>"$LOG_FILE" 2>&1 &
  INSTALLER_PID=$!
  tail -n +1 -f --pid="$INSTALLER_PID" "$LOG_FILE" &
  TAIL_PID=$!
  wait "$INSTALLER_PID" || rc=$?
  wait "$TAIL_PID" 2>/dev/null || true   # espera a que tail termine de volcar el log
  trap - INT TERM

  if [ "$rc" -ne 0 ]; then
    collect_diagnostics "installer.sh terminó con código $rc" || true
    die "installer.sh terminó con código $rc. Revisa $LOG_FILE"
  fi
  log "installer.sh terminó con código 0; verificando que realmente quedó instalado..."
}

# installer.sh devuelve 0 aunque fallen helm/kind (su bucle de espera da "OK" si kubectl
# no responde), así que se comprueba explícitamente el resultado.
verify_install() {
  local ok=true out tool
  for tool in docker kubectl helm kind; do
    command -v "$tool" >/dev/null 2>&1 || { warn "No se encontró '$tool' en el PATH."; ok=false; }
  done

  # Se captura la salida en variables (no 'cmd | grep -q'): con pipefail daría falsos negativos por SIGPIPE.
  if [ "$ok" = true ]; then
    out="$(kind get clusters 2>/dev/null || true)"
    grep -qx "$KIND_CLUSTER" <<<"$out" \
      || { warn "No existe el cluster KIND '$KIND_CLUSTER'."; ok=false; }

    out="$(helm status "$HELM_RELEASE" -n "$NAMESPACE" 2>/dev/null || true)"
    grep -q 'STATUS: deployed' <<<"$out" \
      || { warn "El release Helm '$HELM_RELEASE' no está en estado 'deployed' (namespace $NAMESPACE)."; ok=false; }

    out="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || true)"
    [ -n "$out" ] \
      || { warn "No hay pods en el namespace '$NAMESPACE' (o kubectl no conecta al cluster)."; ok=false; }
  fi

  if [ "$ok" != true ]; then
    collect_diagnostics "verify_install fallo" || true
    die "La instalación NO se completó correctamente aunque installer.sh devolvió 0.
   Revisa $LOG_FILE (y installer/diagnostics-*.log) y vuelve a correr el script."
  fi
  log "Instalación verificada: cluster '$KIND_CLUSTER' y release '$HELM_RELEASE' presentes."

  if [ "$ETCD_RELOCATED" = true ]; then
    out="$(docker inspect "${KIND_CLUSTER}-control-plane" --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    if grep -qx "$ETCD_DIR:/var/lib/etcd" <<<"$out"; then
      log "etcd confirmado en $ETCD_DIR (montado en /var/lib/etcd del nodo)."
    else
      warn "Se pidió reubicar etcd en $ETCD_DIR pero el nodo no tiene ese montaje; etcd sigue en el disco de Docker."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Pasos 5-7: verificar pods, asegurar port-forward de la consola, mostrar acceso
# ---------------------------------------------------------------------------
verify_and_expose() {
  log "Verificando pods en el namespace '$NAMESPACE'..."
  kubectl get pods -n "$NAMESPACE"
  local not_ready
  not_ready="$(kubectl get pods -n "$NAMESPACE" --no-headers | grep -vE 'Running|Completed' | wc -l || true)"
  if [ "${not_ready:-0}" -gt 0 ]; then
    warn "$not_ready pod(s) aún no están Running/Completed. Sigue el avance con:
         kubectl get po -n $NAMESPACE -w"
  else
    log "Todos los pods están Running/Completed."
  fi

  if ss -tln 2>/dev/null | grep -q ":${UI_LOCAL_PORT} "; then
    log "Port-forward de la consola activo en el puerto $UI_LOCAL_PORT."
  else
    log "Levantando port-forward de la consola ($UI_LOCAL_PORT -> $UI_SVC:$UI_REMOTE_PORT)..."
    nohup setsid kubectl port-forward -n "$NAMESPACE" "service/$UI_SVC" \
      "${UI_LOCAL_PORT}:${UI_REMOTE_PORT}" --address 0.0.0.0 >/dev/null 2>&1 &
    sleep 3
  fi

  local host
  host="$(hostname -f 2>/dev/null || hostname)"
  echo ""
  echo "=========================================================="
  echo " watsonx.data Developer Edition instalado"
  echo "   Consola : https://${host}:${UI_LOCAL_PORT}/"
  echo "   Usuario : ibmlhadmin"
  echo "   Password: password   (default público de IBM, cámbiala: ver docs/CREDENTIALS.md)"
  echo ""
  echo "   Nota: los port-forwards de installer.sh NO sobreviven a un reinicio de la VM."
  echo "         Para acceso persistente/remoto usa --remote-access (ver docs/SETUP.md)."
  echo "=========================================================="
}

# ---------------------------------------------------------------------------
# Opcional: kit de acceso remoto (ngrok + systemd + wxd-tunnels.sh)
# ---------------------------------------------------------------------------
install_remote_access() {
  log "Instalando kit de acceso remoto..."
  "$SCRIPT_DIR/install-deps.sh"

  install -m 0644 "$REPO_DIR/systemd/wxd-pf@.service" /etc/systemd/system/wxd-pf@.service
  install -d /etc/wxd-tunnels
  install -m 0644 "$REPO_DIR"/systemd/ui.env "$REPO_DIR"/systemd/minio.env "$REPO_DIR"/systemd/presto.env /etc/wxd-tunnels/
  systemctl daemon-reload
  systemctl enable wxd-pf@ui wxd-pf@minio wxd-pf@presto
  install -m 0755 "$SCRIPT_DIR/wxd-tunnels.sh" /usr/local/bin/wxd-tunnels.sh

  echo ""
  echo "Kit de acceso remoto instalado. Pendiente (manual, requiere tu cuenta ngrok):"
  echo "  1. ngrok config add-authtoken <TU_TOKEN>"
  echo "  2. Reservar 3 dominios fijos y ajustar DOMAIN_* en /usr/local/bin/wxd-tunnels.sh"
  echo "  3. sudo /usr/local/bin/wxd-tunnels.sh   (opción 1)"
  echo "  Detalle: docs/SETUP.md"
}

# ---------------------------------------------------------------------------
main() {
  if [ "$DO_UNINSTALL" = true ]; then
    uninstall
    exit 0
  fi

  preflight
  run_installer
  verify_install
  verify_and_expose
  if [ "$WITH_REMOTE_ACCESS" = true ]; then
    install_remote_access
  fi
}

# Permite 'source' del script (pruebas) sin ejecutar main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
