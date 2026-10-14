#!/bin/bash
#
# install-cloudflare.sh
#
# Configura acceso remoto a watsonx.data Developer Edition usando
# Cloudflare Tunnel — alternativa 100% gratuita a ngrok.
#
# Qué hace este script:
#   1. Instala el binario cloudflared (x86_64 / aarch64, RHEL/CentOS/Rocky/Alma)
#   2. Autentica contra la API de Cloudflare con un token
#   3. Crea un túnel nombrado vía API REST de Cloudflare
#   4. Detecta cómo generar las URLs de los 3 servicios (UI, MinIO, Presto):
#        - Si hay zona DNS activa → subdominios en tu dominio (ej. wxd-ui.tudominio.com)
#        - Si hay subdominio workers.dev habilitado → subdominios workers.dev gratuitos
#          (wxd-ui.<cuenta>.workers.dev) creando 3 Cloudflare Workers de proxy
#        - Si no hay ninguno → ofrece activar workers.dev o usar UUID (solo UI)
#   5. Escribe la config de cloudflared (/etc/cloudflared/config.yml)
#   6. Instala los servicios systemd de port-forward si no existen
#   7. Instala y habilita el servicio systemd wxd-cloudflared.service
#
# Uso:
#   sudo ./scripts/install-cloudflare.sh
#   sudo ./scripts/install-cloudflare.sh --token <CF_API_TOKEN> --account <CF_ACCOUNT_ID>
#   sudo ./scripts/install-cloudflare.sh --token <TOKEN> --account <ID> --zone <ZONE_ID> \
#        --domain <DOMINIO> --sub-ui wxd-ui --sub-minio wxd-minio --sub-presto wxd-presto
#   sudo ./scripts/install-cloudflare.sh --token <TOKEN> --account <ID> --workers-dev
#
# Opciones:
#   --token      <TOKEN>      API Token de Cloudflare
#                             Permisos necesarios: Cloudflare Tunnel:Edit + Workers Scripts:Edit
#                             + Workers Routes:Edit. DNS:Edit también si usas dominio propio.
#   --account    <ID>         Account ID de Cloudflare
#   --zone       <ZONE_ID>    Zone ID (opcional; si se omite el script lo detecta o usa workers.dev)
#   --domain     <DOMINIO>    Dominio base (ej. midominio.com; solo si se especifica --zone)
#   --sub-ui     <SUBDOMINIO> Subdominio para la Lakehouse UI (default: wxd-ui)
#   --sub-minio  <SUBDOMINIO> Subdominio para MinIO Console (default: wxd-minio)
#   --sub-presto <SUBDOMINIO> Subdominio para Presto UI (default: wxd-presto)
#   --tunnel-name <NOMBRE>    Nombre del túnel en Cloudflare (default: wxd-dev)
#   --workers-dev             Fuerza el modo workers.dev (sin dominio propio)
#   --uninstall               Elimina el servicio, config, Workers y el túnel de Cloudflare
#   --yes                     Sin prompts de confirmación
#   --help
#
# Requisitos:
#   - curl, jq, openssl disponibles en la VM.
#   - Token de Cloudflare con permisos: Cloudflare Tunnel:Edit, Workers Scripts:Edit,
#     Workers Routes:Edit. Crear en: https://dash.cloudflare.com/profile/api-tokens

