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
#   4. Detecta si hay una zona activa en tu cuenta:
#        - Si hay zona → genera subdominos en tu dominio (ej. wxd-ui.tudominio.com)
#        - Si no hay zona → usa la URL automática UUID (*.cfargotunnel.com)
#   5. Escribe la config de cloudflared (/etc/cloudflared/config.yml)
#   6. Instala y habilita el servicio systemd wxd-cloudflared.service
#
# Uso:
#   sudo ./scripts/install-cloudflare.sh
#   sudo ./scripts/install-cloudflare.sh --token <CF_API_TOKEN> --account <CF_ACCOUNT_ID>
#   sudo ./scripts/install-cloudflare.sh --token <TOKEN> --account <ID> --zone <ZONE_ID> \
#        --domain <DOMINIO> --sub-ui wxd-ui --sub-minio wxd-minio --sub-presto wxd-presto
#
# Opciones:
#   --token    <TOKEN>      API Token de Cloudflare (Tunnel:Edit + DNS:Edit en la zona)
#   --account  <ID>         Account ID de Cloudflare
#   --zone     <ZONE_ID>    Zone ID (opcional; si se omite el script lo detecta o usa UUID)
#   --domain   <DOMINIO>    Dominio base (ej. midominio.com; solo si se especifica --zone)
#   --sub-ui   <SUBDOMINIO> Subdominio para la Lakehouse UI (default: wxd-ui)
#   --sub-minio <SUBDOMINIO> Subdominio para MinIO Console (default: wxd-minio)
#   --sub-presto <SUBDOMINIO> Subdominio para Presto UI (default: wxd-presto)
#   --tunnel-name <NOMBRE>  Nombre del túnel en Cloudflare (default: wxd-dev)
#   --uninstall             Elimina el servicio, config y el túnel de Cloudflare
#   --yes                   Sin prompts de confirmación
#   --help
#
# Requisitos:
#   - Los servicios systemd wxd-pf@ui, wxd-pf@minio, wxd-pf@presto ya instalados
#     (ver systemd/ en este repo y docs/SETUP.md).
#   - curl, jq, openssl disponibles en la VM.
#   - Token de Cloudflare con permisos: Cloudflare Tunnel:Edit, DNS:Edit (en la zona).
#     Crear en: https://dash.cloudflare.com/profile/api-tokens

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

CF_CONFIG_DIR="/etc/cloudflared"
CF_CONFIG_FILE="$CF_CONFIG_DIR/config.yml"
CF_CREDS_FILE="$CF_CONFIG_DIR/tunnel-creds.json"
CF_API="https://api.cloudflare.com/client/v4"

# ─── Parseo de argumentos ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)       CF_TOKEN="$2";        shift 2 ;;
    --account)     CF_ACCOUNT_ID="$2";   shift 2 ;;
    --zone)        CF_ZONE_ID="$2";      shift 2 ;;
    --domain)      CF_DOMAIN="$2";       shift 2 ;;
    --sub-ui)      SUB_UI="$2";          shift 2 ;;
    --sub-minio)   SUB_MINIO="$2";       shift 2 ;;
    --sub-presto)  SUB_PRESTO="$2";      shift 2 ;;
    --tunnel-name) TUNNEL_NAME="$2";     shift 2 ;;
    --uninstall)   UNINSTALL=true;       shift ;;
    --yes)         AUTO_YES=true;        shift ;;
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

  # Eliminar túnel en CF API
  if [[ -n "$CF_TOKEN" && -f "$CF_CREDS_FILE" ]]; then
    TUNNEL_ID=$(jq -r '.TunnelID // .tunnel_id // ""' "$CF_CREDS_FILE" 2>/dev/null || true)
    ACCOUNT_FROM_CREDS=$(jq -r '.AccountTag // .account_id // ""' "$CF_CREDS_FILE" 2>/dev/null || true)
    [[ -z "$CF_ACCOUNT_ID" ]] && CF_ACCOUNT_ID="$ACCOUNT_FROM_CREDS"
    if [[ -n "$TUNNEL_ID" && -n "$CF_ACCOUNT_ID" ]]; then
      info "Eliminando túnel $TUNNEL_ID de Cloudflare..."
      cf_delete "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}?cascade=true" || warn "No se pudo eliminar el túnel via API."
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

