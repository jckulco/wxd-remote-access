#!/bin/bash
#
# wxd-tunnels-cf.sh
#
# Gestor interactivo de acceso remoto para watsonx.data Developer Edition
# usando Cloudflare Tunnel (alternativa gratuita a ngrok).
#
# Gestiona:
#   - 3 kubectl port-forward (gestionados por systemd, unit template wxd-pf@.service)
#   - 1 túnel Cloudflare (servicio systemd wxd-cloudflared.service)
#
# Requiere:
#   - Haber ejecutado previamente: sudo ./scripts/install-cloudflare.sh
#   - Los servicios systemd wxd-pf@ui, wxd-pf@minio, wxd-pf@presto instalados.
#   - Correr como root o con sudo.
#
# Uso:
#   sudo wxd-tunnels-cf.sh

set -u

CF_CONFIG_DIR="/etc/cloudflared"
URLS_ENV="${CF_CONFIG_DIR}/wxd-urls.env"
PF_UNITS="wxd-pf@ui wxd-pf@minio wxd-pf@presto"

# Cargar URLs generadas por install-cloudflare.sh
URL_UI="(no configurado)"
URL_MINIO="(no configurado)"
URL_PRESTO="(no configurado)"
USE_DOMAIN="false"

if [[ -f "$URLS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$URLS_ENV"
fi

start_tunnels() {
  echo ">> Levantando port-forwards (systemd)..."
  systemctl restart $PF_UNITS
  sleep 4

  echo ">> Verificando port-forwards..."
  systemctl is-active wxd-pf@ui    | sed 's/^/   UI:     /'
  systemctl is-active wxd-pf@minio | sed 's/^/   MinIO:  /'
  systemctl is-active wxd-pf@presto| sed 's/^/   Presto: /'

  echo ""
  echo ">> Levantando túnel Cloudflare (wxd-cloudflared)..."
  systemctl restart wxd-cloudflared
  sleep 5

  echo ""
  echo "=== Estado final ==="
  CF_STATUS=$(systemctl is-active wxd-cloudflared)
  if [[ "$CF_STATUS" == "active" ]]; then
    echo "   OK  wxd-cloudflared activo"
  else
    echo "   !!  wxd-cloudflared: $CF_STATUS"
    echo "       Revisa: journalctl -u wxd-cloudflared -n 30"
  fi

  echo ""
  echo ">> URLs de acceso:"
  if [[ "$USE_DOMAIN" == "true" ]]; then
    echo "   Lakehouse UI  : ${URL_UI}"
    echo "   MinIO Console : ${URL_MINIO}"
    echo "   Presto UI     : ${URL_PRESTO}"
  else
    echo "   URL base (UUID): ${URL_UI}"
    echo "   (Modo UUID: un solo tunnel. Para URLs por servicio"
    echo "    agrega un dominio y re-ejecuta install-cloudflare.sh)"
  fi
  echo ""
  echo "   Credenciales default: ver docs/CREDENTIALS.md"
}

stop_tunnels() {
  echo ">> Deteniendo túnel Cloudflare..."
  systemctl stop wxd-cloudflared
  sleep 1

  echo ">> Deteniendo port-forwards (systemd)..."
  systemctl stop $PF_UNITS
  sleep 1

  if ss -tlnp | grep -qE ':9443|:9101|:9200'; then
    echo "AVISO: algún puerto sigue ocupado:"
    ss -tlnp | grep -E ':9443|:9101|:9200'
  else
    echo "OK: todo detenido."
  fi
}

status_tunnels() {
  echo "=== Servicios systemd (port-forwards) ==="
  systemctl is-active wxd-pf@ui wxd-pf@minio wxd-pf@presto
  echo ""
  echo "=== Servicio Cloudflare Tunnel ==="
  systemctl status wxd-cloudflared --no-pager -l | head -20
  echo ""
  echo "=== Puertos escuchando ==="
  ss -tlnp | grep -E ':9443|:9101|:9200' || echo "   Ninguno activo."
  echo ""
  echo "=== URLs (si activos) ==="
  if [[ "$USE_DOMAIN" == "true" ]]; then
    echo "   Lakehouse UI  : ${URL_UI}"
    echo "   MinIO Console : ${URL_MINIO}"
    echo "   Presto UI     : ${URL_PRESTO}"
  else
    echo "   URL base (UUID): ${URL_UI}"
  fi
}

logs_tunnel() {
  echo ">> Logs del túnel Cloudflare (Ctrl+C para salir):"
  journalctl -u wxd-cloudflared -f
}

echo "════════════════════════════════════════════════════════"
echo "  watsonx.data — gestor de túneles Cloudflare"
echo "════════════════════════════════════════════════════════"
echo "1) Levantar túneles"
echo "2) Detener túneles"
echo "3) Ver estado"
echo "4) Reiniciar (detener + levantar)"
echo "5) Ver logs en tiempo real"
echo "0) Salir"
echo ""
read -rp "Elige una opción: " opt

case "$opt" in
  1) start_tunnels ;;
  2) stop_tunnels ;;
  3) status_tunnels ;;
  4) stop_tunnels; echo ""; start_tunnels ;;
  5) logs_tunnel ;;
  0) echo "Saliendo."; exit 0 ;;
  *) echo "Opción inválida." ;;
esac
