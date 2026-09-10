# Credenciales

Este documento indica **dónde encontrar** las credenciales de cada servicio, sin incluir
valores reales — no se deben commitear contraseñas ni tokens a este repositorio.

## Lakehouse UI / Presto UI

- Usuario: `ibmlhadmin`
- Password: la default documentada por IBM para watsonx.data Developer Edition
  (ver documentación oficial de IBM: "Installing watsonx.data developer version").
- El hash de la contraseña vive en el secret `lhauth-secret` (`users.htpasswd`),
  pero **no es reversible** — la contraseña en texto plano es la default publicada por IBM,
  no algo que se pueda extraer del cluster.

```bash
kubectl -n wxd get secret lhauth-secret -o jsonpath='{.data}' \
  | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"
```

⚠️ **Recomendación**: cambia esta contraseña desde la propia UI (ícono de usuario →
gestión de cuenta) si vas a dejar el entorno expuesto por más de una sesión de prueba.

## MinIO Console

- Las credenciales viven en el secret `ibm-lh-config-secret`, claves `LH_S3_ACCESS_KEY`
  y `LH_S3_SECRET_KEY`:

```bash
kubectl -n wxd get secret ibm-lh-config-secret -o jsonpath='{.data}' \
  | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"
```

⚠️ En esta instalación de referencia, el valor observado fue literalmente el string
`dummyvalue` para ambas claves — no asumas que es siempre así; verifica en tu propio cluster.

## ngrok

El authtoken de tu cuenta de ngrok se guarda localmente en `~/.config/ngrok/ngrok.yml`
al correr `ngrok config add-authtoken <token>`. **Nunca subas ese archivo ni el token a Git.**
Ya está cubierto por `.gitignore` en la raíz del repo.
