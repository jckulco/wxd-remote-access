#!/bin/bash
#
# install-deps.sh
#
# Instala las dependencias del kit de acceso remoto en una VM RHEL/CentOS/Rocky/Alma:
# solo ngrok. docker, kubectl, helm y kind los instala el installer.sh de IBM
# (ver scripts/setup-watsonx-data.sh), por lo que se verifica que estén presentes.
#
# Uso:
#   sudo ./install-deps.sh

set -e

echo ">> Verificando prerrequisitos (instalados por setup-watsonx-data.sh)..."
for c in kubectl docker; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "   AVISO: '$c' no está instalado. Corre primero: sudo ./scripts/setup-watsonx-data.sh"
  fi
done

case "$(uname -m)" in
  x86_64)  NGROK_ARCH="amd64" ;;
  aarch64) NGROK_ARCH="arm64" ;;
  *) echo "Arquitectura no soportada: $(uname -m)"; exit 1 ;;
esac

echo ">> Instalando ngrok..."
if ! command -v ngrok >/dev/null 2>&1; then
  curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${NGROK_ARCH}.tgz" -o /tmp/ngrok.tgz
  tar -xzf /tmp/ngrok.tgz -C /tmp
  mv /tmp/ngrok /usr/local/bin/ngrok
  chmod +x /usr/local/bin/ngrok
  rm -f /tmp/ngrok.tgz
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
echo "        ver docs/SETUP.md, sección '4. Instalar los servicios systemd de port-forward'"
