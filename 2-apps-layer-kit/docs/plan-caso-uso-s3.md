# Plan: llevar el caso de uso (eosdev) a `igualdad-dgutierrez` usando S3 en vez de HDFS

> **Nota (reorganización del workspace):** este documento es un **análisis previo** (2026-10-27), anterior a la reorganización de
> `/stratio/e/igualdad/` y a la creación de `2-apps-layer-kit`. Las rutas operativas se han actualizado: el kit está en
> `2-apps-layer-kit/`, el kubeconfig en `1-aws-cluster/estado/`, y el directorio de ejecución de apps-layer es ahora efímero:
> `/tmp/apps-layer-<cluster>` (700). Para ejecutar, usa `../README.md` (kit) y no los comandos manuales de este análisis.
> Las menciones históricas (qué se tocó o no durante la investigación) se conservan tal cual.

Fecha: 2026-10-27. Investigación de solo lectura. No se ha modificado nada en AWS, en el clúster, en `/stratio/aws/apps-layer-automation` ni en `/stratio/e/igualdad/apps-layer/`. Se ha hecho `docker run --rm` de la imagen en un contenedor desechable (solo `ls`/`md5sum`/`env`) y `docker inspect` del contenedor del usuario (solo mounts). No se han leído secretos: el `LLM_TOKEN` en claro de `eosdev/extensions.yaml`, `three/extensions.yaml` y `eosdev/micro.yaml` no se ha copiado a ningún sitio (ver riesgos).

Leyenda: **[CÓDIGO]** leído en `branch-15.1-0.1` (tarball en `scratchpad/aln/`, coincide byte a byte con la imagen: mismo md5 de `apps/rocket/pre-install.sh` y `scripts/utils/global-functions.sh`) o en el checkout local. **[VERIFICADO]** comprobado en solo lectura (AWS, clúster, imagen, zip del universo). **[SUPOSICIÓN]** deducción mía sin probar.

Borradores generados en `/tmp/claude-1001/-stratio-e-igualdad/599c1d8f-bc2e-42c2-a977-8ed555703659/scratchpad/caso-uso-s3/`:
`igualdad-dgutierrez.yaml` (raíz/keos), `igualdad-dgutierrez-dev.yaml` (tenant dev, S3), `dot-env.example`, `requisites-s3.cfn.yaml` (plantilla CFN mínima, validada con `aws cloudformation validate-template`).

---

## (a) Qué es el caso de uso y qué hace `prepare.sh`

### a.1 `prepare.sh` (checkout `/stratio/aws/apps-layer-automation`) [CÓDIGO]

Es un **lanzador de host**, no instala nada por sí mismo. Uso `./prepare.sh <env>`. Pasos (6):

1. Preflight: exige `docker`, `wget`, `gh` (autenticado), `sudo`, y los ficheros `<env>/<env>.yaml`, `<env>/extensions.yaml` y un kubeconfig en `/stratio/e/<env>/.kube/config` o `/stratio/e/keos-workspace-<env>/.kube/config`.
2. Limpieza: `rm -rf /tmp/config && mkdir /tmp/config`; si existe `/tmp/<env>`, lo borra con `sudo rm -rf`.
3. Copia: escribe `/tmp/config/.env` (`DOCKER_DIND_ENABLED=false`, `KEOS_INSTALLER_VERSION=1.4.2`), **sobrescribe `~/.kube/config`** con el kubeconfig del entorno, lo copia a `/tmp/config/kube-config` y copia los dos YAML.
4. Descarga el zip de descriptores 15.1.0 del Nexus de QA a `/tmp/config/` y `universe-images.lst` de `Stratio/kubernetes-universe` rama `branch-15.1` (vía `gh api`) a `/tmp/config/15.1.0-universe-images.lst`. **Efecto práctico nulo**: esos ficheros quedan en `/apps-layer/`, pero `apps-installer` busca el zip en `/apps-layer-automation/universe/`, y la imagen ya trae ahí el zip (733687 bytes) y el `.lst` [VERIFICADO: `ls` en contenedor desechable].
5. `docker rm -f apps-layer-<env> keos-installer_<env>`.
6. `exec docker run --pull=always -it --name apps-layer-<env> -v /tmp/config:/apps-layer -v /tmp/<env>:/workspace -v /var/run/docker.sock:/var/run/docker.sock --net host --cgroupns host qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT`.

Luego el usuario, a mano en la shell del contenedor, ejecuta `apps-installer eosdev.yaml` (raíz) y `apps-installer extensions.yaml` (tenant). Asunciones del entorno: red/VPN a `qa.int.stratio.com` y `github.com`, `sudo` sin prompt, nombres de entorno que coinciden con `/stratio/e/<env>`, y `/tmp` como workspace.

Rarezas del lab que NO hay que replicar:
- `.env` no define `KEOS_WORKSPACE_DIR`, pero el entrypoint arranca el contenedor `keos-installer_<cluster_id>` con `-v ${KEOS_WORKSPACE_DIR}:/workspace` antes de leer los YAML (por defecto `/workspace` del host). El `KEOS_WORKSPACE_DIR: /tmp/narnia` de los YAML llega tarde. Aquí `.env` ya fija `KEOS_WORKSPACE_DIR=/stratio/e/igualdad` y es lo correcto.
- `docker rm -f keos-installer_<env>` usa el nombre del entorno, no el `cluster_id`. Con `<env>=igualdad-dgutierrez` borraría el keos-installer que está usando el contenedor ya arrancado.
- `~/.kube/config` sobrescrito y `/tmp/config` reseteado: peligroso aquí, donde `/stratio/e/igualdad/apps-layer/` es el directorio de trabajo montado.

### a.2 Qué es "caso de uso" y qué viene en la imagen [CÓDIGO / VERIFICADO]