set -euo pipefail

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}>>  $*${NC}"; }
ok()      { echo -e "${GREEN}    OK  $*${NC}"; }
warn()    { echo -e "${YELLOW}    AVISO  $*${NC}"; }
die()     { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

# ─── Defaults ───────────────────────────────────────────────────────────────
CF_TOKEN=""
CF_ACCOUNT_ID=""
CF_ZONE_ID=""
CF_DOMAIN=""
SUB_UI="wxd-ui"
SUB_MINIO="wxd-minio"
SUB_PRESTO="wxd-presto"
TUNNEL_NAME="wxd-dev"
UNINSTALL=false
AUTO_YES=false
FORCE_WORKERS_DEV=false
USE_WORKERS_DEV=false
CF_WORKERS_SUBDOMAIN=""   # <cuenta>.workers.dev — se detecta vía API

CF_CONFIG_DIR="/etc/cloudflared"
CF_CONFIG_FILE="$CF_CONFIG_DIR/config.yml"
CF_CREDS_FILE="$CF_CONFIG_DIR/tunnel-creds.json"
CF_API="https://api.cloudflare.com/client/v4"

# ─── Parseo de argumentos ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)        CF_TOKEN="$2";        shift 2 ;;
    --account)      CF_ACCOUNT_ID="$2";   shift 2 ;;
    --zone)         CF_ZONE_ID="$2";      shift 2 ;;
    --domain)       CF_DOMAIN="$2";       shift 2 ;;
    --sub-ui)       SUB_UI="$2";          shift 2 ;;
    --sub-minio)    SUB_MINIO="$2";       shift 2 ;;
    --sub-presto)   SUB_PRESTO="$2";      shift 2 ;;
    --tunnel-name)  TUNNEL_NAME="$2";     shift 2 ;;
    --workers-dev)  FORCE_WORKERS_DEV=true; shift ;;
    --uninstall)    UNINSTALL=true;       shift ;;
    --yes)          AUTO_YES=true;        shift ;;
    --help)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
      exit 0 ;;
    *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
  esac
done

# ─── Verificar root ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Ejecuta como root: sudo $0"

# ─── Helpers de API CF ──────────────────────────────────────────────────────
cf_get() {
  curl -fsSL -H "Authorization: Bearer ${CF_TOKEN}" \
       -H "Content-Type: application/json" \
       "${CF_API}${1}"
}

cf_post() {
  curl -fsSL -X POST \
       -H "Authorization: Bearer ${CF_TOKEN}" \
       -H "Content-Type: application/json" \
       --data "$2" \
       "${CF_API}${1}"
}

cf_put() {
  curl -fsSL -X PUT \
       -H "Authorization: Bearer ${CF_TOKEN}" \
       -H "Content-Type: application/json" \
       --data "$2" \
       "${CF_API}${1}"
}

cf_delete() {
  curl -fsSL -X DELETE \
       -H "Authorization: Bearer ${CF_TOKEN}" \
       -H "Content-Type: application/json" \
       "${CF_API}${1}"
}

# ─── DESINSTALAR ────────────────────────────────────────────────────────────
if $UNINSTALL; then
  info "Desinstalando Cloudflare Tunnel..."

  # Leer token si no se pasó
  if [[ -z "$CF_TOKEN" ]]; then
    read -rsp "CF API Token: " CF_TOKEN; echo
  fi
  if [[ -z "$CF_TOKEN" ]]; then
    warn "Sin token; solo se eliminarán archivos locales."
  fi

  # Detener y deshabilitar servicio
  if systemctl is-active --quiet wxd-cloudflared 2>/dev/null; then
    systemctl stop wxd-cloudflared
  fi
  systemctl disable wxd-cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/wxd-cloudflared.service
  systemctl daemon-reload

  if [[ -n "$CF_TOKEN" && -f "$CF_CREDS_FILE" ]]; then
    TUNNEL_ID=$(jq -r '.TunnelID // .tunnel_id // ""' "$CF_CREDS_FILE" 2>/dev/null || true)
    ACCOUNT_FROM_CREDS=$(jq -r '.AccountTag // .account_id // ""' "$CF_CREDS_FILE" 2>/dev/null || true)
    [[ -z "$CF_ACCOUNT_ID" ]] && CF_ACCOUNT_ID="$ACCOUNT_FROM_CREDS"

    # Eliminar Workers de proxy (modo workers.dev) antes de eliminar el túnel
    if [[ -n "$CF_ACCOUNT_ID" ]]; then
      for WORKER_NAME in "wxd-proxy-ui" "wxd-proxy-minio" "wxd-proxy-presto"; do
        WORKER_EXISTS=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" 2>/dev/null \
          | jq -r '.success // false')
        if [[ "$WORKER_EXISTS" == "true" ]]; then
          info "Eliminando Worker '${WORKER_NAME}'..."
          cf_delete "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" >/dev/null \
            || warn "No se pudo eliminar el Worker '${WORKER_NAME}'."
          ok "Worker '${WORKER_NAME}' eliminado."
        fi
      done
    fi

    # Eliminar túnel en CF API
    if [[ -n "$TUNNEL_ID" && -n "$CF_ACCOUNT_ID" ]]; then
      info "Eliminando túnel $TUNNEL_ID de Cloudflare..."
      cf_delete "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}?cascade=true" \
        || warn "No se pudo eliminar el túnel via API."
      ok "Túnel eliminado en Cloudflare."
    fi
  fi

  rm -rf "$CF_CONFIG_DIR"
  ok "Archivos de configuración eliminados."
  echo ""
  echo "Si quieres eliminar también el binario: rm -f /usr/local/bin/cloudflared"
  exit 0
