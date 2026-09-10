#!/bin/bash
#
# wxd-tunnels.sh
#
# Gestor interactivo de acceso remoto para watsonx.data Developer Edition.
# Levanta / detiene / reporta el estado de:
#   - 3 kubectl port-forward (gestionados por systemd, unit template wxd-pf@.service)
#   - 3 túneles ngrok con dominios fijos reservados en la cuenta de ngrok
#
# Requiere:
#   - Los servicios systemd wxd-pf@ui, wxd-pf@minio, wxd-pf@presto ya instalados
#     (ver systemd/ en este repo y docs/SETUP.md).
#   - ngrok instalado y autenticado (ngrok config add-authtoken ...).
#   - 3 dominios fijos reservados en el dashboard de ngrok, referenciados abajo.
#   - Correr como root o con sudo (controla systemctl).
#
# Uso:
#   sudo ./wxd-tunnels.sh

set -u

LOG_NGROK=~/ngrok-logs
mkdir -p "$LOG_NGROK"

PF_UNITS="wxd-pf@ui wxd-pf@minio wxd-pf@presto"

# --- Dominios fijos ngrok (ajusta a los tuyos si reservas otros) ---
DOMAIN_UI="wx-data-dev.ngrok.app"
DOMAIN_MINIO="minio-wxdev.ngrok.app"
DOMAIN_PRESTO="prestowx-ui-dev.ngrok.app"

start_tunnels() {
  echo ">> Deteniendo ngrok previo (si hay)..."
  pkill -9 -f "ngrok http" 2>/dev/null
  sleep 1

  echo ">> Levantando port-forwards (systemd)..."
  systemctl restart $PF_UNITS
  sleep 4

  echo ">> Verificando port-forwards..."
  systemctl is-active wxd-pf@ui    | sed 's/^/   UI:     /'
  systemctl is-active wxd-pf@minio | sed 's/^/   MinIO:  /'
  systemctl is-active wxd-pf@presto| sed 's/^/   Presto: /'

  echo ""
  echo ">> Levantando tuneles ngrok con dominios fijos..."
  nohup ngrok http https://localhost:9443 --url="https://${DOMAIN_UI}" --log=stdout > "$LOG_NGROK/ui.log" 2>&1 &
  sleep 3
  nohup ngrok http http://localhost:9101 --url="https://${DOMAIN_MINIO}" --log=stdout > "$LOG_NGROK/minio.log" 2>&1 &
  sleep 3
  nohup ngrok http https://localhost:9200 --url="https://${DOMAIN_PRESTO}" --log=stdout > "$LOG_NGROK/presto.log" 2>&1 &
  sleep 5

  echo ""
  echo "=== Estado final ==="
  for s in "ui:$DOMAIN_UI" "minio:$DOMAIN_MINIO" "presto:$DOMAIN_PRESTO"; do
    name="${s%%:*}"; domain="${s#*:}"
    if grep -qa "started tunnel" "$LOG_NGROK/$name.log" 2>/dev/null; then
      echo "   OK  $name -> https://$domain"
    else
      echo "   ??  $name -> revisa $LOG_NGROK/$name.log"
    fi
  done

  echo ""
  echo ">> URLs de acceso:"
  echo "   Lakehouse UI : https://${DOMAIN_UI}"
  echo "   MinIO Console: https://${DOMAIN_MINIO}"
  echo "   Presto UI    : https://${DOMAIN_PRESTO}"
  echo ""
  echo "   Credenciales default: ver docs/CREDENTIALS.md"
}

stop_tunnels() {
  echo ">> Deteniendo tuneles ngrok..."
  pkill -9 -f "ngrok http" 2>/dev/null
  sleep 1

  echo ">> Deteniendo port-forwards (systemd)..."
  systemctl stop $PF_UNITS
  sleep 1

  if ss -tlnp | grep -qE ':9443|:9101|:9200'; then
    echo "AVISO: algun puerto sigue ocupado:"
    ss -tlnp | grep -E ':9443|:9101|:9200'
  else
    echo "OK: todo detenido."
  fi
}

status_tunnels() {
  echo "=== Servicios systemd (port-forwards) ==="
  systemctl is-active wxd-pf@ui wxd-pf@minio wxd-pf@presto
  echo ""
  echo "=== Puertos escuchando ==="
  ss -tlnp | grep -E ':9443|:9101|:9200' || echo "   Ninguno activo."
  echo ""
  echo "=== Procesos ngrok ==="
  pgrep -af "ngrok http" || echo "   Ninguno activo."
  echo ""
  echo "=== URLs (si activos) ==="
  echo "   https://${DOMAIN_UI}"
  echo "   https://${DOMAIN_MINIO}"
  echo "   https://${DOMAIN_PRESTO}"
}

echo "========================================"
echo " watsonx.data - gestor de tuneles ngrok"
echo "========================================"
echo "1) Levantar tuneles"
echo "2) Detener tuneles"
echo "3) Ver estado"
echo "4) Reiniciar (detener + levantar)"
echo "0) Salir"
echo ""
read -p "Elige una opcion: " opt

case "$opt" in
  1) start_tunnels ;;
  2) stop_tunnels ;;
  3) status_tunnels ;;
  4) stop_tunnels; echo ""; start_tunnels ;;
  0) echo "Saliendo."; exit 0 ;;
  *) echo "Opcion invalida." ;;
esac