| Elemento del checkout sucio | Qué es | ¿Aplica en el contenedor? |
|---|---|---|
| `prepare.sh` | lanzador (a.1) | No hace falta; el contenedor ya está arrancado |
| `eosdev/eosdev.yaml` | **YAML raíz**: tenant `keos` (13 apps de gobierno + opensearch1 + stack se-*) | Sí (adaptado) |
| `eosdev/extensions.yaml` | **YAML del tenant** `stratio` (27 apps, HDFS) | Sí (adaptado a `dev` y S3) |
| `eosdev/opendata.yaml`, `eosdev/micro.yaml`, `three/*` | variantes (opendata/pds/dg-nginx, solo genai, otro lab) | No para este caso |
| `apps/rocket/pre-install.sh` (modificado) | `sscc-hdfs-rocket` -> `sscc-hdfs` | **No se aplica**: `prepare.sh` no monta `apps/`; el contenedor usa las apps de la imagen. Además es solo la rama HDFS decoupled, que en S3 se desactiva |
| `apps/dg-datarest-pgi/pre-install.sh` (modificado) | añade `set -x` | No se aplica; depuración |
| `apps/nginx-connectors/files/*.jar` (sin seguimiento) | 4 jars `sscc-s3-0.3_2.12-1.0.0..1.3.3` (2024, 860 MB) | Ningún script ni YAML los referencia. Resto de un side-loading antiguo del conector S3 [SUPOSICIÓN] |
| `universe/*` borrados, `universe-images.lst` raíz | limpieza local | No |

Importante: el checkout está en `master` (HEAD `1d19c64`, 2026-10-07), que **no es** `branch-15.1-0.1`: sus `apps/` difieren en decenas de ficheros (p. ej. falta `LINEAGE_ENABLE` en rocket, `pit/pre-install.sh` tiene `s000001-stratio-owners` hardcodeado del cliente, etc.). Montar esos directorios sobre la imagen mezclaría versiones. **Conclusión: no hace falta ningún parche de `apps/*`; el caso de uso son los dos YAML + variables en `.env`.** [CÓDIGO]

### a.3 Cómo funciona el flujo (resumen) [CÓDIGO]
`apps-installer <yaml>` (ejecutado en `/apps-layer`, con ruta relativa) recorre los tenants: `create-tenant.sh`, `assign-gov-roles.sh` (no `keos`) y `deploy-apps.sh`. Cada app se ejecuta en un subshell que exporta env de tenant y de app, hace `source vars.env`, `source sizes/S`, ejecuta `pre-install.sh` (sourced), renderiza `<app>.json.tmpl`, despliega vía CCT, `post-deploy.sh`, aplica `gosec-policies/*.json` (cada uno desactivable con `<NOMBRE_FICHERO_EN_MAYÚSCULAS_Y_GUIONES_BAJOS>_POLICY_ENABLED=false`) y `post-install.sh`. Reintentable: salta apps `success/ready` (pero los `pre-install` se vuelven a ejecutar).

---

## (b) Resumen de los dos YAML del caso de uso (sin secretos)

### Raíz `eosdev/eosdev.yaml` (tenant `keos`, namespaces `keos-core`) [CÓDIGO]
`env` global: `UNIVERSE_VERSION 15.1.0`, `ENVIRONMENT_SIZE S`, `CLUSTER_NAME admin` y `EXT_DOMAIN k8s.eosdev.labs.stratio.com` (ambos **recalculados** por apps-installer desde el objeto `keos`), `KEOS_WORKSPACE_DIR /tmp/narnia`, `KEOS_INSTALLER_EXTRA_ARGS --net host`, `KEOS_INSTALLER_VERSION 1.4.2`, registry `qa.int.stratio.com/stratio/keos-installer`.
Orden: 1) dg-businessglossary-api · 2) opensearch (`opensearch1`, ns `core`, plugin fonético online) + dg-ontology-graph-api · 3) opensearch-agent + dg-discovery-manager + governance-map · 4) se-searcher + se-manager + se-indexer (mTLS, whitelist `dg-scheduler-agent`) · 5) governance-ui + dg-scheduler-agent · 6) dg-datamarket-api · 7) governance-datamarket-ui. **Sin HDFS ni S3.**