fi

# ─── INSTALACIÓN ─────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
echo "  watsonx.data — Cloudflare Tunnel Setup"
echo "════════════════════════════════════════════════════════"
echo ""

# Verificar dependencias
info "Verificando dependencias..."
for cmd in curl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' no está instalado. Instálalo con: dnf install -y $cmd"
done
for c in kubectl docker; do
  command -v "$c" >/dev/null 2>&1 || warn "'$c' no encontrado. Corre primero: sudo ./scripts/setup-watsonx-data.sh"
done
ok "Dependencias OK."

# ─── Instalar cloudflared ────────────────────────────────────────────────────
info "Instalando cloudflared..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  CF_ARCH="amd64" ;;
  aarch64) CF_ARCH="arm64" ;;
  *) die "Arquitectura no soportada: $ARCH" ;;
esac

if ! command -v cloudflared >/dev/null 2>&1; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  info "  Descargando cloudflared (${CF_ARCH})..."
  curl -fsSL "$CF_URL" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
  # /usr/local/bin puede no estar en PATH de root con sudo secure_path;
  # se invoca con ruta absoluta para el mensaje de confirmación.
  ok "cloudflared instalado: $(/usr/local/bin/cloudflared --version)"
else
  ok "cloudflared ya instalado: $(command -v cloudflared | xargs -I{} {} --version)"
fi

# ─── Solicitar credenciales si no se pasaron ─────────────────────────────────
echo ""
if [[ -z "$CF_TOKEN" ]]; then
  echo "Necesitas un API Token de Cloudflare con permisos:"
  echo "  • Cloudflare Tunnel:Edit  (en la cuenta)"
  echo "  • DNS:Edit                (en la zona, si usas dominio propio)"
  echo "Créalo en: https://dash.cloudflare.com/profile/api-tokens"
  echo ""
  read -rsp "Pega tu Cloudflare API Token: " CF_TOKEN; echo
  [[ -z "$CF_TOKEN" ]] && die "El token es obligatorio."
fi

if [[ -z "$CF_ACCOUNT_ID" ]]; then
  echo ""
  echo "Account ID: lo encuentras en el panel derecho de https://dash.cloudflare.com"
  read -rp "Pega tu Account ID: " CF_ACCOUNT_ID
  [[ -z "$CF_ACCOUNT_ID" ]] && die "El Account ID es obligatorio."
fi

# ─── Verificar token ─────────────────────────────────────────────────────────
info "Verificando API Token..."
TOKEN_CHECK=$(cf_get "/user/tokens/verify" 2>/dev/null || true)
if ! echo "$TOKEN_CHECK" | jq -e '.success == true' >/dev/null 2>&1; then
  die "El API Token no es válido o no tiene los permisos necesarios."
fi
ok "Token válido."

# ─── Detectar zona DNS o subdominio workers.dev ──────────────────────────────
USE_DOMAIN=false

if [[ -n "$CF_ZONE_ID" && -n "$CF_DOMAIN" ]]; then
  USE_DOMAIN=true
  info "Usando zona y dominio especificados: $CF_DOMAIN"
elif $FORCE_WORKERS_DEV; then
  info "Modo workers.dev forzado con --workers-dev."
  USE_WORKERS_DEV=true
