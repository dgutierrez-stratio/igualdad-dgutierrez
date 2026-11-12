# 2-apps-layer-kit: apps-layer-automation con S3 en AWS, relanzable (fase 3)

Kit para instalar el caso de uso (tenant `keos` de gobierno + tenant `dev` con virtualizer, rocket, discovery,
intelligence, genai, etc.) sobre un clúster EKS legacy usando **S3 en vez de HDFS**, y para **repetir todo el proceso
en otro clúster/cuenta cambiando solo variables**. Reutiliza tal cual la imagen
`qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-M2` (tag inmutable de la rama `branch-15.1-0.1`; el `SNAPSHOT` es mutable); no parchea `apps/*`.

Es la **fase 3** del workspace `/stratio/e/igualdad/` (índice en `../README.md`): la fase 1-2 (VPC, cloud-provisioner,
`keos install`) está en `../1-aws-cluster/` y en la skill `legacy-eks-cluster`. **La raíz del workspace (`..`) es el workspace
de keos-installer** y se monta como `/workspace` en el contenedor de apps-layer: no muevas allí `keos.yaml`, `secrets.yml`,
`override_vars/`, `pki/`, `requirements/`, `logs/`, `.kube/`, `.config/`.

El análisis que lo justifica está en `docs/INFORME.md` (informe del proyecto) y `docs/plan-caso-uso-s3.md` (plan HDFS->S3
por app, riesgos y lo no verificado); ambos son análisis previos a la reorganización (sus rutas operativas ya están actualizadas).

## Estructura

```
2-apps-layer-kit/
  README.md  kit.env.example
  templates/   root.yaml.tpl  tenant.yaml.tpl  env.tpl  requisites-s3.cfn.yaml  (+ bucket de backups opcional)  sizes-custom.env  (overlay de recursos de ENVIRONMENT_SIZE=CUSTOM)
  scripts/     lib.sh  render-apps-layer.sh  s3-requisites.sh  import-llm-token.sh  fetch-universe.sh  launch-apps-layer.sh  check-apps-layer.sh  backups-env.sh  (opcional)
  docs/        INFORME.md  plan-caso-uso-s3.md  (+ igualdad-dgutierrez.yaml y dot-env de la PR 220, solo referencia)
  tests/       run-offline-tests.sh  mock/bin/{aws,kubectl,docker,getent,curl,gh}  fixtures/ (base de la plantilla requisites)
```

## Requisitos

`bash`, `jq`, `yq` (kislyuk o mikefarah v4), `envsubst`, `awk`, `aws` (v1 o v2; los scripts prefieren v2 y fijan
`AWS_PAGER=""`), `kubectl` y `docker` (solo para `launch`/`check` de clúster), `curl`, `unzip` y `sha256sum` (descarga del zip del universo) y **`gh` autenticado con acceso a `Stratio/kubernetes-universe`** (descarga de `universe-images.lst`; `gh auth login`). Hace falta VPN/acceso a `qa.int.stratio.com` (imagen y zip). Perfil AWS con permisos de CloudFormation,
IAM, S3 y Secrets Manager (por defecto `cloud-provisioner`, `KIT_AWS_PROFILE`). Las variables del clúster se leen de
`../cluster.env` (raíz del workspace; el kit nunca lo modifica). El clúster debe tener ya keos instalado (tenant `keos`).

## Variables

Prioridad: **variables exportadas en el shell > `kit.env` > `../cluster.env` > defaults**. Plantilla en `kit.env.example` (sin secretos).

| Variable | Default | Notas |
|---|---|---|
| `CLUSTER_NAME`, `AWS_ACCOUNT_ID`, `AWS_REGION`, `EXTERNAL_DOMAIN` | de `cluster.env` | obligatorias; la cuenta se verifica con `sts` antes de tocar AWS |
| `TENANT_NAME` | `dev` | tenant específico (no puede ser `keos`) |
| `APPS_LAYER_DIR` | `${TMPDIR:-/tmp}/apps-layer-${CLUSTER_NAME}` | directorio de **ejecución efímero** montado en `/apps-layer` (700; ver abajo) |
| `KEOS_WORKSPACE_DIR` | `<padre del kit>` (raíz del workspace) | montado en `/workspace` |
| `APPS_LAYER_IMAGE`, `APPS_LAYER_IMAGE_DIGEST` | imagen `15.1-0.1.0-M2` (inmutable), vacío | con `sha256:...` (64 hex) se fija `repo:tag@sha256:...`; digest local de M2 (pull del 2026-11-12): `sha256:95ea159b7f0e206d6dc5662c3b861dbead468902cf4d4ab0123f9aea34c14ea8` |
| `S3_BUCKET_NAME` | `${CLUSTER_NAME}-internal-${AWS_ACCOUNT_ID}` | global en AWS |
| `S3_USER_NAME` | `${CLUSTER_NAME}-s3` | usuario IAM y secreto de Secrets Manager |
| `STACK_NAME` | `${CLUSTER_NAME}-requisites` | stack CloudFormation mínimo propio |
| `S3_INIT_PATH` | `/${S3_BUCKET_NAME}` | `INIT_PATH` de `connector-s3` en el YAML del tenant: no vacío, empieza por `/` y **no puede ser `/` solo** (el driver S3 lo rechaza con `UnsupportedRootInitPath`; vacío, sin `/` o `/` abortan). Valores válidos: `/<bucket>` o `/<bucket>/<prefijo>`. Necesario por la errata `INTI_PATH` de `vars.env` (ver abajo) |
| `ENABLE_BACKUPS_BUCKET` | `false` | `true`/`false`. Bucket de backups **opcional** para migrar a GitOps (sección "Bucket de backups opcional"); `false` = el stack no cambia en nada |
| `BACKUPS_BUCKET_NAME` | `${CLUSTER_NAME}-backups-${AWS_ACCOUNT_ID}` | solo con backups habilitados; global en AWS (la referencia `aws-clusters-automation` usa `${CLUSTER_NAME}-backups`, que sin sufijo de cuenta puede chocar con otra cuenta) |
| `BACKUPS_USER_NAME` | `${CLUSTER_NAME}-backups` | usuario IAM y secreto de backups; nunca `cloud-provisioner`, `igualdad` ni el perfil del kit |
| `ENVIRONMENT_SIZE` | `S` | `S`, `PIT` o `CUSTOM` (otro valor aborta). `CUSTOM` = overlay propio del kit, ver "ENVIRONMENT_SIZE=CUSTOM" |
| `CUSTOM_SIZES_FILE` | `templates/sizes-custom.env` | solo con `CUSTOM`: ruta **absoluta** de un overlay de recursos que **sustituye** al del kit (cópialo y edítalo; con `S`/`PIT` no se lee) |
| `VELERO_BUCKET`, `VELERO_ROLE`, `SC_POSTGRES` | `${CLUSTER_NAME}-velero-${AWS_ACCOUNT_ID}`, `${CLUSTER_NAME}-velero`, vacío | solo los lee `backups-env.sh` (opcional, `enviroment-ready --backups`): bucket y **nombre** del rol IRSA de Velero (los de `cluster.env`) y StorageClass opcional de los backups de postgres |
| `VIRTUALIZER_CREATE_LOADBALANCER` | `false` | `true` crearía un Service LoadBalancer (ELB) en AWS |
| `USE_TENANT_HOSTS` | `false` | ver abajo |
| `ENABLE_GENAI` | `true` | `true`/`false`; `true` exige `LLM_TOKEN` |
| `KEOS_PROFILE` | `full` | `full` (stack se-* + governance como `eosdev.yaml`) o `minimal` (PR 220, `GOVERNANCE_UI_ENABLE_SEARCHER: "false"`) |
| `LLM_PROVIDER`, `LLM_MODEL` | vacío | opcionales, no secretos; si se definen se escriben en el env del tenant (los defaults de la app son `openai`/`gpt-5.4-mini`) |
| `KUBECONFIG_SRC` | `$KEOS_WORKSPACE_DIR/1-aws-cluster/estado/kubeconfig-${CLUSTER_NAME}` | origen del `kube-config` (si falta, se genera con `aws eks update-kubeconfig`) |
| `UNIVERSE_VERSION` | `15.1.0` | versión del universo: nombre del zip y del `.lst` y, por defecto, rama del `.lst` |
| `UNIVERSE_BRANCH` | el **tag** `UNIVERSE_VERSION` (`15.1.0`); si la versión no es `X.Y.Z`, `branch-<major>.<minor>` | tag/rama de `Stratio/kubernetes-universe` de la que se baja `universe-images.lst`. Se ancla al tag porque `branch-15.1` ya es 15.1.1 (connectors-loader 2.2.5, rocket 4.1.2) y mezclaría imágenes posteriores con los descriptores 15.1.0; obligatoria si la versión no tiene forma `X.Y...` |
| `UNIVERSE_ZIP_URL` | `http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/kubernetes-universe-descriptors-${UNIVERSE_VERSION}.zip` | override de la URL del zip |
| `KIT_AWS_PROFILE`, `KEOS_INSTALLER_EXTRA_ARGS`, `NLB_IP`, `NLB_NAMESPACE`, `NLB_SERVICE` | ver `kit.env.example` | |

