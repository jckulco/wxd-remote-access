# Guía de instalación y exposición remota

## 1. Instalar watsonx.data Developer Edition

1. Coloca el instalador de IBM en `installer/watsonx.data-developer-edition-installer.tar`
   (ver `installer/README.md`).
2. Corre el script de setup de tu pipeline (por ejemplo `setup-watsonx-data.sh`), que:
   - Verifica prerrequisitos (docker, kubectl).
   - Extrae el instalador.
   - Crea un cluster KIND (`kind-wxd`).
   - Despliega el Helm chart `wxd` en el namespace `wxd`.
   - Espera a que todos los pods queden `Running`/`Completed`.
3. Al finalizar, verifica:
   ```bash
   kubectl -n wxd get pods
   kubectl -n wxd get svc
   ```

## 2. Instalar dependencias de acceso remoto

```bash
sudo ./scripts/install-deps.sh
```

Instala `ngrok`. Luego:

```bash
ngrok config add-authtoken <TU_TOKEN>
```

(Consigue tu token en https://dashboard.ngrok.com/get-started/your-authtoken — requiere cuenta,
el plan gratuito no permite 3 dominios fijos simultáneos; se usó un plan Hobby de pago.)

## 3. Reservar dominios fijos en ngrok

En https://dashboard.ngrok.com/domains, crea 3 **Agent Endpoints** con dominio fijo
(uno por servicio: UI, MinIO, Presto). ngrok asigna un subdominio del tipo
`algo-aleatorio.ngrok.app` a cada uno (el plan Hobby no permite elegir el nombre).

Anota los 3 dominios y actualiza las variables al inicio de `scripts/wxd-tunnels.sh`:

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

> El unit template usa `Environment=KUBECONFIG=/root/.kube/config` — ajusta esa ruta si tu
> kubeconfig vive en otro lugar (verifica con `kubectl config view --minify -o jsonpath='{.clusters[0].name}'`
> o revisando `$KUBECONFIG` en tu shell).

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
   Si los contenedores de KIND no arrancan solos, puede requerir recrear el cluster
   (fuera del alcance de este kit — revisa la documentación de tu instalador de watsonx.data).

2. Una vez el cluster esté sano, simplemente corre de nuevo:
   ```bash
   sudo /usr/local/bin/wxd-tunnels.sh
   ```
   y elige **1) Levantar túneles**. Los servicios systemd ya quedaron habilitados
   (`systemctl enable`), así que sobreviven al reinicio por sí solos; ngrok se relanza
   manualmente vía el script (no corre como servicio systemd en esta versión).