else
  info "Detectando zonas activas en tu cuenta Cloudflare..."
  ZONES_JSON=$(cf_get "/zones?account.id=${CF_ACCOUNT_ID}&status=active&per_page=50" 2>/dev/null || echo '{"result":[]}')
  ZONE_COUNT=$(echo "$ZONES_JSON" | jq '.result | length')

  if [[ "$ZONE_COUNT" -gt 0 ]]; then
    echo ""
    echo "  Zonas activas encontradas en tu cuenta:"
    echo ""
    mapfile -t ZONE_NAMES < <(echo "$ZONES_JSON" | jq -r '.result[].name')
    mapfile -t ZONE_IDS   < <(echo "$ZONES_JSON" | jq -r '.result[].id')

    for i in "${!ZONE_NAMES[@]}"; do
      echo "    $((i+1))) ${ZONE_NAMES[$i]}"
    done
    echo "    w) Usar workers.dev gratuito (3 subdominios <cuenta>.workers.dev)"
    echo "    0) Usar URL automática UUID (solo Lakehouse UI, sin subdominios)"
    echo ""
    read -rp "  Elige una zona [0-${ZONE_COUNT} / w]: " ZONE_CHOICE

    if [[ "$ZONE_CHOICE" =~ ^[1-9][0-9]*$ && "$ZONE_CHOICE" -le "$ZONE_COUNT" ]]; then
      IDX=$((ZONE_CHOICE-1))
      CF_ZONE_ID="${ZONE_IDS[$IDX]}"
      CF_DOMAIN="${ZONE_NAMES[$IDX]}"
      USE_DOMAIN=true
      ok "Usando zona: $CF_DOMAIN ($CF_ZONE_ID)"

      echo ""
      echo "  Subdominios que se crearán (Enter para aceptar el default):"
      read -rp "  Subdominio para Lakehouse UI   [${SUB_UI}]: " INPUT
      [[ -n "$INPUT" ]] && SUB_UI="$INPUT"
      read -rp "  Subdominio para MinIO Console  [${SUB_MINIO}]: " INPUT
      [[ -n "$INPUT" ]] && SUB_MINIO="$INPUT"
      read -rp "  Subdominio para Presto UI      [${SUB_PRESTO}]: " INPUT
      [[ -n "$INPUT" ]] && SUB_PRESTO="$INPUT"
    elif [[ "${ZONE_CHOICE,,}" == "w" ]]; then
      USE_WORKERS_DEV=true
    else
      info "Usando URL automática UUID."
      USE_DOMAIN=false
    fi
  else
    # Sin zonas: ofrecer workers.dev como alternativa antes de caer en UUID
    echo ""
    echo "  No hay zonas DNS en tu cuenta."
    echo "  Opciones:"
    echo "    w) Usar workers.dev gratuito (3 subdominios <cuenta>.workers.dev)"
    echo "    0) Usar URL UUID (solo Lakehouse UI)"
    echo ""
    read -rp "  Elige [w/0]: " NO_ZONE_CHOICE
    if [[ "${NO_ZONE_CHOICE,,}" == "w" ]]; then
      USE_WORKERS_DEV=true
    else
      warn "Sin dominio ni workers.dev: solo se expone Lakehouse UI vía URL UUID."
      USE_DOMAIN=false
    fi
  fi
fi

# ─── Crear / reusar túnel vía API ─────────────────────────────────────────────
info "Creando túnel Cloudflare '${TUNNEL_NAME}'..."
mkdir -p "$CF_CONFIG_DIR"

# Verificar si ya existe un túnel con ese nombre
EXISTING=$(cf_get "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" 2>/dev/null || echo '{"result":[]}')
EXISTING_ID=$(echo "$EXISTING" | jq -r '.result[0].id // ""')

if [[ -n "$EXISTING_ID" ]]; then
  warn "Ya existe un túnel llamado '${TUNNEL_NAME}' (ID: ${EXISTING_ID})."
  if $AUTO_YES; then
    TUNNEL_ID="$EXISTING_ID"
    info "Reusando túnel existente."
  else
    read -rp "  ¿Reusar el túnel existente? [S/n]: " REUSE
    if [[ "$REUSE" =~ ^[Nn]$ ]]; then
      read -rp "  Nuevo nombre para el túnel: " TUNNEL_NAME
      EXISTING_ID=""
    fi
  fi
fi