## Bucket de backups opcional

> No confundir con los backups de la plataforma de `enviroment-ready` (sección "Backups de la plataforma con `enviroment-ready`", más abajo): aquello usa el bucket y el rol IRSA de **Velero**; este bucket con usuario IAM de claves estáticas es
> solo para la migración a GitOps.

**Para qué sirve.** El consumidor GitOps (keos-fleet) necesita un bucket S3 de backups de la plataforma Stratio con un usuario IAM de claves estáticas. En
igualdad no existe; al migrar el clúster legacy a GitOps hay que crearlo. Es **opcional y está desactivado por defecto** (`ENABLE_BACKUPS_BUCKET=false`): sin
activarlo, el stack `${STACK_NAME}`, los parámetros de `deploy` (salvo `EnableBackupsBucket=false`) y las salidas son los de siempre. apps-layer-automation **no** usa
este bucket ni sus claves.

**Cómo activarlo** (sobre el stack ya creado, que tampoco se recrea):

```bash
# kit.env:  export ENABLE_BACKUPS_BUCKET=true      (opcional: BACKUPS_BUCKET_NAME, BACKUPS_USER_NAME)
scripts/s3-requisites.sh plan          # solo lectura: estado de bucket/usuario/secreto de backups; aborta si hay un homonimo que no es del stack
scripts/s3-requisites.sh apply         # ACTUALIZACION del mismo stack: solo AÑADE bucket, usuario IAM, access key y secreto (confirmacion tecleando el cluster)
scripts/s3-requisites.sh env           # ademas escribe BACKUPS_S3_BUCKET_{ACCESS_KEY,SECRET_KEY,NAME,REGION} en ${APPS_LAYER_DIR}/.env (600, sin imprimir valores)
scripts/s3-requisites.sh backups-info  # solo lectura y SIN secretos: bucket, region, usuario, ARN del secreto y el comando get-secret-value (no se ejecuta)
```

- **Solo añade.** Con `EnableBackupsBucket=true` los 4 recursos nuevos (`BackupsS3Bucket`, `BackupsS3IAMUser`, `BackupsS3IAMUserAccessKey`, `BackupsS3Secret`, todos con
  `Condition: CreateBackups`) se suman al stack; `InternalS3Bucket` y los demás no cambian (hay pruebas que lo comparan con la plantilla anterior). `apply` aborta si
  `ENABLE_BACKUPS_BUCKET=false` pero el stack ya tiene backups (quitarlos borraría usuario, clave y secreto) o si los nombres difieren de los del stack (sería un reemplazo).
- **Coste y retención.** Bucket versionado, cifrado AES256, sin acceso público y con `DeletionPolicy`/`UpdateReplacePolicy: Retain`: borrar el stack **no** lo borra y
  las versiones se acumulan (coste de almacenamiento) hasta que se gestionen con una política de ciclo de vida propia. El secreto guarda la access key por diseño
  (keos-fleet necesita user/pass), igual que el secreto interno.
- **Borrado.** `s3-requisites.sh delete` **conserva** el bucket de backups (solo informa); si el stack lo tenía, el usuario IAM, su access key y su secreto sí se van con el stack.
  Para borrarlo también: `s3-requisites.sh delete --delete-backups` (vacía versiones y delete markers y borra el bucket; irreversible), con una confirmación extra tecleando el
  nombre del bucket de backups, además de las de siempre (clúster y cuenta). Solo si es del clúster (output del stack o etiqueta `cluster`).
- **Consumirlo en GitOps (keos-fleet).** `backups.s3BucketName` = `BACKUPS_S3_BUCKET_NAME`, `backups.s3BucketRegion` = `BACKUPS_S3_BUCKET_REGION` y `BACKUPS_S3_BUNDLE` = base64 de
  `passwords: [{name: backup, data: {user: <ACCESS_KEY>, pass: <SECRET_KEY>}}]` (formato de `configure-gitops.sh` de aws-clusters-automation). Sin imprimir las claves:

  ```bash
  source "${APPS_LAYER_DIR}/.env"      # BACKUPS_S3_BUCKET_ACCESS_KEY / _SECRET_KEY / _NAME / _REGION
  export BACKUPS_S3_BUNDLE="$(printf 'passwords:\n  - name: backup\n    data:\n      user: %s\n      pass: %s\n' "$BACKUPS_S3_BUCKET_ACCESS_KEY" "$BACKUPS_S3_BUCKET_SECRET_KEY" | base64 -w0)"
  ```

## Directorio de ejecución efímero (`APPS_LAYER_DIR`)

