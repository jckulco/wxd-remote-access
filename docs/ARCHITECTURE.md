# Arquitectura

## Componentes

```
Internet
   │
   │  https://wx-data-dev.ngrok.app
   │  https://minio-wxdev.ngrok.app
   │  https://prestowx-ui-dev.ngrok.app
   ▼
┌─────────────────────────────┐
│      ngrok (agente)          │   3 procesos, cada uno con
│  corre en la VM, 3 túneles   │   dominio fijo reservado
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

- **ngrok** expone el puerto del host a internet con TLS terminado por ngrok, sin necesidad
  de abrir puertos entrantes en el firewall de la VM ni depender de que la red del cliente
  permita puertos no estándar (ver docs/SETUP.md, sección "Por qué no bore/cloudflare Quick Tunnel").

## Alternativas descartadas y por qué

| Opción | Problema encontrado |
|---|---|
| `bore` (relay público `bore.pub`) | Requiere puertos altos arbitrarios; muchas redes corporativas solo permiten salida en 80/443, bloqueando la conexión del cliente. |
| Cloudflare Tunnel — Quick Tunnel (sin cuenta) | Rate-limit agresivo (HTTP 429 / error 1015) al reiniciar el túnel con frecuencia (p. ej. bajo `Restart=always`). |
| Cloudflare Tunnel — túnel nombrado | Requiere un dominio propio agregado a Cloudflare (cambio de nameservers), fricción innecesaria para un entorno de pruebas. |
| **ngrok con dominios fijos reservados (plan pago)** | ✅ Sin problemas de puertos bloqueados (usa 443 estándar), sin rate-limit agresivo, URLs estables entre reinicios. |
