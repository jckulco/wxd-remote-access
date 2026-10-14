# Arquitectura

## Instalación de watsonx.data (capa base)

`scripts/setup-watsonx-data.sh` envuelve el `installer.sh` oficial de IBM, que construye esta base:

```
VM RHEL
 └─ Docker
     └─ contenedor kind-wxd-control-plane   (cluster KIND de un solo nodo, "kind-wxd")
         └─ namespace wxd                    (helm release "wxd", ~20 pods)
```

`installer.sh` además deja 3 `kubectl port-forward` (nohup) para acceso local directo:
UI `6443→443`, MinIO `9001→9001`, MDS Thrift `8381→8381`. Estos **no** son persistentes.
La capa de abajo (systemd + túnel) es independiente y usa otros puertos.

## Componentes del acceso remoto

El kit soporta dos backends de túnel intercambiables. Ambos comparten la misma capa
de `kubectl port-forward` gestionada por systemd.

### Opción A — Cloudflare Tunnel (recomendada, gratuita)

```
Internet
   │
   │  https://wxd-ui.tudominio.com       ← tu propio dominio
   │  https://wxd-minio.tudominio.com       (o UUID *.cfargotunnel.com si no tienes dominio)
   │  https://wxd-presto.tudominio.com
   ▼
┌─────────────────────────────┐
│   Cloudflare Edge            │   TLS terminado en el edge de CF
│   (red global de CF)         │
└──────────────┬───────────────┘
               │ HTTPS outbound desde la VM
               │ (puerto 443 / QUIC — funciona en redes corporativas)
               ▼
┌─────────────────────────────┐
│  wxd-cloudflared.service     │   1 proceso cloudflared,
│  (systemd, Restart=always)   │   3 ingress rules en config.yml
└──────────────┬───────────────┘
               │ localhost:9443 / 9101 / 9200
               ▼
┌─────────────────────────────┐
│  kubectl port-forward         │   gestionado por systemd,
│  (wxd-pf@ui / minio / presto) │   Restart=always
└──────────────┬───────────────┘
               │
               ▼
┌─────────────────────────────┐
│   Cluster KIND (kind-wxd)     │
│   Namespace: wxd               │
│                                 │
│   lhconsole-ui-svc   :443       │  → Lakehouse UI
│   ibm-lh-minio-svc   :9001      │  → MinIO Console
│   ibm-lh-presto-svc  :8443      │  → Presto UI
└─────────────────────────────┘
```

### Opción B — ngrok (requiere plan pago para dominios fijos)

```
Internet
   │
   │  https://wx-data-dev.ngrok.app
   │  https://minio-wxdev.ngrok.app
   │  https://prestowx-ui-dev.ngrok.app
   ▼
┌─────────────────────────────┐
│      ngrok (agente)          │   3 procesos, cada uno con
│  corre en la VM, 3 túneles   │   dominio fijo reservado (plan pago)
└──────────────┬────────────────┘
               │ localhost:9443 / 9101 / 9200
               ▼
┌─────────────────────────────┐
│  kubectl port-forward         │   gestionado por systemd,
│  (wxd-pf@ui / minio / presto) │   Restart=always
└──────────────┬────────────────┘
               │
               ▼
┌─────────────────────────────┐
│   Cluster KIND (kind-wxd)     │
│   Namespace: wxd               │
│                                 │
│   lhconsole-ui-svc   :443       │  → Lakehouse UI
│   ibm-lh-minio-svc   :9001      │  → MinIO Console
│   ibm-lh-presto-svc  :8443      │  → Presto UI
└─────────────────────────────┘
```

## Por qué esta combinación

- **kubectl port-forward** es la forma más simple de sacar un Service de ClusterIP
  (solo accesible dentro del cluster) a un puerto del host de la VM. Es inherentemente
  inestable bajo carga (se cae con errores de tipo "broken pipe" / "lost connection to pod"),
  por eso se gestiona con **systemd** y `Restart=always` en vez de un proceso manual con `nohup`.

- **Cloudflare Tunnel** expone el puerto del host a internet con TLS terminado por Cloudflare,
  sin necesidad de abrir puertos entrantes en el firewall de la VM, sin costo, y sin rate-limit
  agresivo en reconexiones. Un solo proceso (`cloudflared`) gestiona los 3 servicios y corre
  como servicio systemd con `Restart=always`, sobreviviendo a reinicios de la VM de forma
  completamente automática.

## Comparación de backends de túnel

| Aspecto | Cloudflare Tunnel | ngrok |
|---|---|---|
| Costo | **Gratis** | Plan pago para dominios fijos |
| URLs permanentes | ✅ Tu dominio o UUID fijo | Requiere plan Hobby pago |
| Procesos de túnel | **1 servicio systemd** | 3 procesos independientes |
| Supervivencia a reinicios | **Automática** (systemd) | Manual (no es servicio systemd) |
| Rate-limit en reconexión | ❌ No (tunnel nombrado) | ❌ No (plan pago) |
| Puertos bloqueados en red corp. | ❌ Solo usa 443 saliente | ❌ Solo usa 443 saliente |
| Dominio propio | Opcional (UUID sin dominio) | No disponible en plan free |

## Alternativas descartadas y por qué

| Opción | Problema encontrado |
|---|---|
| `bore` (relay público `bore.pub`) | Requiere puertos altos arbitrarios; muchas redes corporativas solo permiten salida en 80/443, bloqueando la conexión del cliente. |
| Cloudflare Quick Tunnel (sin cuenta) | Rate-limit agresivo (HTTP 429 / error 1015) al reiniciar el túnel con frecuencia (p. ej. bajo `Restart=always`). |
| Tailscale Funnel | Viable, pero la URL incluye el tailnet name no personalizable en el plan free. Requiere instalar Tailscale en cada cliente que quiera acceder. |
| **Cloudflare Tunnel nombrado (cuenta gratuita)** | ✅ Sin problemas de puertos bloqueados, sin rate-limit, URLs estables, completamente gratuito. **Backend recomendado.** |
| **ngrok con dominios fijos (plan Hobby pago)** | ✅ Funciona, pero requiere pago. Se mantiene como opción alternativa. |