> **Gotcha real:** una `APPS_LAYER_DIR` **exportada en tu shell** por una sesión anterior pisa el defecto (prioridad: entorno > `kit.env` > `cluster.env`) y
> `s3-requisites.sh env` escribió el `.env` en la ruta vieja sin que se notara. Antes de empezar: `unset APPS_LAYER_DIR`. Desde ahora `lib.sh` avisa (`AVISO: APPS_LAYER_DIR
> efectivo = ... distinto del esperado ...; viene de <entorno|kit.env/cluster.env>`) cada vez que la ruta efectiva no es `${TMPDIR:-/tmp}/apps-layer-<cluster>`; el aviso no aborta.

Los ficheros que consume el contenedor (YAML raíz y de tenant, `.env`, `kube-config`, `aws/`) **contienen secretos** (token LLM,
claves S3, credenciales AWS) y por eso ya no viven en el repo sino en `/tmp/apps-layer-${CLUSTER_NAME}` (en `$TMPDIR` si está definido):

- Se crea con `umask 077` + `chmod 700` y los scripts que escriben en él (`render-apps-layer.sh`, `import-llm-token.sh`,
  `s3-requisites.sh env`) **abortan** si ya existe y no es del usuario actual, es un enlace simbólico o es accesible por grupo/otros
  (`chmod 700 <dir>`); `launch-apps-layer.sh` y `check-apps-layer.sh` también lo comprueban.
- **`/tmp` puede vaciarse al reiniciar** (o por limpiezas periódicas): no es un sitio donde guardar nada irrepetible. Todo se regenera:

```bash
cd /stratio/e/igualdad/2-apps-layer-kit
scripts/render-apps-layer.sh        # YAML raíz + tenant, .env base, kube-config y aws/ (solo perfil cloud-provisioner)
scripts/s3-requisites.sh env        # S3_BUCKET_ACCESS_KEY/SECRET_KEY + AWS_REGION al .env (lee el secreto de Secrets Manager; stack ya creado)
scripts/import-llm-token.sh <yaml>  # LLM_TOKEN al .env (hace falta el YAML del lab o `export LLM_TOKEN=...`); luego repetir render para inyectarlo en el YAML del tenant
```

- `kube-config`: lo crea `render-apps-layer.sh` si falta (copia de `$KUBECONFIG_SRC` o, si no existe, `aws eks update-kubeconfig --name $CLUSTER_NAME` con el perfil del kit; 600).
- `aws/`: `render-apps-layer.sh` crea `$APPS_LAYER_DIR/aws/{credentials,config}` (700/600) con **solo** el perfil `cloud-provisioner`
  (`KIT_AWS_PROFILE`): las claves se leen de `~/.aws` con `aws configure get`, no se imprimen y no pasan por argv; `config` solo lleva la región.
  Idempotente (sin cambios si coincide). Si el perfil no tiene claves estáticas avisa y no crea nada. Con `--no-aws-creds` se omite por completo
  (útil si montas tu propio directorio de credenciales).
- Para usar otra ubicación: `APPS_LAYER_DIR=/ruta/absoluta` (mismas reglas de permisos). Si ya tienes un directorio previo con modo 775 (p. ej. el antiguo
  `apps-layer/` de la raíz), `chmod 700` antes de usarlo, o muévelo.

## Lanzar y RELANZAR (8 pasos)

Desde `2-apps-layer-kit/` (otro clúster/cuenta: cambia `CLUSTER_NAME`/`AWS_ACCOUNT_ID`/`AWS_REGION`/`EXTERNAL_DOMAIN` en
`cluster.env` o `kit.env`, o expórtalas, y repite desde el paso 1):

```bash
export AWS_PAGER=""                                        # opcional: los scripts ya lo fijan
scripts/s3-requisites.sh plan                              # 1. solo lectura: que existe y que crearia (no escribe nada)
scripts/s3-requisites.sh apply                             # 2. crea stack+bucket+usuario+secreto (pide terminal y escribir el cluster)
scripts/s3-requisites.sh env                               # 3. S3_BUCKET_ACCESS_KEY/SECRET_KEY + AWS_REGION al .env (sin imprimirlas)
scripts/import-llm-token.sh /ruta/al/extensions.yaml       # 4. LLM_TOKEN del YAML del lab al .env (o: export LLM_TOKEN=...; scripts/import-llm-token.sh)
scripts/render-apps-layer.sh                               # 5. YAML raiz + YAML del tenant (+ .env, kube-config, aws/) en $APPS_LAYER_DIR (/tmp/apps-layer-<cluster>)
scripts/check-apps-layer.sh                                # 6. solo lectura: debe terminar en 'sin KO' y mostrar 'LLM_TOKEN OK (N caracteres) -> genai-*: ...'
scripts/launch-apps-layer.sh                               # 7. DESCARGA fresco zip del universo + universe-images.lst (fetch-universe.sh) e IMPRIME el docker run (con --run lo ejecuta)
# 8. dentro del contenedor:
source /apps-layer/.env && cd /apps-layer
apps-installer <CLUSTER_NAME>.yaml                         #    tenant keos
apps-installer <CLUSTER_NAME>-<TENANT_NAME>.yaml           #    tenant dev (vigila el punto de control sscc-s3, abajo)
```

Los pasos 3-4 pueden hacerse antes o después del 5; `render` conserva las líneas secretas del `.env` existente y hace
copia `.bak` de lo que cambie. Cada script admite `-h`. Prueba sin tocar nada: `scripts/render-apps-layer.sh --dry-run`.

### Contenedor ya arrancado vs. contenedor nuevo

- **Contenedor interactivo ya arrancado** (el `.env` antiguo se cargó al arrancar): no hace falta reiniciarlo. En su shell:
  `source /apps-layer/.env && cd /apps-layer && apps-installer <yaml>`. No lances un segundo contenedor: su entrypoint
  hace `docker rm -f keos-installer_<cluster>` y rompería el `apps-installer` del primero (`launch --run` lo detecta y aborta).
- **Contenedor nuevo**: `launch-apps-layer.sh` imprime el comando (monta `$APPS_LAYER_DIR` en `/apps-layer`,
  `$KEOS_WORKSPACE_DIR` en `/workspace`, `docker.sock`, `$APPS_LAYER_DIR/aws` en `/root/.aws` solo lectura, el zip del universo y el `.lst` frescos sobre los de la imagen (ver abajo); `--net host
  --cgroupns host`; `--add-host admin.<dominio>:<IP del NLB>` resuelta con `kubectl`, o fija `NLB_IP`). El entrypoint carga
  `/apps-layer/.env` solo. `$APPS_LAYER_DIR/aws` debe existir con el perfil que use el `kube-config` (`aws eks get-token`):
  lo crea `render-apps-layer.sh` (solo el perfil `cloud-provisioner`; ver arriba).

## Universo: zip de descriptores y `universe-images.lst` (siempre frescos)

La imagen trae un universo embebido (`/apps-layer-automation/universe/`), pero **se descarga siempre fresco antes de cada lanzamiento y se monta encima**:
`launch-apps-layer.sh` invoca `scripts/fetch-universe.sh` (que también puedes lanzar solo) y **nunca reutiliza una copia previa**:

| Fichero (en `$APPS_LAYER_DIR`) | Origen | Montaje en el contenedor |
|---|---|---|
| `kubernetes-universe-descriptors-${UNIVERSE_VERSION}.zip` | `curl -fSL` de `http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/<zip>` (VPN) a un temporal, `unzip -t`, tamaño > 0, `mv` atómico; imprime tamaño y sha256 | `-v <zip>:/apps-layer-automation/universe/<zip>` |
| `${UNIVERSE_VERSION}-universe-images.lst` | `gh api -H 'Accept: application/vnd.github.raw' repos/Stratio/kubernetes-universe/contents/universe-images.lst?ref=${UNIVERSE_BRANCH}` (tag `15.1.0` por defecto), no vacío y con `connectors-loader`, `mv` atómico | `-v <lst>:/apps-layer-automation/universe/<lst>:ro` |

Por qué el `.lst`: `apps/connectors-management/post-install.sh` saca de ahí la versión de `connectors-loader` y `apps/intelligence/post-upgrade.sh` la de
`analytic-environment`. El de la imagen está desfasado (connectors-loader **2.2.0** frente a **2.2.5** en `branch-15.1`, que ya es 15.1.1, y ~100 imágenes más con bump de patch; el tag `15.1.0`, el que usa el kit, trae 2.2.0). Por defecto el kit
**fija `CONNECTORS_LOADER_VERSION=2.2.0`** en el env de `connectors-management` del tenant (como la PR Stratio/keos-fleet#220, probada solo en HDFS): **con el pin, el hook IGNORA el `.lst`
para el loader** (el `.lst` fresco sigue siendo obligatorio: `intelligence` lo usa para `analytic-environment` y `connectors-management` lo usa si no hay pin). Para usar el loader del `.lst` (el del tag usado: 2.2.0 con `15.1.0`) pon `CONNECTORS_LOADER_VERSION=` **vacía** en `kit.env` (la línea no se renderiza); con otro valor se fija ese. `check-apps-layer.sh` informa de qué versión de loader se usará.

- Sin `gh` autenticado con acceso a `Stratio/kubernetes-universe`, o sin VPN, `fetch`/`launch` **paran** con un mensaje claro (no hay modo "usar lo que hubiera").
- `launch --skip-fetch`: solo si acabas de descargarlos a mano; exige ambos ficheros válidos y avisa si tienen más de 24 h.
- `check-apps-layer.sh` marca **KO** si falta el zip, está vacío/corrupto, o si falta el `.lst` o no contiene `connectors-loader` (y avisa si pasan de 24 h).
- Un contenedor ya arrancado no ve los ficheros nuevos: hay que relanzarlo (con el cuidado de siempre sobre `keos-installer_<cluster>`).

## Secretos y LLM_TOKEN

- Las **plantillas no contienen ningún secreto**. Los valores viven en `$APPS_LAYER_DIR/.env` (600, en `/tmp`, fuera del repo) y, solo `LLM_TOKEN`, también en el YAML del tenant.
- **`LLM_TOKEN` se usa de verdad por dos vías, ambas escritas por `render`**:
  1. **Inyectado en el env del tenant del YAML** (`LLM_TOKEN: '...'`, como en `eosdev/extensions.yaml`): es **suficiente aunque no
     se haga `source` del `.env`**. apps-layer exporta el env del tenant a los hooks de cada app (`deploy-apps.sh`:
     `export clave=valor` sin comillas), por eso el render rechaza tokens con espacios o `* ? [`. Lo consumen `genai-litellm`
     (registra credencial y modelo en LiteLLM) y `genai-api` (lo guarda en Vault); `genai-ui` no lo usa. Ese YAML queda con **chmod 600**
     y cabecera "contiene secretos: no subir a git".
  2. **En `.env`** (`export LLM_TOKEN='...'`): respaldo para quien haga `source /apps-layer/.env`.
- Con `ENABLE_GENAI=true` y sin token (ni en el entorno ni en el `.env`) **`render` aborta** con un mensaje claro; no quita apps en silencio.
- `import-llm-token.sh <yaml>` busca `LLM_TOKEN` en cualquier nivel (global, tenant, app). Si hay valores distintos aborta y lista solo
  las **rutas** de las claves. Sin argumento usa `LLM_TOKEN` del entorno. Imprime solo `LLM_TOKEN importado (N caracteres)`.
  El token puede estar ya en claro en `eosdev/extensions.yaml`, `three/extensions.yaml` y `eosdev/micro.yaml` del checkout de apps-layer-automation:
  si esos ficheros se han subido a git, conviene rotarlo.
- `check` verifica sin imprimirlo: `LLM_TOKEN` en el YAML renderizado y en el `.env`, no vacío, igual en ambos, YAML en 600, y termina con
  `LLM_TOKEN OK (N caracteres) → genai-*: genai-api, genai-litellm`.
- **`ENABLE_GENAI=false`** (opción manual): se omiten `genai-litellm/api/ui` **y también `datamarket-agent` y `pit`**, porque sus hooks
  (`pit/post-deploy.sh`, `datamarket-agent/post-install.sh`) asignan roles y grupos de GoSec que crea `genai-api`; no hay `LLM_TOKEN` en el YAML
  y se quitan `ROCKET_GENAI_ENABLED`/`INTELLIGENCE_GENAI_ENABLED` y `DEPENDENCIES_GENAI_*`. El render avisa.
- Ninguna app genai-* tiene rama S3 ni HDFS: solo usan Postgres/OpenSearch y el token.
- **`DISCOVERY_ADMIN_GROUP` / `INTELLIGENCE_ADMIN_GROUPS`** van fijos a `<tenant>-stratio-owners` en `templates/tenant.yaml.tpl` (grupo que crea el tenant). Deben existir en GoSec: con un grupo inexistente el post-install de discovery da 403 al crear la BD de Virtualizer y `apps-installer` se detiene (PR keos-fleet#220, `a73962b6`; `discovery/pre-install.sh` solo crea `<tenant>-discovery-admins` e ignora la variable). Un test del kit fija ambas líneas.

## Decisiones del caso de uso (qué hace el render)

- **S3**: `S3_BUCKET_NAME` en el env del tenant; sin app `hdfs` ni `connector-dfs-hdfs`; se añade `connector-s3`. Las variables
  **`connector-s3` lleva `INIT_PATH: ${S3_INIT_PATH}` (def. `/<S3_BUCKET_NAME>`)**: `vars.env` de connector-s3 (`branch-15.1-0.1`) tiene la errata `export INTI_PATH=...`, la plantilla renderiza `"customInitPath": ""` y el agente `dg-s3-agent` crashea con `Missing environment variable: COMM_SERVICE_INIT_PATH`; `check-apps-layer.sh` da KO si falta o si vale exactamente `/`. Verificado en vivo: `/<bucket>` arranca el agente (1/1 Running) y conecta con S3; la raíz `/` NO sirve (el agente falla con `UnsupportedRootInitPath: Custom driver does not support '/' as init-path`).
  Las variables `*_DECOUPLED_CONNECTOR_HDFS` valen `false` por defecto en las apps y no se escriben. `pit` lleva `HDFS_USAGE_POLICY_POLICY_ENABLED: false`
  (su política hdfs no tiene rama S3). **Las claves S3 van al `.env`, no al stack ni al YAML**: `apps-layer` calcula `CLUSTER_NAME=admin` y buscaría
  el stack `admin-requisites`, y `AWS_REGION` no existe en la imagen. Sin `S3_BUCKET_ACCESS_KEY/SECRET_KEY` en el entorno las apps vuelven en silencio
  a HDFS y fallan lejos del origen: `check` lo valida (solo nombres) antes de lanzar.
- **Hosts**: con `USE_TENANT_HOSTS=false` (defecto) el render no escribe ninguna `*_HAPROXY_HOST`/`*_HAPROXY_PATH`/`VIRTUALIZER_SERVER_HOST`: cada app usa su
  default (`${CLUSTER_NAME}.${EXT_DOMAIN}` = `admin.<dominio>` + path propio; no hace falta DNS ni certificado nuevos) y se omite el segundo `dlc-entity`
  (idéntico al primero sin host propio). Con `true` se reproducen los hosts del lab (`genai|rocket|discovery|virtualizer|dlc.${tenantId}.${external_domain}`,
  placeholders que resuelve Command Center) y exigen registro DNS (external-dns) y certificado que cubra `*.<tenant>.<dominio>`.
- **Gobierno `keos`**: `full` reproduce `eosdev.yaml` (opensearch1 + se-searcher/manager/indexer + governance-map/ui + scheduler + datamarket); `minimal`
  es el de la PR 220. `minimal` no se ha validado junto a `datamarket-agent`/`pit` del tenant.
- **Almacenamiento**: el bucket único se usa con prefijo `/data` (virtualizer, rocket). No hay políticas GoSec de S3: la credencial es global y compartida.

## ENVIRONMENT_SIZE=CUSTOM: recursos propios por app

**Qué es y cuándo usarlo.** apps-layer-automation (`branch-15.1-0.1`) solo conoce los tamaños `S` y `PIT`: `deploy-apps.sh` hace `source apps/<app>/sizes/S|PIT` y con cualquier otro valor **no carga nada**,
y `envsubst` no valida (una variable de recursos que falte sale **vacía** en el JSON de la app y el despliegue falla lejos del origen). La guía de la PR Stratio/keos-fleet#220 (§7.2) usa `ENVIRONMENT_SIZE: CUSTOM`
con todas las variables de recursos puestas a mano en el `env:` de cada app, pero eso **no es un modo soportado upstream** (no existe `sizes/CUSTOM`). El kit lo reproduce con un overlay propio:
`ENVIRONMENT_SIZE=CUSTOM` en `kit.env` (o exportada) y `render-apps-layer.sh` inyecta en el `env:` de cada app de **los dos YAML** las variables de `templates/sizes-custom.env`. Úsalo si quieres los recursos
del cliente de la guía (o los tuyos) en vez de los de `S`/`PIT`. Sin tocar nada, con `S`/`PIT` el render es **idéntico byte a byte** al de siempre (el overlay no se lee).

- **Por qué importa que `sizes/` pisa el env.** Con `S`/`PIT`, `deploy-apps.sh` carga `sizes/<tamaño>` **después** del `env` del tenant y de la app. En las apps cuyo `sizes/S` exporta valores fijos
  (`dg-ontology-graph-api`, `dg-discovery-manager`, `dg-datarest-pgi`, `discovery`, `intelligence`, `rocket`, `rocket-catalog-standalone`, `eureka-agent`, `connector-s3`, `connector-rdbms-postgres-internal`,
  `dlc-entity`, `genai-api/litellm/ui`, `pit`, `hdfs`) **pisa** lo que pongas en `env:`; en las que usan `${VAR:-defecto}` (el resto) manda el `env`. Por eso en `S`/`PIT` no puedes cambiar los recursos de las primeras
  desde el YAML: con `CUSTOM` no se carga ningún `sizes/` y manda siempre el `env:` (el overlay).
- **Overlay editable.** `templates/sizes-custom.env` (formato INI: `[app]` y `VARIABLE=valor`, sin comillas) lleva **todas** las apps de nuestras plantillas, con la procedencia de cada valor en el propio fichero:
  los de la guía (Francisco, §7.2: `dg-businessglossary-api`, `dg-ontology-graph-api`, `dg-discovery-manager`, `governance-map`, `governance-ui`, `postgres` [valores de pg-meta], `postgres-agent`, `pgbouncer`,
  `connectors-management`, `rocket` [+12 de workers], `eureka-agent`, `dg-datarest-pgi`, `discovery`, `intelligence`) y, para las que la guía no cubre, copiados tal cual de `apps/<app>/sizes/S` (kafka, opensearch*, se-*,
  dg-scheduler-agent, dg-datamarket-api, governance-datamarket-ui, rocket-catalog-standalone, connector-s3, connector-rdbms-postgres-internal, dlc-entity, virtualizer-monitor/ui, datamarket-agent, genai-*).
  **Solo se traen los recursos**: no los hosts `rocket.dev.igualdad…`, `DISCOVERY_*`, `DG_DATAREST_TYPES_TO_BE_DISCOVERED`, `GOVERNANCE_API_SWAGGER_ENABLED`, `DOMAINS_ENABLED`, `VIRTUALIZER_MONITORING_ENABLED`, `DATANODE_*` ni
  subdominios por tenant. Son tamaños de un cliente (p. ej. postgres pide 4096M, y los workers de rocket 3072/3072/1024/1024): compáralos con tus nodos antes de lanzar.
- **Cambiarlos sin tocar el fichero del repo.** `cp templates/sizes-custom.env ~/mis-sizes.env`, edítalo y `export CUSTOM_SIZES_FILE=/ruta/absoluta/mis-sizes.env` (en `kit.env`). El fichero indicado **sustituye** al del kit
  por completo (no se mezclan): lo que ves es lo que se usa. Una sección vale para **todas las instancias** de esa app del YAML (las dos de `connector-rdbms-postgres-internal`, `opensearch1` de keos y del tenant...).
- **Salvaguarda.** Tras renderizar, el kit comprueba que **cada app** de ambos YAML lleva **todas** las variables de recursos que consume su plantilla upstream (lista cerrada por app en `scripts/lib.sh`,
  `custom_required_vars`) y **aborta** nombrando app y variable (`app postgres: falta MEMORY_LIMITS`); no escribe nada. También rechaza en el overlay apps desconocidas, variables que la plantilla no consume (p. ej. `MEMORY_LIMITS`
  en `discovery`), sintaxis mala, valores con comillas/vacíos y secciones o variables repetidas. `check-apps-layer.sh` repite la comprobación sobre los YAML ya generados (KO si falta alguna). Al añadir una app a las plantillas del kit
  hay que añadirla a esa lista y al overlay (sin lista, el render aborta).
- **Quirks de las plantillas (respetados en el overlay).**

| App(s) | Quirk |
|---|---|
| `discovery`, `intelligence`, `rocket`, `rocket-catalog-standalone` | **no consumen `MEMORY_LIMITS`** (solo `MEMORY_REQUESTS`): declararla es error. Francisco la tiene en rocket/intelligence, pero la plantilla la ignora |
| `governance-map` | memoria **cruzada**: `podMemoryLimit` sale de `MEMORY_REQUESTS` y `MEM` de `MEMORY_LIMITS`. Para request 512 / límite 1024 (cliente) hay que poner `MEMORY_REQUESTS=1024` y `MEMORY_LIMITS=512` |
| `postgres`, `pgbouncer` (y kafka, opensearch, opensearch-dashboards en sus `S`) | memoria **con unidad** (`4096M`, `768M`); el resto **sin unidad** (= MB de Command Center). No mezcles |
| `postgres` | además `SHARED_BUFFERS` y `MAINTENANCE_WORK_MEM`. El tenant del kit tiene **un solo** postgres (`psql`), que hace de pg-meta y de pg-data: el overlay usa los valores de pg-meta (pg-data del cliente: `CPU_LIMITS=4`, `MEMORY_LIMITS=8192M`) |
| `rocket` | 12 variables de workers: `DEBUG_`, `CATALOG_`, `VALIDATOR_` y `EXTERNAL_SERVICES_` × `CPU_REQUESTS`, `CPU_LIMITS`, `MEMORY_REQUESTS` |
| `virtualizer`, `pit` | no consumen recursos (la plantilla de virtualizer no los expone; pit no tiene plantilla): sin sección |
| `hdfs`, `connector-dfs-hdfs` | no existen en este kit (S3) |

- **Lo que `CUSTOM` no cubre.** Instancias de postgres, parámetros de postgres/pgbouncer, heap de los agents, calidad de servicio `Guaranteed`, etc. no los exponen las plantillas: se ajustan después en Command Center
  (siguiente sección). **No verificado**: ninguna ejecución real de `apps-installer` con `CUSTOM`; la semántica de `deploy-apps.sh` (carga solo `S`/`PIT`; `envsubst` sin validar) es lectura de código de `branch-15.1-0.1`.

## Ajustes posteriores en Command Center (técnica, no se automatiza)

La guía de la PR (§7.4) cambia después de `apps-installer`, apoyándose en su `cct-ajustes-cliente.sh`, parámetros que las plantillas no exponen. **Ese script y `keos-cluster-snapshot.sh` NO se adoptan**: todo su contenido es sizing y
seguridad del cliente (nombres de tenant `dev`, namespaces y apps del cliente, JWT/TLS desactivados en dg-datarest-pgi, etc.). Sí se documenta aquí la técnica y un bug, para ajustes que quieras hacer tú:

- **Bug de CCT 15.1: actualizar `intelligence` falla si ya existe el `SecretsBundle intelligence`** (la actualización intenta crearlo de nuevo). Antes de actualizarla hay que borrarlo; Command Center lo vuelve a crear:
  `kubectl -n <tenant>-intelligence delete secretsbundles.secrets.stratio.com intelligence --ignore-not-found`.
- **`PUT /v2/upgrade/<app>` al orquestador** (lo que hace `scripts/upgrade-apps.sh` de apps-layer): `GET /v1/applications/<id>/deployment?interpolate=false` (descriptor y despliegue actuales; `<id>` = `<app>.<tenant>-<sufijo>`)
  → modificar el JSON del despliegue → `PUT /v2/upgrade/<id>` con `{"descriptor": {service, model, version}, "deployment": <modificado>}`. El orquestador exige la clave del cliente en PEM y la guarda en DER (PKCS8): se convierte
  **fuera del pod**, se copia al pod con otro nombre y se **borra de los dos sitios al salir** (`trap`, declarado antes de crear nada para que se ejecute aunque falle un paso). Plantilla (sin valores de cliente; adapta `<id>` y el cambio):

```bash
set -euo pipefail
# El trap va PRIMERO: así la clave se borra (local y en el pod) aunque falle mktemp, cp u openssl más abajo
W=""; O=""
trap '[ -z "$O" ] || kubectl -n keos-cct exec "$O" -- rm -f /tmp/ajuste.key.pem /tmp/ajuste-upgrade.json || true; [ -z "$W" ] || rm -rf "$W"' EXIT
W=$(mktemp -d); chmod 700 "$W"
O=$(kubectl -n keos-cct get po -l app.kubernetes.io/name=cct-orchestrator -o name --sort-by=.metadata.creationTimestamp | tail -1 | cut -d/ -f2)
kubectl -n keos-cct cp "$O:/tmp/server.key.pk8" "$W/k.pk8" >/dev/null
openssl pkcs8 -in "$W/k.pk8" -inform DER -outform PEM -out "$W/k.pem" -nocrypt
kubectl -n keos-cct cp "$W/k.pem" "$O:/tmp/ajuste.key.pem" >/dev/null; rm -f "$W/k.pk8" "$W/k.pem"
cct() { kubectl -n keos-cct exec "$O" -- curl -s -k --cert /tmp/server.crt --key /tmp/ajuste.key.pem "$@"; }
ID=<app>.<tenant>-<sufijo>
cct -f "https://cct-applications-query:8443/v1/applications/$ID/deployment?interpolate=false" > "$W/d.json"
python3 - "$W/d.json" "$W/up.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); D = d['deployment']
# D['general']['resources']['memResourceType'] = 'Guaranteed'    # <- el cambio que toque (la estructura depende del descriptor)
json.dump({'descriptor': {k: d['descriptor'][k] for k in ('service', 'model', 'version')}, 'deployment': D}, open(sys.argv[2], 'w'))
PY
kubectl -n keos-cct cp "$W/up.json" "$O:/tmp/ajuste-upgrade.json" >/dev/null
cct -o /dev/null -w '%{http_code}\n' -X PUT "https://localhost:8443/v2/upgrade/$ID" -d @/tmp/ajuste-upgrade.json -H 'content-type: application/json'
```

  Comprueba antes el resultado en un entorno de pruebas: modificar el despliegue de una app puede reiniciar sus pods.

## Backups de la plataforma con `enviroment-ready` (OPCIONAL)

Es un paso **opcional** (paso 14h de la skill): la guía de la PR (§7.5-7.6) lo hace así en el cliente, pero ni apps-layer ni este kit lo necesitan, y **actúa sobre el clúster**. `scripts/backups-env.sh` solo **escribe**
`${APPS_LAYER_DIR}/backups.env` (modo 600, **sin comillas** ni comentarios: el script exporta cada valor tal cual y las comillas acabarían dentro del ARN del rol; no hay secretos) con
`AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_BUCKET_NAME` (= `VELERO_BUCKET` de `cluster.env`) y `AWS_IAM_ROLE_NAME` (= `VELERO_ROLE`, el **nombre**, no el ARN; más `SC_POSTGRES` si lo defines), e imprime los avisos y comandos. No ejecuta
`enviroment-ready`, ni docker, ni kubectl, ni aws. `--dry-run` muestra sin escribir.

```bash
scripts/backups-env.sh                                    # escribe $APPS_LAYER_DIR/backups.env (lo ve el contenedor como /apps-layer/backups.env)
# dentro del contenedor de apps-layer (launch-apps-layer.sh --run), con keos install y las apps ya instaladas:
cd /apps-layer && enviroment-ready --backups backups.env
```

- **Qué hace en el clúster**: `keos backup create idp vault` (volúmenes en `keos-backup`), escribe `override_vars/velero.yaml` en el workspace si no existe y **relanza `keos backup velero`**, y para cada PgCluster crea un PVC
  `<pg>-backup-pvc` de 40Gi y un `PgBackup` diario a las 01:00 si no existen (el cliente los tiene escalonados y con PVC de 50/50/80Gi; la guía los crea antes con `kubectl apply`: es sizing del cliente, no se adopta). Los PVC quedan `Pending` (StorageClass `WaitForFirstConsumer`) hasta la primera ejecución del backup: es normal. Solo lanza un backup
  **puntual** de IdP y vault; los diarios (00:00 IdP, 00:05 vault, 7 días) son `keos backup schedule vault idp` desde la shell de keos-installer (paso 13b de la skill).
- **Requisito para que Velero funcione con IRSA**: el override `keos-backup-velero.yaml` (`credentials.useSecret: false`) que genera `render-keos.sh` con `ENABLE_BACKUP_VELERO=true` en `cluster.env`; sin él la `BackupStorageLocation`
  puede quedar `Unavailable`. Comprueba: `kubectl -n keos-backup get bsl aws` (debe estar `Available`).
- **Es el bucket de Velero, no el de `ENABLE_BACKUPS_BUCKET`.** Son dos cosas distintas: este `backups.env` usa el bucket y el rol IRSA de Velero que ya creó la fase 1 (sin claves estáticas); el "Bucket de backups opcional" de arriba
  es otro bucket con usuario IAM de claves estáticas que solo necesita la migración a GitOps (keos-fleet). La PR 220 **no** usa `BACKUPS_S3_BUNDLE`, así que no valida su formato; el formato del kit es el de
  `configure-gitops.sh` de `Stratio/aws-clusters-automation` (productor: `passwords: [{name: backup, data: {user, pass}}]` en base64) y los componentes de `Stratio/keos-apps` lo consumen como `bundle:` de un `Secret`
  (comprobado leyendo código; no probado contra un keos-fleet real).
- **Reporters (aún más opcional, guía §7.6).** `enviroment-ready --reporter backups.env` (exige un fichero aunque no lo use: sirve el mismo `backups.env`) crea el namespace `keos-reports`, la `GlobalNetworkPolicy`
  `allow-all-traffic-from-keos-reports` y tres HelmReleases (`postgresql-statistics-report`, `keos-versions-reporter`, `functional-monitoring`). Avisos conocidos: (1) `functional-monitoring` necesita el chart **0.3.1** y la imagen
  `stratio/functional-monitoring:0.3.1`, que puede **no estar en el ECR** (`717279725338` en la PR; `ImagePullBackOff`): hay que subirla desde `qa.int.stratio.com/stratio/functional-monitoring:0.3.1` (el universo 15.1 espera la 0.3.2, cuyo chart no está
  en el ECR `helm-15.1`); (2) el hook post-install de `functional-monitoring` falla con `i/o timeout` hacia `thanos-query.keos-metrics:9090` porque la `GlobalNetworkPolicy` se crea con `namespaceSelector: name == 'keos-reports'` y el namespace no
  lleva esa etiqueta; parche (desde el host):
  `kubectl patch globalnetworkpolicies.crd.projectcalico.org allow-all-traffic-from-keos-reports --type json -p '[{"op":"replace","path":"/spec/ingress/0/source/namespaceSelector","value":"kubernetes.io/metadata.name == '"'"'keos-reports'"'"'"}]'`;
  (3) un nuevo `enviroment-ready --reporter` vuelve a aplicar la plantilla y **pisa** el parche: repítelo. Todo ello **sin ejecutar nunca** desde este kit ni probado contra un clúster real.

## Punto de control crítico: `sscc-s3` (riesgo no verificado)

Virtualizer, rocket, eureka-agent y connector-s3 dependen de que `connectors-management` (loader **2.2.0** fijado por defecto como la PR keos-fleet#220, o **2.2.3** del `universe-images.lst` fresco si `CONNECTORS_LOADER_VERSION` está vacía) sirva el jar `sscc-s3` (scala 2.12).
No se ha podido comprobar que lo incluya: hay que verificarlo contra la versión de loader que se use (2.2.0 por defecto, 2.2.3 con la variable vacía). **Tras la primera tanda del tenant** (cuando `connectors-management` esté Running), desde otra terminal:

```bash
scripts/check-apps-layer.sh --no-aws        # ejecuta el GET dentro del pod y marca KO si viene vacio
# a mano:  kubectl -n <tenant>-apps exec <pod-connectors-management> -- \
#   curl -s "http://connectors-management.<tenant>-apps/v1/api/connector/findByName?name=sscc-s3"
```

Si viene **vacío, parar** (Ctrl-C en `apps-installer`; ojo: su `trap EXIT` hace `helm rollback cct`): hay que subir el conector `sscc-s3` al
connectors-management antes de continuar. Los jars de `apps/nginx-connectors` del checkout sugieren que antes se hacía a mano.

## Teardown y ciclo de vida

- El stack mínimo crea el bucket con `DeletionPolicy: Retain`: borrar el stack **no** borra el bucket. `scripts/s3-requisites.sh delete` vacía el bucket
  (el de backups, si existe, se conserva salvo `--delete-backups`; ver "Bucket de backups opcional") (objetos, versiones, delete markers, multipart), borra el stack, borra el bucket y libera el nombre del secreto (CloudFormation lo deja en ventana de
  recuperación y bloquearía un relanzado con el mismo nombre). Pide escribir el nombre del clúster y la cuenta y exige terminal; comprueba que el bucket
  es del clúster (output del stack o etiqueta `cluster`).
- **Con la skill `legacy-eks-cluster`**: `teardown.sh` tiene una **fase A (apps-layer, la primera)** que para `apps-layer-<cluster>` y `keos-installer_<cluster>`, borra el directorio efímero y, con `--delete-s3-requisites`, invoca este `s3-requisites.sh delete`; la skill también envuelve estos scripts en `scripts/apps-layer.sh` (paso 14). A mano: ejecuta `scripts/s3-requisites.sh delete` **antes** de `teardown.sh`. El usuario IAM
  `${CLUSTER_NAME}-s3`, su access key, el secreto y el bucket interno son del clúster y la skill no los conoce (nota en
  `.claude/skills/legacy-eks-cluster/references/teardown.md`).
- Desinstalar apps de apps-layer: no hay comando completo (ver `docs/INFORME.md`, paso 5).

## Pruebas

`tests/run-offline-tests.sh` (sin AWS, sin red, sin docker real; directorio temporal; `aws`/`kubectl`/`docker` simulados con datos ficticios: cuenta
`111111111111`, clúster `demo-x`, tenant `dev`, token ficticio). Cubre render (perfil x hosts, con/sin token y genai), `.bak`/idempotencia/
conservación de secretos, importación del token, `s3-requisites` (plan solo lectura, apply sin tty, delete con confirmación errónea, env sin imprimir ni duplicar), el bucket de backups opcional (plantilla con `yq` y sin cambios en lo existente, variables y validación de identidades protegidas, plan/apply/env/status/backups-info/delete con y sin habilitar, `delete` sin `--delete-backups` no toca el bucket),
`launch` (comando impreso, nada sin `--run`), `check`, `ENVIRONMENT_SIZE` inválido, el directorio por defecto en `/tmp` con modo 700, el aborto si existe con permisos abiertos
(o enlace simbólico) la descarga fresca del zip y del `.lst` (curl y gh falsos: fallos, vacío, corrupto, sin `connectors-loader`, sin `gh` autenticado, `--skip-fetch`, versión/rama), el aviso de `APPS_LAYER_DIR` inesperado y la creación de `kube-config` (copia y `aws eks update-kubeconfig`) y de `aws/` (solo el perfil `cloud-provisioner`, 600, `--no-aws-creds`) con mocks. Cubre también `ENVIRONMENT_SIZE=CUSTOM` (render completo para `full`/`minimal` x hosts, quirks, overlay propio con `CUSTOM_SIZES_FILE`, salvaguarda que falla nombrando app y variable, `check`, y que `S`/`PIT` no cambian ni leen el overlay) y `backups-env.sh` (4 líneas sin comillas, modo 600, `.bak`, `--dry-run`, validaciones, sin llamadas a aws/kubectl/docker). Comprueba además que el token no aparece en ninguna salida.

## Solución de problemas

| Síntoma | Causa / acción |
|---|---|
| `render` aborta: "ENABLE_GENAI=true pero no hay LLM_TOKEN" | `scripts/import-llm-token.sh <yaml>` o `export LLM_TOKEN=...` y repetir; o `ENABLE_GENAI=false` |
| `apply` aborta "terminal interactiva" | ejecutarlo desde una terminal (no `| tee`, no cron) |
| `apply` dice que el bucket/usuario/secreto ya existe | nombres globales/ya usados: cambia `S3_BUCKET_NAME`/`S3_USER_NAME`, o si es de un intento anterior, `delete` |
| Secreto "programado para borrado" | `aws secretsmanager delete-secret --secret-id <S3_USER_NAME> --force-delete-without-recovery` (irreversible; `delete` lo hace solo) |
| Apps vuelven a HDFS / `s3-secret` vacío en Vault | faltan `S3_BUCKET_ACCESS_KEY/SECRET_KEY` en el entorno del contenedor: `s3-requisites.sh env`, `check`, `source /apps-layer/.env` |
| `admin.<dominio>` no resuelve en el contenedor | falta `--add-host` (usa `launch`; fija `NLB_IP` si no resuelve el NLB) |
| `aws eks get-token` falla dentro del contenedor | falta `$APPS_LAYER_DIR/aws` (`render-apps-layer.sh` lo crea) o el perfil del `kube-config` no es `cloud-provisioner` |
| Scripts abortan "directorio de ejecucion de apps-layer no seguro" | `chmod 700 $APPS_LAYER_DIR` (o es de otro usuario/enlace: bórralo o cambia `APPS_LAYER_DIR`) |
| Tras reiniciar no existe `/tmp/apps-layer-<cluster>` | es efímero: `render-apps-layer.sh`, `s3-requisites.sh env`, `import-llm-token.sh` y de nuevo `render` |
| `check`: `.env con modo 644` | `chmod 600 $APPS_LAYER_DIR/.env` (o repetir `render`) |
| `findByName?name=sscc-s3` vacío | parar (ver punto de control) |
| Hosts `*.dev.<dominio>` no abren | `USE_TENANT_HOSTS=true` exige DNS y certificado; vuelve a `false` |
| `fetch`/`launch`: "gh no esta autenticado" o "gh api no pudo leer" | `gh auth login` con una cuenta con acceso a `Stratio/kubernetes-universe`; comprueba `UNIVERSE_BRANCH` |
| `fetch`/`launch`: "no se pudo descargar ... zip" | VPN/acceso a `qa.int.stratio.com`; `UNIVERSE_ZIP_URL` si el zip está en otra URL |
| `check`: KO del zip o del `.lst` | `scripts/fetch-universe.sh` (o `launch`, que lo hace siempre) |
| `render` aborta "ENVIRONMENT_SIZE=CUSTOM: en <yaml> faltan variables de recursos ... app X: falta VAR" | el overlay (`templates/sizes-custom.env` o `CUSTOM_SIZES_FILE`) no tiene esa variable para esa app: añádela (ver la lista de la sección CUSTOM) |
| `render` aborta "la plantilla de 'X' no consume VAR" | `MEMORY_LIMITS` en discovery/intelligence/rocket/rocket-catalog-standalone, o una variable mal escrita: quítala |
| Actualizar `intelligence` en Command Center falla | bug de CCT 15.1 con el `SecretsBundle intelligence` existente: `kubectl -n <tenant>-intelligence delete secretsbundles.secrets.stratio.com intelligence` y repetir |
| `yq` falla con "No module named yq" | el `yq` de kislyuk necesita su entorno Python; comprueba `yq --version` |

## Lo que NO está verificado

Ninguna ejecución real de `apps-installer` con S3 ni de `aws cloudformation deploy` (solo `validate-template` y `plan` reales, y el resto con mocks);
que el `connectors-loader` que se use (2.2.0 por defecto, 2.2.3 con `CONNECTORS_LOADER_VERSION` vacía) incluya `sscc-s3`; el borrado del secreto de Secrets Manager por CloudFormation (ventana de recuperación) tal como se asume;
`pit`/`discovery` sin HDFS; ninguna ejecución de `apps-installer` con `ENVIRONMENT_SIZE=CUSTOM` ni de `enviroment-ready --backups/--reporter`; acceso S3 desde notebooks de Intelligence; pull-through de ECR, DNS y certificados con `USE_TENANT_HOSTS=true`; el perfil `minimal`
junto a `datamarket-agent`/`pit`; el namespace/servicio del NLB (`keos-ingress/ingress-nginx-controller`) en otros clústeres.