# ─── Detectar zona DNS ───────────────────────────────────────────────────────
USE_DOMAIN=false

if [[ -n "$CF_ZONE_ID" && -n "$CF_DOMAIN" ]]; then
  USE_DOMAIN=true
  info "Usando zona y dominio especificados: $CF_DOMAIN"
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
    echo "    0) Usar URL automática (UUID de cfargotunnel.com — sin dominio propio)"
    echo ""
    read -rp "  Elige una zona [0-${ZONE_COUNT}]: " ZONE_CHOICE

    if [[ "$ZONE_CHOICE" =~ ^[1-9][0-9]*$ && "$ZONE_CHOICE" -le "$ZONE_COUNT" ]]; then
      IDX=$((ZONE_CHOICE-1))
      CF_ZONE_ID="${ZONE_IDS[$IDX]}"
      CF_DOMAIN="${ZONE_NAMES[$IDX]}"
      USE_DOMAIN=true
      ok "Usando zona: $CF_DOMAIN ($CF_ZONE_ID)"

      echo ""
      echo "  Subdominos que se crearán (puedes cambiarlos):"
      read -rp "  Subdominio para Lakehouse UI   [${SUB_UI}]: " INPUT
      [[ -n "$INPUT" ]] && SUB_UI="$INPUT"
      read -rp "  Subdominio para MinIO Console  [${SUB_MINIO}]: " INPUT
      [[ -n "$INPUT" ]] && SUB_MINIO="$INPUT"
      read -rp "  Subdominio para Presto UI      [${SUB_PRESTO}]: " INPUT
      [[ -n "$INPUT" ]] && SUB_PRESTO="$INPUT"
    else
      info "Usando URL automática UUID (*.cfargotunnel.com)."
      USE_DOMAIN=false
    fi
  else
    warn "No se encontraron zonas activas en tu cuenta. Se usará URL automática UUID."
    USE_DOMAIN=false
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

# ─── Crear registros DNS (si aplica) ─────────────────────────────────────────
if $USE_DOMAIN; then
  info "Creando registros DNS CNAME en ${CF_DOMAIN}..."
  for SUBDOMAIN in "$SUB_UI" "$SUB_MINIO" "$SUB_PRESTO"; do
    HOSTNAME="${SUBDOMAIN}.${CF_DOMAIN}"
    # Verificar si ya existe
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
else
  URL_UI="https://${TUNNEL_ID}.cfargotunnel.com"
  URL_MINIO="https://${TUNNEL_ID}.cfargotunnel.com"
  URL_PRESTO="https://${TUNNEL_ID}.cfargotunnel.com"
  warn "Sin dominio: los 3 servicios comparten la misma URL base (${TUNNEL_ID}.cfargotunnel.com)."
  warn "El enrutamiento se hace por path; ver docs/CLOUDFLARE-SETUP.md para detalles."
fi

# ─── Escribir config.yml de cloudflared ──────────────────────────────────────
info "Escribiendo config: ${CF_CONFIG_FILE}..."

if $USE_DOMAIN; then
cat > "$CF_CONFIG_FILE" <<EOF
# Cloudflare Tunnel — watsonx.data Developer Edition
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
else
cat > "$CF_CONFIG_FILE" <<EOF
# Cloudflare Tunnel — watsonx.data Developer Edition (modo UUID, sin dominio)
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
CF_DOMAIN="${CF_DOMAIN:-}"
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
if $USE_DOMAIN; then
  echo "  Lakehouse UI  : ${URL_UI}"
  echo "  MinIO Console : ${URL_MINIO}"
  echo "  Presto UI     : ${URL_PRESTO}"
else
  echo "  URL base      : ${URL_UI}"
  echo ""
  echo "  (Modo UUID: un solo tunnel hacia localhost:9443."
  echo "   Para exponer los 3 servicios con URLs separadas"
  echo "   agrega un dominio a Cloudflare y re-ejecuta el script.)"
fi
echo ""
echo "  Credenciales default: ver docs/CREDENTIALS.md"
echo ""
echo "  Estado del servicio  : systemctl status wxd-cloudflared"
echo "  Logs en tiempo real  : journalctl -u wxd-cloudflared -f"
echo "  Gestión interactiva  : sudo wxd-tunnels-cf.sh"
echo "  Desinstalar          : sudo $0 --uninstall --token <TOKEN>"
echo ""