### Tenant `eosdev/extensions.yaml` (`stratio` en el lab -> `dev` aquí) [CÓDIGO]
`env` de tenant: `LLM_TOKEN` (secreto, ver riesgos), `DEPENDENCIES_*` (hdfs1/datastores, opensearch1/datastores, psql, pool-psql, virtualizer*/apps, connectors/apps, discovery/apps, rocket y rocket-catalog/rocket, genai*/genai, eureka-agent/datastores).
Orden de apps (27 entradas):
1. postgres · hdfs (`hdfs1`, 3.4.2) · kafka1 · connectors-management (apps, loader: 2.2.0 fijado por defecto con `CONNECTORS_LOADER_VERSION` como la PR keos-fleet#220; con la variable vacía, 2.2.3 del `.lst` fresco de `branch-15.1`, que se monta siempre) · opensearch1
2. postgres-agent (DOMAINS_ENABLED) · opensearch1-agent · pgbouncer
3. opensearch1-dashboards · virtualizer (decoupled PG+HDFS, `CREATE_LOADBALANCER true`, auth local) · genai-litellm
4. genai-api
5. rocket-catalog-standalone · rocket (opensearch, intelligence, genai, chains custom-id; decoupled PG+HDFS) · eureka-agent (datastores; decoupled PG+HDFS) · **connector-dfs-hdfs** (`SERVICE_NAME hdfs1.stratio-datastores`) · connector-rdbms-postgres-internal (x2)
6. dlc-entity · discovery (`DISCOVERY_ADMIN_GROUP stratio-stratio-owners`) · intelligence (decoupled PG+HDFS, `INTELLIGENCE_ADMIN_GROUPS stratio-stratio-owners`, `INTELLIGENCE_ADMIN_USERS admin,stratio-user`) · virtualizer-monitor
7. virtualizer-ui · datamarket-agent · genai-ui
8. pit · 9. dg-datarest-pgi · 10. dlc-entity (ns `dlc`)
Hosts por tenant (`genai|rocket|discovery|virtualizer|dlc|dlc-entity.${tenantId}.${external_domain}`): placeholders que resuelve CCT; solo funcionan en `env` de **app** (entrecomillado), no de tenant (el `export ${key}=${value}` sin comillas los expandiría vacíos) [CÓDIGO].

Variables HDFS en uso: `DEPENDENCIES_HDFS_APP_NAME/_NAMESPACE_SUFFIX`, `HDFS_VERSION`, `*_DECOUPLED_CONNECTOR_HDFS` (virtualizer, rocket, rocket-catalog, eureka, intelligence), app `hdfs`, app `connector-dfs-hdfs` (+`SERVICE_NAME`, `INIT_PATH /`; el equivalente S3 es `S3_INIT_PATH`, ver la fila de `connector-s3`).

---

## (c) Tabla HDFS -> S3 por app

Mecanismo común [CÓDIGO, `scripts/utils/global-functions.sh`]: `isInternalS3Enabled` = `getInternalS3Credentials` + `S3_BUCKET_ACCESS_KEY` y `S3_BUCKET_SECRET_KEY` no vacíos. `getInternalS3Credentials` solo hace algo si hay `S3_BUCKET_NAME` **y** faltan las claves: entonces lee el stack CFN `${CLUSTER_NAME}-requisites` con `--profile cloud-provisioner`, el output `S3StratioAppsSecretArn`, y el secreto de Secrets Manager (JSON `{"ACCESS_KEY","SECRET_KEY"}`). **Dos trampas**:
1. `CLUSTER_NAME` lo pisa `apps-installer` con el subdominio admin (`admin` aquí, [VERIFICADO] `ingress.admin.subdomain=null`). Buscaría el stack **`admin-requisites`**, no `igualdad-dgutierrez-requisites`.
2. `--region "${AWS_REGION}"` y `AWS_REGION` no existe en la imagen [VERIFICADO: `env | grep AWS` vacío].
Salida limpia: **inyectar `S3_BUCKET_ACCESS_KEY`/`S3_BUCKET_SECRET_KEY` en el entorno (vía `.env`)** y no depender del stack. Además `connector-s3/pre-install.sh` escribe en Vault las claves **sin** comprobar `isInternalS3Enabled` ni leer el stack: sin claves en entorno escribe vacío. Y si falta la clave, discovery/intelligence/virtualizer/rocket/eureka **vuelven en silencio a la rama HDFS** y fallan. Por eso las claves deben estar en el entorno del shell para todas las apps.

| App | HDFS (lab) | S3 (qué cambia) | Variables / hook | Fuente |
|---|---|---|---|---|
| `hdfs` | HDFSCluster `hdfs1` (3 datanodes) | **No se despliega** | quitar `HDFS_VERSION`, `DEPENDENCIES_HDFS_*` | [CÓDIGO] |
| `connector-dfs-hdfs` (`dg-hdfs-agent`) | agente DFS HDFS; en tamaño S pide 4 CPU/4 GB | **Se sustituye por `connector-s3`** (`dg-s3-agent`, modelo `agent-dfs-amazons3`, existe en el zip 15.1.0) | `APP_NAMESPACE_SUFFIX: datastores`; pre-install escribe `s3-secret` en Vault `/userland/passwords/dg-s3-agent.dev-datastores/`; `INIT_PATH: ${S3_INIT_PATH}` (def. `/<S3_BUCKET_NAME>`) **obligatorio**: `vars.env` de connector-s3 en `branch-15.1-0.1` tiene la errata `export INTI_PATH=${INIT_PATH:-/buckets}`, así que `connector-s3.json.tmpl` (`"customInitPath": "${INIT_PATH}"`) se renderiza vacío y el agente crashea con `Missing environment variable: COMM_SERVICE_INIT_PATH` (parámetro `required` sin default en el descriptor). Hermanos: connector-dfs-hdfs `/`, connector-athena `/awsdatacatalog`, pero **en S3 la raíz `/` NO sirve**: el driver falla con `UnsupportedRootInitPath: Custom driver does not support '/' as init-path`; el kit la rechaza. **Verificado en vivo**: `/<S3_BUCKET_NAME>` (también `/<bucket>/<prefijo>`) arranca el agente y conecta con S3 | [CÓDIGO] [VERIFICADO zip] [VERIFICADO en vivo: INIT_PATH] |
| `connectors-management` | igual | **Sigue siendo necesaria y crítica**: sirve el jar `sscc-s3` (`findByName?name=sscc-s3`, `scalaVersion 2.12`) que usan virtualizer, rocket, eureka y connector-s3 | `CONNECTORS_LOADER_VERSION` = `2.2.0` por defecto (variable del kit, como la PR keos-fleet#220; fijarlo hace que el hook ignore el `.lst`; vacía => loader del `.lst` fresco, 2.2.3). Que el loader usado incluya `sscc-s3` no está verificado | [CÓDIGO] / [SUPOSICIÓN] |
| `virtualizer` | storage HDFS, `DEPENDENCIES_HDFS`, política HDFS | `s3-secret` en Vault; `VIRTUALIZER_STORAGE_SELECTOR="Amazon S3"`; `VIRTUALIZER_S3_MANUALLY_CONFIG` con `s3a://${S3_BUCKET_NAME}`; `DEPENDENCIES_HDFS=` vacío; `VIRTUALIZER_PREREQUISITES_HDFS_POLICY_ENABLED=false`; conector S3 activado con el jar `sscc-s3` | poner `VIRTUALIZER_DECOUPLED_CONNECTOR_HDFS: false` (si no, añade además el jar `sscc-hdfs`) | [CÓDIGO] |
| `rocket` | `HDFS_GOSEC_VERSION` + política `rocket-hdfs.json` | `s3-secret` x2 en Vault (`rocket.dev-rocket` y `execution-identity-rocket.dev-rocket`); ConfigMap `s3-config` (`fs.defaultFS s3a://${S3_BUCKET_NAME}`, `SSCCS3HadoopFileSystem`) aplicado en `dev-rocket`; `UNIVERSE_MODEL=defaults3` (existe en el zip); `ROCKET_S3_EXTERNAL_HDFS` (basePath `/data`); `ROCKET_S3_CONNECTOR_ENABLED=true`; `ROCKET_HDFS_POLICY_ENABLED=false`; jar `sscc-s3` en `CONNECTORS_EXTRA_JARS` | `ROCKET_DECOUPLED_CONNECTOR_HDFS: false` (si no, intenta el jar `sscc-hdfs-rocket`, justo lo que tocaba el parche local) | [CÓDIGO] [VERIFICADO zip] |
| `rocket-catalog-standalone` | solo el flag `ROCKET_DECOUPLED_CONNECTOR_HDFS` | sin rama S3 | poner el flag a `false` | [CÓDIGO] |
| `eureka-agent` | jar `sscc-hdfs` | `s3-secret` en Vault; `EUREKA_JARS_ENABLED=true` y `EUREKA_ADDITIONAL_JARS` = jar `sscc-s3` | `EUREKA_DECOUPLED_CONNECTOR_HDFS: false` | [CÓDIGO] |
| `discovery` | política `discovery-hdfs.json` + gosec version de hdfs | `DISCOVERY_HDFS_POLICY_ENABLED=false`; sin credenciales S3 propias | solo depende de que las claves estén en el entorno | [CÓDIGO] |
| `intelligence` | `HDFS_CONFIG=k8-configmap` + `DEPENDENCIES_HDFS` | `HDFS_CONFIG=no-hdfs`, `DEPENDENCIES_HDFS=` vacío. No añade jar S3 (el acceso S3 de los notebooks no lo configura apps-layer) | `INTELLIGENCE_DECOUPLED_CONNECTOR_HDFS: false` | [CÓDIGO] / [SUPOSICIÓN] sobre el acceso desde notebooks |
| `pit` | aplica siempre `pit/gosec-policies/hdfs-usage-policy.json` | no tiene rama S3: con hdfs ausente `getGosecVersion` agota 5 reintentos x 5 s (el `export X=$(...)` enmascara el error) y la política se enviaría con versión vacía | `HDFS_USAGE_POLICY_POLICY_ENABLED: false` en el env de pit | [CÓDIGO] / [SUPOSICIÓN] sobre el fallo |
| `scripts/authorize-customer.sh` | — | escribiría `/people/passwords/${USER_ID}/s3-secret` para el usuario humano, **pero no lo invoca ningún script de la rama** (grep) | si se quiere acceso S3 del usuario `admin`, hay que hacerlo a mano con `vault write` | [CÓDIGO] |
| `genai-api` | — | el LLM puede ir por OpenAI (`LLM_TOKEN`) o por **Bedrock** (`BEDROCK_AWS_REGION`, `BEDROCK_INFERENCE_PROFILE_ID` + claves; lee el output `BedrockStratioAppsIAMUserSecretArn` del mismo stack, con el mismo problema del nombre) | decisión del usuario | [CÓDIGO] |
| `postgres*`, `pgbouncer`, `kafka`, `opensearch*`, `genai-*`, `dlc-entity`, `datamarket-agent`, `dg-datarest-pgi`, `virtualizer-ui/-monitor`, `connector-rdbms-postgres-internal` | sin HDFS/S3 | igual | `connector-rdbms-postgres-internal`: `SERVICE_NAME psql.dev-datastores` | [CÓDIGO] |

Un solo bucket basta: virtualizer (`VIRTUALIZER_STORAGE_PATH=/data`) y rocket (`hdfsRocketBasePath=/data`) usan `s3a://${S3_BUCKET_NAME}` con prefijo `/data`; no hay variables de bucket distintas para discovery, intelligence ni eureka [CÓDIGO]. No hay políticas gosec de S3: el acceso es una credencial global compartida (`s3-secret`), sin control por usuario/bucket [CÓDIGO].
Por tanto "dejan de ser necesarias": `hdfs`, `connector-dfs-hdfs`. "A añadir": `connector-s3`. "A sustituir en entorno": `S3_BUCKET_NAME` (tenant) + claves + `AWS_REGION`.

Alternativa no soportada por apps-layer: los descriptores permiten asumir rol (rocket `S3_ASSUMED_ROLE_AUTHENTICATION`, dg-s3-agent `customServiceDsSecurity: AssumeRole`, S3 agent `S3_DEFAULT_REGION`), pero ningún hook ni plantilla lo cablea; ahora mismo **todo va por access key estática**, sin IRSA [CÓDIGO / VERIFICADO en el zip].

---

## (d) Prerrequisitos AWS del modo S3

### d.1 Qué es el stack `<cluster>-requisites` [CÓDIGO]
Es la plantilla de **marketplace** `Stratio/aws-clusters-automation`, fichero `cloudformation/automations/scripts/cloudformation/template.yaml` (checkout local limpio en `/stratio/aws/aws-clusters-automation`, rama `task/plt-4463`; también en `/stratio/l/`), desplegada por `create-aws-reqs.sh` con `aws cloudformation deploy --stack-name ${CLUSTER_NAME}-requisites`. No existe en este clúster [VERIFICADO: solo hay el stack `cluster-api-provider-aws-sigs-k8s-io`] y la skill `legacy-eks-cluster` no lo crea.
Qué crea (relevante): `InternalS3Bucket` (versionado), `S3StratioAppsIAMUser` (política: `s3:ListAllMyBuckets` en `*`, `s3:*` en el bucket, Deny de acciones no-S3), `S3StratioAppsIAMUserAccessKey`, `S3StratioAppsSecret` (Secrets Manager, JSON `ACCESS_KEY`/`SECRET_KEY`, nombre = usuario). Parámetros: `InternalS3BucketName` (`${CLUSTER_NAME}${PRODUCT_CODE:+-$PRODUCT_CODE}`), `InternalS3BucketUser` (`${CLUSTER_NAME}-s3`). Outputs leídos por apps-layer: `S3StratioAppsSecretArn` (S3) y `BedrockStratioAppsIAMUserSecretArn` (Bedrock). El resto (Flux KMS+rol, aws-metering, SNS alertmanager, SES, Bedrock user, VPC endpoints S3/DynamoDB, buckets Loki `-logs` y Thanos `-metrics` con roles IRSA) es de GitOps/marketplace y **no lo necesita apps-layer**; además requiere parámetros de marketplace (metering role, SNS topic, OIDC id).

Recomendación: **plantilla mínima propia** (`caso-uso-s3/requisites-s3.cfn.yaml`: bucket + usuario + access key + secreto + los outputs `InternalS3BucketName`/`S3StratioAppsSecretArn`; añade cifrado SSE-S3, bloqueo de acceso público y `DeletionPolicy: Retain`) y pasar las claves por `.env`, **no** por el stack, por las dos trampas de (c).

Actualización posterior: la plantilla del kit admite, **opcional y desactivado por defecto** (`ENABLE_BACKUPS_BUCKET`), el bucket de backups de la plataforma (`BackupsS3Bucket`, `BackupsS3IAMUser` con política `s3-backups`, `BackupsS3IAMUserAccessKey`, `BackupsS3Secret` y los outputs `BackupsS3BucketName`/`BackupsS3BucketUser`/`BackupsS3SecretArn` de la referencia). Lo necesita la migración a GitOps, no apps-layer (README, "Bucket de backups opcional").

### d.2 Buckets necesarios

| Bucket | Para qué | Nombre propuesto | Permisos | Estado en la cuenta |
|---|---|---|---|---|
| Interno de datos | warehouse del virtualizer (`/data`), base path de rocket, agente `dg-s3-agent`, datos de prueba | `igualdad-dgutierrez-internal-821111360971` (patrón del Velero; el nombre de marketplace sería `igualdad-dgutierrez`) | usuario IAM `igualdad-dgutierrez-s3`: `s3:*` sobre bucket y objetos; acceso por access key | **Falta** [VERIFICADO: solo existe `igualdad-dgutierrez-velero-821111360971`] |
| Backups Velero | solo `enviroment-ready --backups` (no se lanza) | `igualdad-dgutierrez-velero-821111360971` | rol IRSA `igualdad-dgutierrez-velero` | Existe; apps-layer no lo usa |
| hive/warehouse, rocket, intelligence, discovery, backups propios | **no hay buckets separados en apps-layer** | — | — | No aplica |
| Loki/Thanos (`-logs`, `-metrics`) | los crea la plantilla de marketplace para keos observabilidad | — | IRSA | Fuera de alcance; no se ha comprobado cómo está configurado en este clúster |

Credenciales: access key estática (única vía soportada), guardada en Vault `userland/passwords/<app>.<ns>/s3-secret` y en la configuración de los conectores. Usuarios IAM existentes ahora: solo `cloud-provisioner` (con `AdministratorAccess`, simulación [VERIFICADO]: puede `iam:CreateUser`, `iam:CreateAccessKey`, `s3:CreateBucket`, `secretsmanager:CreateSecret`, `cloudformation:CreateStack`) — ver comandos. Roles IRSA existentes: `igualdad-dgutierrez-external-dns`, `-velero`, `-iam-service-role` [VERIFICADO]. No hay VPC endpoint de S3 (el tráfico irá por NAT) [VERIFICADO].

### d.3 Comandos que PROPONGO (no ejecutados)

```bash
export AWS_PROFILE=cloud-provisioner AWS_PAGER="" AWS_REGION=eu-west-1
export CLUSTER_NAME=igualdad-dgutierrez AWS_ACCOUNT_ID=821111360971
export S3_BUCKET_NAME="${CLUSTER_NAME}-internal-${AWS_ACCOUNT_ID}"
export S3_IAM_USER="${CLUSTER_NAME}-s3"
CFN=/tmp/claude-1001/-stratio-e-igualdad/599c1d8f-bc2e-42c2-a977-8ed555703659/scratchpad/caso-uso-s3/requisites-s3.cfn.yaml

# 1) Pre-chequeo: el bucket no debe existir (el nombre es global)
aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>&1 | head -2      # esperado: 404/403 Not Found

# 2) Opcion A (recomendada): stack minimo
aws cloudformation deploy --stack-name "${CLUSTER_NAME}-s3-requisites" --template-file "$CFN" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ClusterName="$CLUSTER_NAME" InternalS3BucketName="$S3_BUCKET_NAME" InternalS3BucketUser="$S3_IAM_USER"
aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-s3-requisites" --query "Stacks[0].Outputs" --output table

# 3) Claves al .env SIN imprimirlas (umask 077; no usar "set -x")
SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-s3-requisites" \
  --query "Stacks[0].Outputs[?OutputKey=='S3StratioAppsSecretArn'].OutputValue" --output text)
( umask 077; aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text \
  | jq -r '"export S3_BUCKET_ACCESS_KEY=\(.ACCESS_KEY)","export S3_BUCKET_SECRET_KEY=\(.SECRET_KEY)"' \
  >> /tmp/apps-layer-igualdad-dgutierrez/.env )
chmod 600 /tmp/apps-layer-igualdad-dgutierrez/.env
grep -c '^export S3_BUCKET_' /tmp/apps-layer-igualdad-dgutierrez/.env       # esperado: 2 (solo cuenta, no muestra valores)

# 2') Opcion B (sin CloudFormation), equivalente
aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$S3_BUCKET_NAME" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws iam create-user --user-name "$S3_IAM_USER"
aws iam put-user-policy --user-name "$S3_IAM_USER" --policy-name s3-stratio-apps --policy-document "{
 \"Version\":\"2012-10-17\",\"Statement\":[
  {\"Effect\":\"Allow\",\"Action\":\"s3:ListAllMyBuckets\",\"Resource\":\"*\"},
  {\"Effect\":\"Allow\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::${S3_BUCKET_NAME}\",\"arn:aws:s3:::${S3_BUCKET_NAME}/*\"]}]}"
( umask 077; aws iam create-access-key --user-name "$S3_IAM_USER" --output json \
  | jq -r '"export S3_BUCKET_ACCESS_KEY=\(.AccessKey.AccessKeyId)","export S3_BUCKET_SECRET_KEY=\(.AccessKey.SecretAccessKey)"' \
  >> /tmp/apps-layer-igualdad-dgutierrez/.env )

# 4) Opcional: endpoint S3 de tipo gateway (evita NAT para el trafico a S3; sin coste)
VPC_ID=vpc-0a075e6de1228ae1d      # [VERIFICADO] tag Name=igualdad-dgutierrez
RTB=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID --query "RouteTables[].RouteTableId" --output text)
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.${AWS_REGION}.s3 --route-table-ids $RTB

# 5) Validacion de las claves y el bucket (desde el contenedor, tras "source /apps-layer/.env")
env -u AWS_PROFILE aws s3api head-bucket --bucket "$S3_BUCKET_NAME" && echo bucket-ok
```
Teardown: la skill `legacy-eks-cluster` no conoce este stack/bucket/usuario. Para borrar: vaciar el bucket versionado (objetos y delete markers), `aws cloudformation delete-stack` (el bucket tiene `Retain`, borrarlo aparte) y limpiar `.env`.

---

## (e) Qué adaptar para `igualdad-dgutierrez`

| Aspecto | Lab (eosdev) | AWS (`igualdad-dgutierrez`) | Acción |
|---|---|---|---|
| Tenant | `stratio` | `dev` | grupos `dev-stratio-owners`; `INTELLIGENCE_ADMIN_USERS` `admin,dev-user` (pit crea `${TENANT_NAME}-user`); ns `dev-apps/-datastores/-rocket/-genai/-intelligence/-dlc` [CÓDIGO] |
| Clúster/dominio | `CLUSTER_NAME admin`, `k8s.eosdev.labs.stratio.com` | `admin` + `igualdad-dgutierrez.desa.int` [VERIFICADO] | quitar ambos del YAML (se recalculan) |
| Workspace | `/tmp/narnia` | `/stratio/e/igualdad` (mount en `/workspace`) | ya en `.env` y YAML |
| Registry | `qa.int.stratio.com:11443`, helm `helm-15.1-devel` | ECR `717279725338.dkr.ecr.eu-west-1.amazonaws.com` con pull-through, helm `oci://.../helm-15.1` [VERIFICADO en keos.yaml] | nada en YAML; las imágenes de apps las resuelve CCT con ese registry: **no verificado** (no se pueden listar las reglas de PTC de la cuenta 717279725338: AccessDenied) |
| keos-installer | `1.4.3-rc.5` en el contenedor del lab (docker ps) / `.env` 1.4.2 | 1.4.2 (anotación del objeto `keos`) [VERIFICADO] | omitir `KEOS_INSTALLER_VERSION` |
| StorageClass | `local-path` / NFS | `keos` (EBS gp, default, RWO, `WaitForFirstConsumer`, 3 AZ), `gp2`, `efs-igualdad-dgutierrez` (RWX) [VERIFICADO] | las apps usan la default (EBS). Intelligence trae PVC `keos` pero los volúmenes están desactivados por defecto. Con EBS cada pod con PVC queda atado a su AZ |
| LoadBalancer | MetalLB | AWS (NLB/ELB) | `VIRTUALIZER_CREATE_LOADBALANCER: true` crearía un Service LoadBalancer en AWS (¿público?). Propongo `false` hasta decidir |
| DNS/TLS | DNS del lab | zonas Route53 pública y privada + external-dns [VERIFICADO]; `desa.int` no delega, no resuelve desde la estación | el contenedor ya lleva `--add-host admin.igualdad-dgutierrez.desa.int:<IP>` [VERIFICADO con docker inspect]. Los hosts `*.dev.<dominio>` del YAML necesitan registro (external-dns) y certificado que cubra `*.dev.` [SUPOSICIÓN: no verificado] |
| Tamaño | `S` | `S` (sizes/S existen; otro valor rompe las plantillas; tras la sincronización con la PR 220 el kit admite además `CUSTOM` con overlay propio, ver README) | igual |
| Capacidad | VMs del lab | 3 x m6a.4xlarge, 15,89 vCPU y ~60 GiB asignables cada una; uso actual 3-5 % CPU, 13-16 % memoria [VERIFICADO] | suma de requests en tamaño S del caso de uso ~50 GB de memoria y pocos CPU sin réplicas [cálculo mío sobre `sizes/S`]; quitar hdfs y `connector-dfs-hdfs` ahorra 4 CPU/4 GB + datanodes |
| Egress | lab | NAT: `PHONETIC_PLUGIN_OFFLINE false` descarga el plugin; OpenAI API si se usa `LLM_TOKEN` | OK si hay salida a internet [SUPOSICIÓN] |
| LDAP/Kerberos | del lab | `keos-idp` con `ldap-idp-0/1` y `kerberos-idp` Running [VERIFICADO]; `pit` crea usuarios en LDAP | nada |
| NTP, IPs de lab, `nfs-pds` | en `keos.yaml` del lab | no aplican; `pds` (usa NFS) no está en el caso de uso | nada |
| Tenant `dev` | — | no existe aún (`kubectl get tenant` solo `keos`) [VERIFICADO] | lo crea `create-tenant.sh` |
| `LLM_TOKEN` | en claro en 3 YAML del checkout | — | pasar por `.env` (no al YAML) o usar Bedrock; **rotar** si esos ficheros se han subido/commiteado |

---

## (f) Ficheros a crear en `/tmp/apps-layer-igualdad-dgutierrez/` y cómo se monta

Estado real del contenedor del usuario [VERIFICADO, `docker inspect`, solo mounts]: `adoring_raman`, `--net host`, `--add-host admin.igualdad-dgutierrez.desa.int:52.48.115.190`, mounts: `/stratio/e/igualdad/apps-layer -> /apps-layer`, `/stratio/e/igualdad -> /workspace`, `/tmp/apps-layer-igualdad-dgutierrez/aws -> /root/.aws (ro)`, `docker.sock`. Existe también `keos-installer_igualdad-dgutierrez` (1.4.2). `.env` actual: `DOCKER_DIND_ENABLED=false`, `KEOS_WORKSPACE_DIR=/stratio/e/igualdad`, `KEOS_INSTALLER_EXTRA_ARGS="--net host"`. El `igualdad-dgutierrez.yaml` actual es el de la PR 220 (HDFS, sin los servicios del caso de uso).

| Fichero (host `/tmp/apps-layer-igualdad-dgutierrez/`) | Acción | Borrador |
|---|---|---|
| `igualdad-dgutierrez.yaml` | **reemplazar** por el YAML raíz (guardar antes `cp igualdad-dgutierrez.yaml igualdad-dgutierrez.pr220-hdfs.yaml`) | `caso-uso-s3/igualdad-dgutierrez.yaml` |
| `igualdad-dgutierrez-dev.yaml` | crear (tenant `dev`, S3) | `caso-uso-s3/igualdad-dgutierrez-dev.yaml` |
| `.env` | **añadir** `AWS_REGION=eu-west-1` y las dos claves S3 (comando d.3.3), opcional `LLM_TOKEN`; `chmod 600` | `caso-uso-s3/dot-env.example` |
| `apps/*`, parches | **ninguno** | — |

- **Sin reiniciar el contenedor**: en su shell, `source /apps-layer/.env` (el entrypoint cargó el `.env` antiguo) y ejecutar `cd /apps-layer && apps-installer <fichero>`. Si se reinicia el contenedor el `.env` se vuelve a cargar solo.
- `prepare.sh` se ejecuta **en el host** (hace `docker run` con rutas de host, toca `~/.kube/config`, `/tmp/config` y usa `sudo`). No usarlo tal cual aquí (a.1). Si se quiere conservarlo para este clúster, haría falta parametrizar `CONFIG_DIR`, `WORKSPACE_DIR`, `KUBECONFIG_SRC`, nombre de contenedor, `-v ~/.aws`, `--add-host`, no tocar `~/.kube/config` y no hacer `docker rm -f keos-installer_<env>`. Propongo guardar los dos YAML en el repo como `igualdad-dgutierrez/{igualdad-dgutierrez,extensions}.yaml` junto a `eosdev/` y `three/`.
- Si más adelante hiciera falta parchear una app: copiar a `/apps-layer/overlay/apps/<app>/` y en el contenedor `cp -r /apps-layer/overlay/apps/<app>/. /apps-layer-automation/apps/<app>/` antes de lanzar (sin reinicio, se pierde al reiniciar), o `-v` al relanzar. Partir siempre de `branch-15.1-0.1`, no de `master`.
- Reutilizable tal cual: imagen `15.1-0.1.0-SNAPSHOT` (el SNAPSHOT es mutable; se puede fijar por digest), universo 15.1.0 embebido, `.env`, `kube-config`, mount de `aws`, `--add-host`, YAML raíz casi idéntico.

---

## (g) Secuencia con validaciones

0. **Estado previo** (host, `AWS_PROFILE=cloud-provisioner`, `KUBECONFIG=/stratio/e/igualdad/1-aws-cluster/estado/kubeconfig-igualdad-dgutierrez`): `kubectl get pods -A --no-headers | awk '$4!="Running"&&$4!="Completed"'` vacío; `kubectl get tenant keos`; `docker ps | grep keos-installer_igualdad-dgutierrez`.
1. **AWS S3** (d.3): stack mínimo, claves a `.env`, `head-bucket` OK. Validar: stack `CREATE_COMPLETE`, `grep -c '^export S3_BUCKET_' .env` = 2.
2. **Ficheros** en `/tmp/apps-layer-igualdad-dgutierrez/` (f). Validar YAML en el contenedor: `yq '.tenants[].name' igualdad-dgutierrez-dev.yaml` -> `dev`.
3. **Contenedor**: `source /apps-layer/.env`; comprobar solo nombres: `env | cut -d= -f1 | grep -E '^(S3_BUCKET|AWS_REGION)'` (3 líneas). `env -u AWS_PROFILE aws s3api head-bucket --bucket igualdad-dgutierrez-internal-821111360971`. Nota: el YAML de dev lleva `S3_BUCKET_NAME`; en el shell no hace falta.
4. **Raíz**: `cd /apps-layer && apps-installer igualdad-dgutierrez.yaml`. Validar: `kubectl -n keos-core get deploy | grep -E 'dg-|governance|se-|opensearch'` y que cada app esté `success/ready` en CCT.
5. **Tenant dev**: `apps-installer igualdad-dgutierrez-dev.yaml` y vigilar en 3 puntos de control:
   - Tras la tanda 1 (connectors-management): `kubectl -n dev-apps exec <pod-connectors> -- curl -s "http://connectors-management.dev-apps/v1/api/connector/findByName?name=sscc-s3"` debe devolver artefacto con `scalaVersion 2.12`. **Si viene vacío, parar**: virtualizer/rocket/eureka/connector-s3 no funcionarán (ver riesgos).
   - Tras virtualizer y rocket: `kubectl -n dev-rocket get cm s3-config`; `kubectl get pods -n dev-apps -n dev-rocket`; `vault`: no imprimir valores.
   - Tras `connector-s3`, discovery e intelligence: pods Running; en el log de cada pre-install debe verse la rama S3 (no `HDFS_GOSEC_VERSION`).
6. **Prueba funcional**: subir un CSV al bucket y seguir el escenario de la skill `stratio:e2e-talk-to-your-data` (variante S3) o crear una tabla técnica desde `dg-s3-agent`.
7. **Reintentos**: repetir `apps-installer` es seguro; para acotar, copiar el YAML dejando solo las apps pendientes.
8. **Higiene**: apps-layer deja en `/stratio/e/igualdad/` (workspace) `admin.key`, `admin.cert`, `*-tenant.yaml`, `apps/...json`; no subir a git, borrar la clave al terminar.

---

## (h) Riesgos, incógnitas y decisiones del usuario (preguntas concretas)

Riesgos [mayor a menor]:
1. **`connectors-loader` (2.2.0 fijado por defecto como la PR; 2.2.3 en el `.lst` fresco si la variable queda vacía) y `sscc-s3`**: las 4 apps S3 dependen de `findByName?name=sscc-s3` (scala 2.12). No he podido comprobar el contenido del loader. Los jars de `apps/nginx-connectors` sugieren que antes hubo que servir el conector S3 a mano. Si falta, habría que subirlo al connectors-management.
2. **Silencio ante claves ausentes**: sin `S3_BUCKET_ACCESS_KEY/SECRET_KEY` en el entorno, las apps vuelven a HDFS y fallan lejos del origen; `connector-s3` escribe vacío en Vault. Validar el paso 3 antes de lanzar.
3. **Nombre del stack**: la ruta CFN de apps-layer buscaría `admin-requisites` (CLUSTER_NAME=admin) y `AWS_REGION` no está definido. Por eso se inyectan las claves por `.env`.
4. **Secretos**: `LLM_TOKEN` en claro en `eosdev/extensions.yaml`, `three/extensions.yaml`, `eosdev/micro.yaml`; las claves S3 van a `.env` (600) y a Vault; el workspace acumula `admin.key`.
5. **Imágenes de apps**: ECR pull-through para `stratio-releases.repo.stratio.com` no verificado (heredado del informe previo).
6. **DNS/TLS de `*.dev.igualdad-dgutierrez.desa.int`** (hosts por tenant del YAML) y `desa.int` no delegado.
7. **SNAPSHOT mutable** de la imagen; **`trap EXIT`** hace `helm rollback cct` al salir.
8. **Credencial S3 global**: cualquier usuario de Rocket/Virtualizer accede a todo el bucket; no hay políticas gosec de S3 (por diseño de apps-layer).
9. **pit**: sin rama S3; el `HDFS_USAGE_POLICY_POLICY_ENABLED=false` es mi deducción del código, no probada.
10. `cct-orchestrator` sube a 10Gi y los nodos tienen holgura [VERIFICADO].

Preguntas:
1. ¿Nombre del bucket? Propuesta `igualdad-dgutierrez-internal-821111360971` (global único; marketplace usaría `igualdad-dgutierrez`).
2. ¿Aceptas access key estática (lo único que cablea apps-layer) o prefieres rol asumido/IRSA (obliga a parchear plantillas/descriptores)?
3. ¿Stack CFN mínimo propio (mi propuesta) o plantilla completa de marketplace (exige VPC id, route tables, OIDC, metering/SNS)?
4. ¿LLM: seguir con OpenAI (`LLM_TOKEN` por `.env`) o Bedrock (añade usuario IAM con `AmazonBedrockFullAccess`, `BEDROCK_AWS_REGION`, `BEDROCK_INFERENCE_PROFILE_ID`)? ¿Hay que rotar el token en claro?
5. ¿Hosts por tenant (`genai/rocket/discovery/virtualizer/dlc*.dev.<dominio>`) o hosts por defecto (`admin.<dominio>` + path)? Los primeros exigen DNS y certificado comodín.
6. ¿`VIRTUALIZER_CREATE_LOADBALANCER` true (ELB en AWS) o false?
7. ¿Se mantiene todo lo no-HDFS del caso (kafka, opensearch1-dashboards, dlc-entity x2, datamarket-agent, genai-*, pit)? ¿Y el stack se-* + datamarket en `keos`, o el gobierno mínimo de la PR 220 (`GOVERNANCE_UI_ENABLE_SEARCHER=false`)?
8. ¿Un solo YAML con los dos tenants (como la PR) o los dos ficheros (como en el lab)? Dejé dos.
9. ¿Endpoint de VPC de S3 (gratis, evita NAT)?
10. ¿Los jars de `apps/nginx-connectors` siguen siendo necesarios o son restos?
11. ¿Dónde versionar los YAML (`igualdad-dgutierrez/` en el repo)? El checkout está en `master`, no en `branch-15.1-0.1`.

---

## (i) Qué no he podido verificar

- Ninguna ejecución real de `apps-installer` ni de los hooks S3 de punta a punta.
- Que el connectors-loader usado (2.2.0 por defecto; 2.2.3 con `CONNECTORS_LOADER_VERSION` vacía) contenga `sscc-s3` y que el jar funcione con el endpoint S3 por defecto desde eu-west-1 (el agente S3 admite `S3_DEFAULT_REGION`; rocket/virtualizer no lo exponen).
- Que `S3_BUCKET_NAME`/claves se propaguen a los 5 hooks en la práctica (lectura de código: el `.env` se hereda por los subshells; el env de tenant se exporta sin comillas, válido para las claves con `/` y `+`, pero van por `.env`).
- Pull-through cache de ECR, certificados y DNS de los hosts `*.dev.`, y que el egress permita descargar el plugin fonético.
- El comportamiento real de `pit` y `discovery` sin HDFS, y el acceso S3 desde Intelligence/notebooks.
- Si el perfil `cloud-provisioner` existe dentro de `/apps-layer/aws` (no leído por instrucción). Con las claves por `.env` ya no hace falta para S3.
- `aws cloudformation deploy` de la plantilla mínima: solo `validate-template` (parámetros `ClusterName`, `InternalS3BucketName`, `InternalS3BucketUser` reconocidos).
- Estado de Loki/Thanos y de las buckets de keos observabilidad en este clúster.
