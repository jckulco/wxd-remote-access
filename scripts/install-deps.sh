#!/bin/bash
#
# install-deps.sh
#
# Instala las dependencias necesarias para el kit de acceso remoto en una VM
# RHEL/CentOS/Rocky/Alma: kubectl, ngrok.
# Docker/kind/helm se asumen ya instalados por el instalador de watsonx.data.
#
# Uso:
#   sudo ./install-deps.sh

set -e

echo ">> Instalando ngrok..."
if ! command -v ngrok >/dev/null 2>&1; then
  curl -fsSL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz -o /tmp/ngrok.tgz
  tar -xzf /tmp/ngrok.tgz -C /tmp
  mv /tmp/ngrok /usr/local/bin/ngrok
  chmod +x /usr/local/bin/ngrok
  echo "   ngrok instalado: $(ngrok version)"
else
  echo "   ngrok ya está instalado: $(ngrok version)"
fi

echo ""
echo ">> Siguiente paso manual:"
echo "   1. Autentica ngrok con tu authtoken:"
echo "        ngrok config add-authtoken <TU_TOKEN>"
echo "      (obtén tu token en https://dashboard.ngrok.com/get-started/your-authtoken)"
echo ""
echo "   2. Reserva 3 dominios fijos en https://dashboard.ngrok.com/domains"
echo "      y actualiza las variables DOMAIN_UI / DOMAIN_MINIO / DOMAIN_PRESTO"
echo "      en scripts/wxd-tunnels.sh con los nombres que te asigne ngrok."
echo ""
echo "   3. Instala los servicios systemd de port-forward:"
echo "        ver docs/SETUP.md, sección 'Servicios systemd'"