if [[ -z "$EXISTING_ID" ]]; then
  # Generar secret del túnel (32 bytes aleatorios en base64)
  TUNNEL_SECRET=$(openssl rand -base64 32)
  CREATE_RESP=$(cf_post "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
    "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"${TUNNEL_SECRET}\"}")

  if ! echo "$CREATE_RESP" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "$CREATE_RESP" | jq .
    die "No se pudo crear el túnel. Revisa los permisos del token."
  fi

  TUNNEL_ID=$(echo "$CREATE_RESP" | jq -r '.result.id')
  ACCOUNT_TAG=$(echo "$CREATE_RESP" | jq -r '.result.account_tag')

  # Escribir credentials file
  jq -n \
    --arg AccountTag "$ACCOUNT_TAG" \
    --arg TunnelID "$TUNNEL_ID" \
    --arg TunnelName "$TUNNEL_NAME" \
    --arg TunnelSecret "$TUNNEL_SECRET" \
    '{AccountTag:$AccountTag,TunnelID:$TunnelID,TunnelName:$TunnelName,TunnelSecret:$TunnelSecret}' \
    > "$CF_CREDS_FILE"
  chmod 600 "$CF_CREDS_FILE"
  ok "Túnel creado: ${TUNNEL_ID}"
else
  TUNNEL_ID="$EXISTING_ID"
  # Obtener el credentials file via API (solo si no existe localmente)
  if [[ ! -f "$CF_CREDS_FILE" ]]; then
    warn "El túnel existe pero no hay credentials locales. Regenerando token del túnel..."
    TUNNEL_SECRET=$(openssl rand -base64 32)
    REGEN=$(cf_put "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
      "{\"tunnel_secret\":\"${TUNNEL_SECRET}\"}" 2>/dev/null || echo '{}')
    ACCOUNT_TAG=$(cf_get "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" | jq -r '.result.account_tag // ""')
    jq -n \
      --arg AccountTag "$ACCOUNT_TAG" \
      --arg TunnelID "$TUNNEL_ID" \
      --arg TunnelName "$TUNNEL_NAME" \
      --arg TunnelSecret "$TUNNEL_SECRET" \
      '{AccountTag:$AccountTag,TunnelID:$TunnelID,TunnelName:$TunnelName,TunnelSecret:$TunnelSecret}' \
      > "$CF_CREDS_FILE"
    chmod 600 "$CF_CREDS_FILE"
  fi
fi

# ─── Crear registros DNS (modo dominio propio) ────────────────────────────────
if $USE_DOMAIN; then
  info "Creando registros DNS CNAME en ${CF_DOMAIN}..."
  for SUBDOMAIN in "$SUB_UI" "$SUB_MINIO" "$SUB_PRESTO"; do
    HOSTNAME="${SUBDOMAIN}.${CF_DOMAIN}"
    EXISTING_DNS=$(cf_get "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}" | jq -r '.result[0].id // ""')
    DNS_CONTENT="${TUNNEL_ID}.cfargotunnel.com"
    if [[ -n "$EXISTING_DNS" ]]; then
      cf_put "/zones/${CF_ZONE_ID}/dns_records/${EXISTING_DNS}" \
        "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${DNS_CONTENT}\",\"proxied\":true,\"ttl\":1}" >/dev/null
      ok "DNS actualizado: ${HOSTNAME}"
    else
      cf_post "/zones/${CF_ZONE_ID}/dns_records" \
        "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${DNS_CONTENT}\",\"proxied\":true,\"ttl\":1}" >/dev/null
      ok "DNS creado: ${HOSTNAME}"
    fi
  done

  URL_UI="https://${SUB_UI}.${CF_DOMAIN}"
  URL_MINIO="https://${SUB_MINIO}.${CF_DOMAIN}"
  URL_PRESTO="https://${SUB_PRESTO}.${CF_DOMAIN}"

