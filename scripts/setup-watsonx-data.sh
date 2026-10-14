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
# Uso:
#   sudo ./scripts/setup-watsonx-data.sh [opciones]
#
# Opciones:
#   --tar RUTA        Ruta al .tar del instalador
#                     (default: installer/watsonx.data-developer-edition-installer.tar,
#                      o la variable de entorno WXD_TAR)
#   --remote-access   Al terminar, instala también el kit de acceso remoto:
#                     ngrok, units systemd (wxd-pf@*) y wxd-tunnels.sh
#   --uninstall       Desinstala watsonx.data (helm uninstall + borra el cluster KIND)
#   -y, --yes         No pedir confirmación (solo aplica a --uninstall)
#   -h, --help        Muestra esta ayuda

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

WITH_REMOTE_ACCESS=false
DO_UNINSTALL=false
ASSUME_YES=false

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
log()   { echo ">> $*"; }
warn()  { echo "AVISO: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tar)           [ $# -ge 2 ] || die "--tar requiere una ruta"; TAR_FILE="$2"; shift 2 ;;
    --remote-access) WITH_REMOTE_ACCESS=true; shift ;;
    --uninstall)     DO_UNINSTALL=true; shift ;;
    -y|--yes)        ASSUME_YES=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

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
# Desinstalación (paso 8, opcional)
# ---------------------------------------------------------------------------
uninstall() {
  require_root
  if [ "$ASSUME_YES" != true ]; then
    read -r -p "Se desinstalará el release '$HELM_RELEASE' y se borrará el cluster KIND '$KIND_CLUSTER'. ¿Continuar? [s/N] " ans
    case "$ans" in s|S|y|Y) ;; *) echo "Cancelado."; exit 0 ;; esac
  fi

  if command -v helm >/dev/null 2>&1 && helm status "$HELM_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Desinstalando release Helm '$HELM_RELEASE' (namespace $NAMESPACE)..."
    helm uninstall "$HELM_RELEASE" -n "$NAMESPACE" || warn "helm uninstall falló, se continúa."
  else
    log "No hay release Helm '$HELM_RELEASE' instalado."
  fi

  log "Deteniendo port-forwards del instalador..."
  pkill -f "kubectl port-forward.*($IBM_PF_PORTS_REGEX)" 2>/dev/null || true

  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    log "Borrando cluster KIND '$KIND_CLUSTER'..."
    kind delete cluster --name "$KIND_CLUSTER"
  else
    log "No existe el cluster KIND '$KIND_CLUSTER'."
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

  for c in tar curl; do
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

  log "[4/4] Ejecutando installer.sh (puede tardar bastante; log: $LOG_FILE)"
  # No se usa 'cmd | tee': installer.sh deja kubectl port-forward en background
  # heredando stdout, lo que dejaría el pipe abierto y colgaría a tee.
  : > "$LOG_FILE"
  local rc=0
  ./installer.sh </dev/null >>"$LOG_FILE" 2>&1 &
  local pid=$!
  tail -n +1 -f --pid="$pid" "$LOG_FILE" &
  wait "$pid" || rc=$?
  wait 2>/dev/null || true   # espera a que tail termine de volcar el log

  [ "$rc" -eq 0 ] || die "installer.sh terminó con código $rc. Revisa $LOG_FILE"
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

  [ "$ok" = true ] || die "La instalación NO se completó correctamente aunque installer.sh devolvió 0.
   Revisa $LOG_FILE (busca 'command not found' o errores de helm/kind) y vuelve a correr el script."
  log "Instalación verificada: cluster '$KIND_CLUSTER' y release '$HELM_RELEASE' presentes."
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

main