# ─── Crear Workers de proxy (modo workers.dev) ───────────────────────────────
elif $USE_WORKERS_DEV; then
  info "Configurando acceso vía workers.dev..."

  # Obtener el subdominio workers.dev de la cuenta
  WD_RESP=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" 2>/dev/null || echo '{"result":null}')
  CF_WORKERS_SUBDOMAIN=$(echo "$WD_RESP" | jq -r '.result.subdomain // ""')

  if [[ -z "$CF_WORKERS_SUBDOMAIN" ]]; then
    # El subdominio workers.dev no existe — hay que crearlo/habilitarlo
    info "  Activando subdominio workers.dev en tu cuenta..."
    # Cloudflare asigna el subdominio automáticamente al hacer el primer PUT
    WD_PUT=$(cf_put "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" \
      "{\"subdomain\":\"\"}" 2>/dev/null || echo '{"result":null}')
    CF_WORKERS_SUBDOMAIN=$(echo "$WD_PUT" | jq -r '.result.subdomain // ""')

    if [[ -z "$CF_WORKERS_SUBDOMAIN" ]]; then
      die "No se pudo obtener/activar el subdominio workers.dev.
   Ve a https://dash.cloudflare.com → Workers & Pages → tu subdominio
   y actívalo manualmente, luego vuelve a ejecutar este script."
    fi
  fi

  ok "Subdominio workers.dev: ${CF_WORKERS_SUBDOMAIN}.workers.dev"

  # Nombres de los Workers y sus backends en el túnel
  # El Worker hace fetch hacia el túnel con el Host header correcto para
  # que cloudflared enrute al servicio local correspondiente.
  declare -A WORKER_BACKEND=(
    ["wxd-proxy-ui"]="https://${TUNNEL_ID}.cfargotunnel.com"
    ["wxd-proxy-minio"]="https://${TUNNEL_ID}.cfargotunnel.com"
    ["wxd-proxy-presto"]="https://${TUNNEL_ID}.cfargotunnel.com"
  )
  declare -A WORKER_HOST=(
    ["wxd-proxy-ui"]="${SUB_UI}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
    ["wxd-proxy-minio"]="${SUB_MINIO}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
    ["wxd-proxy-presto"]="${SUB_PRESTO}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
  )
  declare -A WORKER_TUNNEL_HOST=(
    ["wxd-proxy-ui"]="${SUB_UI}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
    ["wxd-proxy-minio"]="${SUB_MINIO}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
    ["wxd-proxy-presto"]="${SUB_PRESTO}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
  )

  info "  Creando/actualizando 3 Workers de proxy..."
  for WORKER_NAME in "wxd-proxy-ui" "wxd-proxy-minio" "wxd-proxy-presto"; do
    TUNNEL_URL="${WORKER_BACKEND[$WORKER_NAME]}"
    # Script JS del Worker: reenvía el request al túnel preservando método,
    # headers y body. noTLSVerify se gestiona en el config.yml de cloudflared.
    WORKER_JS=$(cat <<JSEOF
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const target = new URL("${TUNNEL_URL}");
    url.hostname = target.hostname;
    url.protocol = target.protocol;
    url.port = target.port || "";
    const proxied = new Request(url.toString(), request);
    return fetch(proxied);
  }
};
JSEOF
)
    # La API de Workers usa multipart/form-data con dos partes:
    # "metadata" (JSON con main_module) y el script JS como "script".
    METADATA='{"main_module":"worker.js","compatibility_date":"2024-01-01","usage_model":"bundled"}'

    UPLOAD_RESP=$(curl -fsSL -X PUT \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -F "metadata=${METADATA};type=application/json" \
      -F "script=${WORKER_JS};filename=worker.js;type=application/javascript+module" \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" 2>/dev/null || echo '{"success":false}')

    if ! echo "$UPLOAD_RESP" | jq -e '.success == true' >/dev/null 2>&1; then
      echo "$UPLOAD_RESP" | jq -r '.errors // . | tostring' >&2
      die "No se pudo subir el Worker '${WORKER_NAME}'. Verifica que el token tenga permiso Workers Scripts:Edit."
    fi
    ok "Worker '${WORKER_NAME}' subido."

    # Habilitar la ruta workers.dev (<sub>.<cuenta>.workers.dev) en el Worker
    SUBDOMAIN_RESP=$(cf_post \
      "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" \
      '{"enabled":true}' 2>/dev/null || echo '{"success":false}')
    if ! echo "$SUBDOMAIN_RESP" | jq -e '.success == true' >/dev/null 2>&1; then
      warn "No se pudo habilitar la ruta workers.dev para '${WORKER_NAME}' (puede tardar unos segundos — normal)."
    else
      ok "Ruta workers.dev habilitada: ${WORKER_HOST[$WORKER_NAME]}"
    fi
  done

  URL_UI="https://${SUB_UI}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
  URL_MINIO="https://${SUB_MINIO}.${CF_WORKERS_SUBDOMAIN}.workers.dev"
  URL_PRESTO="https://${SUB_PRESTO}.${CF_WORKERS_SUBDOMAIN}.workers.dev"

else
  URL_UI="https://${TUNNEL_ID}.cfargotunnel.com"
  URL_MINIO="https://${TUNNEL_ID}.cfargotunnel.com"
  URL_PRESTO="https://${TUNNEL_ID}.cfargotunnel.com"
  warn "Sin dominio ni workers.dev: solo se expone Lakehouse UI vía URL UUID."
  warn "Para exponer los 3 servicios ejecuta con --workers-dev o agrega un dominio a Cloudflare."
fi

# ─── Escribir config.yml de cloudflared ──────────────────────────────────────
info "Escribiendo config: ${CF_CONFIG_FILE}..."

if $USE_DOMAIN; then
cat > "$CF_CONFIG_FILE" <<EOF
# Cloudflare Tunnel — watsonx.data Developer Edition (modo dominio propio)
# Generado por install-cloudflare.sh el $(date '+%Y-%m-%d %H:%M:%S')
tunnel: ${TUNNEL_ID}
credentials-file: ${CF_CREDS_FILE}

ingress:
  - hostname: ${SUB_UI}.${CF_DOMAIN}
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
  - hostname: ${SUB_MINIO}.${CF_DOMAIN}
    service: http://localhost:9101
  - hostname: ${SUB_PRESTO}.${CF_DOMAIN}
    service: https://localhost:9200
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
elif $USE_WORKERS_DEV; then
# En modo workers.dev los Workers hacen proxy hacia el túnel usando el hostname
# del Worker como Host. cloudflared enruta por hostname a cada servicio local.
cat > "$CF_CONFIG_FILE" <<EOF
# Cloudflare Tunnel — watsonx.data Developer Edition (modo workers.dev)
# Generado por install-cloudflare.sh el $(date '+%Y-%m-%d %H:%M:%S')
tunnel: ${TUNNEL_ID}
credentials-file: ${CF_CREDS_FILE}

ingress:
  - hostname: ${SUB_UI}.${CF_WORKERS_SUBDOMAIN}.workers.dev
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
  - hostname: ${SUB_MINIO}.${CF_WORKERS_SUBDOMAIN}.workers.dev
    service: http://localhost:9101
  - hostname: ${SUB_PRESTO}.${CF_WORKERS_SUBDOMAIN}.workers.dev
    service: https://localhost:9200
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
else
cat > "$CF_CONFIG_FILE" <<EOF
# Cloudflare Tunnel — watsonx.data Developer Edition (modo UUID, solo UI)
# Generado por install-cloudflare.sh el $(date '+%Y-%m-%d %H:%M:%S')
tunnel: ${TUNNEL_ID}
credentials-file: ${CF_CREDS_FILE}

ingress:
  - service: https://localhost:9443
    originRequest:
      noTLSVerify: true
EOF
fi

chmod 600 "$CF_CONFIG_FILE"
ok "config.yml escrito."

# ─── Instalar servicios systemd de port-forward (si aún no están) ────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PF_UNIT_SRC="${REPO_ROOT}/systemd/wxd-pf@.service"
PF_ENV_DIR="/etc/wxd-tunnels"

if [[ ! -f /etc/systemd/system/wxd-pf@.service ]]; then
  info "Instalando servicios systemd de port-forward (wxd-pf@ui/minio/presto)..."
  if [[ -f "$PF_UNIT_SRC" ]]; then
    install -m 0644 "$PF_UNIT_SRC" /etc/systemd/system/wxd-pf@.service
    install -d "$PF_ENV_DIR"
    install -m 0644 \
      "${REPO_ROOT}/systemd/ui.env" \
      "${REPO_ROOT}/systemd/minio.env" \
      "${REPO_ROOT}/systemd/presto.env" \
      "$PF_ENV_DIR/"
    systemctl daemon-reload
    systemctl enable --now wxd-pf@ui wxd-pf@minio wxd-pf@presto
    ok "Servicios wxd-pf@ui/minio/presto habilitados."
  else
    warn "No se encontró ${PF_UNIT_SRC}; los port-forwards deben estar instalados manualmente."
    warn "Ver docs/CLOUDFLARE-SETUP.md sección 0."
  fi
else
  ok "Servicios wxd-pf@* ya instalados."
fi

# ─── Instalar servicio systemd wxd-cloudflared ───────────────────────────────
info "Instalando servicio systemd wxd-cloudflared..."

SYSTEMD_SRC="${REPO_ROOT}/systemd/wxd-cloudflared.service"

if [[ -f "$SYSTEMD_SRC" ]]; then
  cp "$SYSTEMD_SRC" /etc/systemd/system/wxd-cloudflared.service
else
  # Generar el unit inline si el repo no está disponible.
  # Se usa Wants= (no Requires=) para que cloudflared arranque aunque los
  # port-forwards tarden o fallen temporalmente — systemd los reintentará.
  cat > /etc/systemd/system/wxd-cloudflared.service <<'UNIT'
[Unit]
Description=Cloudflare Tunnel for watsonx.data Developer Edition
After=network-online.target wxd-pf@ui.service wxd-pf@minio.service wxd-pf@presto.service
Wants=network-online.target wxd-pf@ui.service wxd-pf@minio.service wxd-pf@presto.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable wxd-cloudflared
systemctl restart wxd-cloudflared
sleep 3

if systemctl is-active --quiet wxd-cloudflared; then
  ok "Servicio wxd-cloudflared activo y habilitado."
else
  warn "El servicio no levantó. Revisa: journalctl -u wxd-cloudflared -n 40"
fi

# ─── Guardar URLs para uso por wxd-tunnels-cf.sh ─────────────────────────────
cat > "${CF_CONFIG_DIR}/wxd-urls.env" <<EOF
# URLs generadas por install-cloudflare.sh — $(date '+%Y-%m-%d %H:%M:%S')
CF_TUNNEL_ID="${TUNNEL_ID}"
CF_TUNNEL_NAME="${TUNNEL_NAME}"
USE_DOMAIN="${USE_DOMAIN}"
USE_WORKERS_DEV="${USE_WORKERS_DEV}"
CF_DOMAIN="${CF_DOMAIN:-}"
CF_WORKERS_SUBDOMAIN="${CF_WORKERS_SUBDOMAIN:-}"
URL_UI="${URL_UI}"
URL_MINIO="${URL_MINIO}"
URL_PRESTO="${URL_PRESTO}"
EOF
chmod 600 "${CF_CONFIG_DIR}/wxd-urls.env"

# ─── Resumen final ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✅  Cloudflare Tunnel configurado exitosamente"
echo "════════════════════════════════════════════════════════"
echo ""
if $USE_DOMAIN || $USE_WORKERS_DEV; then
  echo "  Lakehouse UI  : ${URL_UI}"
  echo "  MinIO Console : ${URL_MINIO}"
  echo "  Presto UI     : ${URL_PRESTO}"
  if $USE_WORKERS_DEV; then
    echo ""
    echo "  (Modo workers.dev: si alguna URL tarda en responder espera ~30 s"
    echo "   a que Cloudflare propague los Workers recién creados.)"
  fi
else
  echo "  URL base (UUID): ${URL_UI}"
  echo ""
  echo "  (Modo UUID: solo Lakehouse UI expuesta."
  echo "   Para los 3 servicios: re-ejecuta con --workers-dev o agrega"
  echo "   un dominio a Cloudflare.)"
fi
echo ""
echo "  Credenciales default: ver docs/CREDENTIALS.md"
echo ""
echo "  Estado del servicio  : systemctl status wxd-cloudflared"
echo "  Logs en tiempo real  : journalctl -u wxd-cloudflared -f"
echo "  Gestión interactiva  : sudo wxd-tunnels-cf.sh"
echo "  Desinstalar          : sudo $0 --uninstall --token <TOKEN>"
echo ""
