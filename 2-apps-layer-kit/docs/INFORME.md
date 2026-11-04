# apps-layer-automation sobre `igualdad-dgutierrez`: informe operativo

> **Nota (reorganización del workspace):** este documento es un **análisis previo** (2026-10-27), anterior a la reorganización de
> `/stratio/e/igualdad/` y a la creación de `2-apps-layer-kit`. Las rutas operativas se han actualizado: el kit está en
> `2-apps-layer-kit/`, el kubeconfig en `1-aws-cluster/estado/`, y el directorio de ejecución de apps-layer es ahora efímero:
> `/tmp/apps-layer-<cluster>` (700). Para ejecutar, usa `../README.md` (kit) y no los comandos manuales de este análisis.
> Las menciones históricas (qué se tocó o no durante la investigación) se conservan tal cual.

Fecha: 2026-10-27. Tarea de solo lectura: no se ha modificado nada en AWS, en el clúster ni en `/stratio/e/igualdad/`.

Leyenda de procedencia usada en todo el informe:

- **[CÓDIGO]**: leído en el repo `Stratio/apps-layer-automation`, rama `branch-15.1-0.1` (HEAD `8ca2450`, 2026-10-23), o en sus docs.
- **[PR]**: viene de la guía `instalacion-cliente-legacy.md` de la PR 220 (HEAD `2d36d7d` el 2026-10-29; el análisis original se hizo sobre `f36fe83`), no del proyecto.
- **[VERIFICADO]**: lo he comprobado yo, solo lectura, contra el clúster, la imagen local o el registry.
- **[SUPOSICIÓN]**: deducción mía, no probada.

---

## 0. Parte A (resumen): cambios nuevos de la PR 220

HEAD de la PR **en el momento de este análisis** (2026-10-27): `f36fe83a176c7da96d90549d88b21901df0c253b` (hoy, 2026-10-29, es `2d36d7d`: ver `../README.md` y la guía del workspace). La última versión revisada entonces era `a95c453`. Había 5 commits nuevos, todos del 2026-10-27:

| sha | hora UTC | mensaje |
|---|---|---|
| ed67b05 | 09:43 | `instalacion-cliente-legacy.md`: deploy apps with apps-layer-automation (nueva sección 7) |
| 0c0dbca | 10:25 | `instalacion-cliente-legacy.md`: apps-layer deploy file matches the customer's apps |
| 798923f | 10:27 | `igualdad-keos-desa`: enable governance ontology-graph-api and map (en `default/resourcesetinputproviders.yaml`, +8 líneas) |
| ed79d16 | 10:33 | `instalacion-cliente-legacy.md`: apps-layer dir inside the keos workspace |
| f36fe83 | 10:50 | `instalacion-cliente-legacy.md`: download and mount the universe descriptors zip |

Ficheros tocados: `clusters/igualdad-keos-desa/instalacion-cliente-legacy.md` (+170/-1) y `clusters/igualdad-keos-desa/default/resourcesetinputproviders.yaml` (+8).

Diff completo guardado en `/tmp/claude-1001/-stratio-e-igualdad/599c1d8f-bc2e-42c2-a977-8ed555703659/scratchpad/legacy-diff2.patch`. La versión nueva está en `/tmp/claude-1001/-stratio-e-igualdad/599c1d8f-bc2e-42c2-a977-8ed555703659/scratchpad/legacy-latest2.md`.

Cambios funcionales:

1. La guía legacy gana una **sección 7 nueva, "Despliegue de las aplicaciones con apps-layer-automation"**, y la antigua 7 (eliminación de recursos AWS) pasa a ser la 8. Las secciones 1 a 6 no cambian (el diff solo añade a partir de la línea 535).
2. En la sección 7 aparecen: directorio `apps-layer` dentro del workspace, kubeconfig con `aws eks update-kubeconfig`, `.env` con `DOCKER_DIND_ENABLED=false`, descarga del zip de descriptores 15.1.0 del Nexus de QA, fichero `igualdad.yaml` y comando `docker run` + `apps-installer igualdad.yaml`.
3. `igualdad.yaml` tiene dos tenants.
   - `keos`: gobierno del cliente en `keos-core`, sin searcher, sin datamarket y con `GOVERNANCE_UI_ENABLE_SEARCHER: "false"`.
   - `dev`: postgres `pg-meta` y `pg-data`, hdfs, connectors, virtualizer, discovery, dg-datarest-pgi, eureka-agent, `connector-dfs-hdfs`, rocket e intelligence. Los nombres y namespaces son los del cliente (`dev-apps`, `dev-datastores`, `dev-rocket`, `dev-intelligence`).
4. `798923f` solo afecta a la variante **GitOps** de `igualdad-keos-desa` (RSIP): activa `governance.config.ontologyGraphApi` y `map`.
5. Fuera de ese `.md` y del RSIP, nada más en `clusters/igualdad-keos-desa/` menciona apps-layer-automation. No hay vars.env, sizes ni ficheros propios del cliente en la PR.

Impacto en lo que ya tenemos instalado (`cluster.yaml` con `gitops_enabled: false`, cloud-provisioner 0.9.8, cluster-operator 0.7.4, keos-installer 1.4.2, EFS, Velero y external-dns hechos a mano):

- **Ninguno** sobre lo instalado. No cambia ni `keos.yaml`, ni `override_vars`, ni los prerrequisitos AWS, ni las versiones.
- El cambio del RSIP (`798923f`) no aplica a nuestro clúster porque no usa GitOps.
- La novedad es el siguiente paso: desplegar las apps con apps-layer-automation.
- Divergencias entre la sección 7 de la PR y lo que he verificado (detalle en el apartado 6):
  - **El zip y `universe-images.lst` se descargan SIEMPRE frescos y se montan** (requisito posterior del usuario; esta fila decía antes que no hacía falta). La imagen trae un universo embebido, pero el `.lst` está desfasado (connectors-loader 2.2.0 frente a 2.2.3 en `branch-15.1`). El `.lst` fresco sigue siendo obligatorio (lo usa `intelligence` para `analytic-environment` y `connectors-management` si no hay pin), pero el kit fija por defecto `CONNECTORS_LOADER_VERSION=2.2.0` (como la PR Stratio/keos-fleet#220, probada solo en HDFS), lo que hace que el hook ignore el `.lst` para el loader; vacía la variable en `kit.env` para usar el del `.lst` (2.2.3). Lo hace `scripts/fetch-universe.sh` desde `launch-apps-layer.sh`; ver `README.md`.
  - **`.env` incompleto.** El entrypoint lanza el contenedor keos-installer antes de leer el YAML, así que `KEOS_WORKSPACE_DIR` y `KEOS_INSTALLER_EXTRA_ARGS` deben ir en `.env` o con `-e`.
  - **Tag de imagen.** La PR deja `<versión 15.1>` sin concretar. El único tag 15.1 publicado es `15.1-0.1.0-SNAPSHOT`.
  - **Tamaño del entorno.** La PR dice que cualquier valor distinto de `S` o `PIT` usa los recursos por defecto de los descriptores. Es incorrecto: con otro valor las plantillas quedan con variables vacías y generan JSON inválido.

---

## 1. Resumen del proyecto

### Localización y acceso

- Repo: `github.com/Stratio/apps-layer-automation`, rama por release de producto. Para 15.1 se usa `branch-15.1-0.1` (`gh` tiene acceso; el repo es accesible).
- Checkout local: `/stratio/aws/apps-layer-automation`. Está en `master` y con **cambios locales sin commitear**: `apps/rocket/pre-install.sh` y `apps/dg-datarest-pgi/pre-install.sh` modificados, ficheros de `universe/` borrados, y `eosdev/`, `three/`, `prepare.sh` y `apps/nginx-connectors/` sin seguimiento. Es trabajo vuestro (eosdev, three). **No lo he tocado ni lo he usado como fuente.**
- Fuente que he usado: tarball de `branch-15.1-0.1` descargado con `gh api` a `/tmp/claude-1001/-stratio-e-igualdad/599c1d8f-bc2e-42c2-a977-8ed555703659/scratchpad/aln/`.
- Imagen Docker. [VERIFICADO]
  - `qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT` ya está en local, creada el 2026-10-23.
  - Su digest (`sha256:a745cac6...`) coincide con el del tag en el registry de QA.
  - Se construyó tras el HEAD de la rama (10:28 el commit, 10:31 la imagen).
  - Tags 15.x publicados: `15.0-0.1.0-M1`, `15.0-0.1.0-SNAPSHOT`, `15.1-0.1.0-SNAPSHOT`, `15.1-15.2.0-SNAPSHOT`, `15.2-0.1.0-SNAPSHOT`.
  - Un SNAPSHOT es mutable: conviene fijar el digest.

### Qué hace [CÓDIGO]

Despliega todos los productos Stratio sobre un clúster ya aprovisionado con keos. Es decir, **usa Command Center (CCT, namespace `keos-cct`) y el universo de descriptores**, no Helm ni GitOps. Para cada app renderiza `apps/<app>/<app>.json.tmpl` con `envsubst` y lo envía al `cct-orchestrator` (`POST /v2/install`). Después espera a que el objeto de la app cumpla la condición `APP_CONDITION`.

La imagen es un Alpine con docker, kubectl, helm, jq, yq, aws-cli v2, gcloud y ansible-vault [VERIFICADO: kubectl, helm, jq, yq, aws, envsubst y ansible-vault están en la imagen]. Las `apps/`, `scripts/`, `docs/` y `universe/` van copiadas a `/apps-layer-automation`.

### Cómo se lanza [CÓDIGO]

1. Se arranca el contenedor de la imagen. Su `entrypoint.sh` hace, por este orden:
   1. Lee la versión de keos de la anotación `keos.stratio.com/version` del objeto `keos` y la usa como `KEOS_INSTALLER_VERSION` si no se define.
   2. Carga `/apps-layer/.env` (si existe).
   3. Con `DOCKER_DIND_ENABLED=false` no arranca dockerd y usa el socket del host.
   4. Si `/workspace/keos.yaml` no existe, extrae un workspace del clúster. Si existe, lo usa tal cual.
   5. Obtiene `VAULT_MASTER_KEY` del secret `keos-ops/keos-installer-credentials`.
   6. Lanza **otro contenedor** `keos-installer_<cluster_id>` en detached: `docker run -it -d --rm -e SKIP_CONFIRMATION=true -e VAULT_MASTER_KEY=... -v ${KEOS_WORKSPACE_DIR}:/workspace -v /var/run/docker.sock:/var/run/docker.sock ${KEOS_INSTALLER_EXTRA_ARGS} --name ... --cgroupns host ${KEOS_WORKSPACE_REGISTRY}:${KEOS_INSTALLER_VERSION}`.
   7. Deja una shell bash interactiva.
2. En esa shell (alias en `/root/.bashrc`): `apps-installer <fichero.yaml>`.
   - Lee `.env` globales del YAML.
   - Calcula `CLUSTER_NAME` = `.spec.keos.ingress.admin.subdomain` o `admin`, y `EXT_DOMAIN` = `.spec.keos.external_domain`.
   - Espera a que el contenedor keos-installer esté listo (log "Starting interactive session.").
   - Sube la memoria de `cct-orchestrator` a `CCT_ORCHESTATOR_MEMORY_RESOURCES` (10Gi por defecto). Al salir hace `helm rollback cct <revisión>`.
   - Sube el zip del universo a `cct-universe` si no hay descriptores de esa versión.
   - Por cada tenant: `create-tenant.sh`, luego `assign-gov-roles.sh` (si no es `keos`), luego `deploy-apps.sh`.

### Fichero de despliegue y variables [CÓDIGO]

Estructura:

```
env: {}
tenants:
  - name: <tenant>
    env: {}
    apps:
      - name: <app>
        env: {}
      - parallel: [ {name, env}, ... ]
```

Variables globales documentadas en `docs/quickstart.md`:

| Variable | Obligatoria | Por defecto |
|---|---|---|
| `UNIVERSE_VERSION` | sí | ninguno |
| `UNIVERSE_VERSION_BUGFIX_ENABLED` | no | false |
| `USER_ID`, `USER_NAME` | sí | `admin` |
| `ENVIRONMENT_SIZE` | sí | `S` |
| `KEOS_WORKSPACE_DIR` | no | `/workspace` |
| `KEOS_WORKSPACE_REGISTRY` | no | `qa.int.stratio.com/stratio/keos-installer` |
| `KEOS_INSTALLER_EXTRA_ARGS` | no | vacío |
| `DOCKER_DIND_ENABLED` | no | true |
| `CCT_ORCHESTATOR_MEMORY_RESOURCES` | no | 10Gi |

Variables por app: `apps/<app>/vars.env` define `APP_NAME`, `APP_NAMESPACE_SUFFIX`, `APP_NAMESPACE` (= `<tenant>-<sufijo>`), `APP_OBJECT`, `APP_LABEL`, `APP_CONDITION`, `UNIVERSE_SERVICE`, `UNIVERSE_MODEL`, `DEPENDENCIES_*`, etc., todas con `${VAR:-default}`. Por eso se pueden sobreescribir desde `env:` del tenant o de la app.

Precedencia: global, luego tenant, luego app, y después `vars.env` y `sizes/<tamaño>`. **Matiz (corregido tras revisar `deploy-apps.sh`):** `sizes/<tamaño>` se carga **después** del env y, en las apps cuyo `sizes/S` exporta valores fijos (`export CPU_REQUESTS="0.5"`), **lo pisa**; solo "rellena huecos" en las que usan `${VAR:-defecto}`. La lista de unas y otras está en `../README.md` (sección `ENVIRONMENT_SIZE=CUSTOM`).

Tamaños: `apps/<app>/sizes/S` y `sizes/PIT`. **Solo se cargan para `ENVIRONMENT_SIZE` igual a `S` o `PIT`** (`scripts/deploy-apps.sh`, líneas 67-71). Las plantillas usan `${MEMORY_REQUESTS}` y similares sin valor por defecto. Con otro tamaño no se carga ningún fichero, `envsubst` no valida y esas variables quedan vacías (JSON mal formado). **`CUSTOM` (la usa la guía de la PR en `2d36d7d`) no es un modo soportado upstream**: no existe `sizes/CUSTOM`. Corrección posterior a este análisis: el kit lo soporta con un overlay propio (`templates/sizes-custom.env`, `ENVIRONMENT_SIZE=CUSTOM`) y una salvaguarda que aborta si falta alguna variable (ver `../README.md`); `S`/`PIT` siguen igual.

Orden y dependencias:

- Los elementos de `apps:` se ejecutan en secuencia. Cada `parallel:` lanza sus apps en background con 10 s de separación y espera a todas.
- No hay resolución automática de dependencias: **el orden lo marca el YAML**.
- Si la app ya existe en CCT con `status == success` y `health == ready`, se **salta** el despliegue. Por tanto es reintentable.
- Cada app, en este orden:
  1. Carga vars.
  2. Crea el namespace (`kubectl --as admin --as-group <tenant>-stratio-owners create ns`) y, si el tenant no es `keos`, espera a la NetworkPolicy `allow-all-<ns>`.
  3. Ejecuta `pre-install.sh`.
  4. Renderiza el `.json.tmpl`, lo sube al orquestador, lo despliega y espera la condición (timeout 10 min).
  5. Ejecuta `post-deploy.sh`.
  6. Aplica las `gosec-policies/*.json`.
  7. Ejecuta `post-install.sh`.
- Los hooks usan `execKeos "play ..."`, que ejecuta playbooks dentro del contenedor `keos-installer_<cluster_id>`, y `execVault`, que escribe en Vault.

Apps disponibles en `apps/`: 66 directorios (ver `ls apps`). Las que usa Igualdad según la PR existen todas, incluida `connector-dfs-hdfs`.

Otras utilidades [CÓDIGO]: `enviroment-ready` (reporters, backups con Velero, monitorización con Thanos), `apps-upgrader` (TUI), `update-monitoring`. **No son necesarias** para esta instalación.

### S3 interno frente a HDFS [CÓDIGO]

Varios hooks (`rocket`, `virtualizer`, `discovery`, `intelligence`, `eureka-agent`) llaman a `isInternalS3Enabled`.

- Si `S3_BUCKET_NAME` está definido, se leen las credenciales del stack CloudFormation `<cluster>-requisites` con el perfil `cloud-provisioner`, y se usa S3 en lugar de HDFS.
- Si **no** está definido, usan HDFS.

El YAML de la PR (con hdfs) no define `S3_BUCKET_NAME`, así que **no necesita** ese stack ni credenciales S3. No definirlo.

**Errata `INTI_PATH` en connector-s3 [CÓDIGO]**: `apps/connector-s3/vars.env` (apps-layer-automation `branch-15.1-0.1`) exporta `INTI_PATH` en vez de `INIT_PATH`; `connector-s3.json.tmpl` (`"customInitPath": "${INIT_PATH}"`) se renderiza vacío y `dg-s3-agent` crashea con `Missing environment variable: COMM_SERVICE_INIT_PATH` (el descriptor lo exige, sin default). El kit lo fija en el env de `connector-s3` del tenant con `INIT_PATH: ${S3_INIT_PATH}` (def. `/<S3_BUCKET_NAME>`; también valen `/<bucket>/<prefijo>`); `check-apps-layer.sh` marca KO si falta, está vacío o vale exactamente `/`. **[VERIFICADO en vivo]** el valor óptimo ya no es incógnita: con `COMM_SERVICE_INIT_PATH=/<bucket>` el agente `dg-s3-agent` (`dg-custom-agent_2.12:1.2.0`, `sscc-s3 1.5.1`) arranca (1/1 Running) y conecta con S3 (la descubierta solo se queja de bucket vacío); la raíz `/` NO sirve (`UnsupportedRootInitPath: Custom driver does not support '/' as init-path`), por lo que el kit la rechaza.

---

## 2. Prerrequisitos y estado real del clúster

Comprobados solo lectura contra `igualdad-dgutierrez` (kubeconfig `/stratio/e/igualdad/1-aws-cluster/estado/kubeconfig-igualdad-dgutierrez`, `AWS_PROFILE=cloud-provisioner`):

| Requisito de apps-layer | Estado | Origen |
|---|---|---|
| Objeto `keos/keos-ops` con anotación de versión | `1.4.2` | [VERIFICADO] |
| `cluster_id` | `igualdad-dgutierrez` | [VERIFICADO] |
| `external_domain` | `igualdad-dgutierrez.desa.int` | [VERIFICADO] |
| `ingress.admin.subdomain` | `null`, así que `CLUSTER_NAME=admin` y el host es `admin.igualdad-dgutierrez.desa.int` | [VERIFICADO] |
| Namespace `keos-cct` con orquestador, universe, query, central-config y paas-services | todo Running | [VERIFICADO] |
| Release Helm `cct` en `keos-cct` | `cct-3.0.26`, revisión 1, deployed (el trap de rollback lo necesita) | [VERIFICADO] |
| `cct-orchestrator` | requests/limits memoria 3Gi (se parchea a 10Gi, los nodos tienen unos 61 GiB asignables cada uno) | [VERIFICADO] |
| Capsule (`capsule-controller-manager`) | chart `capsule-1.0.0`, API `v1beta2` | [VERIFICADO] |
| SIS (`keos-auth/sis`) | chart `sis-3.0.8` | [VERIFICADO] |
| Tenant `keos` | Active, READY, reconciled | [VERIFICADO] |
| Postgres de keos (`postgreskeos`) | 3/3 OK | [VERIFICADO] |
| gosec-*, tenant-operator, vault, kyverno | Running | [VERIFICADO] |
| Pods no Running/Completed en todo el clúster | ninguno | [VERIFICADO] |
| Secret `keos-ops/keos-installer-credentials` con `vault-master-key` | existe | [VERIFICADO] |
| `ansible-vault view /stratio/e/igualdad/secrets.yml` con esa clave | funciona; `.secrets.keos.admin` tiene usuario `admin` y su contraseña (no impresa) | [VERIFICADO] |
| kubeconfig dentro de la imagen con `~/.aws` en solo lectura | `kubectl get keos`, `helm history` y demás funcionan | [VERIFICADO] |
| StorageClasses | `keos` (default, EBS gp), `gp2`, `efs-igualdad-dgutierrez` | [VERIFICADO] |
| Nodos | 3 x m6a.4xlarge (16 vCPU y 64 GiB), 15,9 vCPU asignables cada uno | [VERIFICADO] |
| Zonas Route53 `igualdad-dgutierrez.desa.int` | pública `Z02917533RWGFYFALT83D` y privada `Z00533042CTBKN4ZVTA4E`, con A/AAAA de `admin` y `sis` | [VERIFICADO] |

Bloqueos y avisos previos:

1. **Esperar a que acabe `keos install`.** Sigue arrancado el contenedor `dreamy_haslett` (keos-installer 1.4.2). Comprobar su log o `docker ps`. apps-layer lanza su propio contenedor `keos-installer_igualdad-dgutierrez` sobre el **mismo workspace**, y no conviene que los dos escriban a la vez. [SUPOSICIÓN: en la práctica el clúster ya parece completo, pero no lo he confirmado]
2. **DNS de `admin.igualdad-dgutierrez.desa.int`.** No resuelve desde esta estación (`getent hosts` sin resultado). `desa.int` no delega a esas zonas, y la privada solo resuelve dentro de la VPC. [VERIFICADO]
   - Impacto [CÓDIGO]: `assign-gov-roles.sh` (se ejecuta para el tenant `dev`) llama a `createUserCert`, que hace `curl https://admin.<EXT_DOMAIN>/gosec/baas/management/account/export/certificate...` desde el contenedor. Si no resuelve, ese paso falla y `apps-installer` marca `PHASE="assigning governance roles in tenant dev"`.
   - Solución sin sudo: `--add-host admin.igualdad-dgutierrez.desa.int:<IP>` en el `docker run`. [VERIFICADO: `--add-host` funciona junto con `--net host` en esta imagen]. La IP es la de una de las IPs del NLB externo (`aef41434cc93d4839b4e1e0f880d87d7-edff3916aae1d657.elb.eu-west-1.amazonaws.com`, las IPs cambian). [SUPOSICIÓN: la IP es la del NLB; el controlador ingress es el `ingress-nginx-controller` de `keos-ingress`]
   - Alternativa: entrada en `/etc/hosts` (necesita sudo).
   - Si `ingress_external_access_cidrs: ["0.0.0.0/0"]` no abre desde vuestra red (el SG del NLB), usar el NLB interno, solo alcanzable desde la VPC. [SUPOSICIÓN]
3. **Acceso a `qa.int.stratio.com`** (VPN): comprobado, responde (el Nexus y el registry). [VERIFICADO]
4. **Registry de las imágenes de las apps.** [SUPOSICIÓN / INCÓGNITA] Las imágenes de aplicaciones salen de `stratio-releases.repo.stratio.com` (107 de las 216 de `universe/15.1.0-universe-images.lst`). Que se reescriban al ECR `717279725338...` con prefijo de pull-through cache depende de CCT y de `ecr_pull_through_cache_enabled: true`. No lo he podido comprobar: tampoco he comprobado que exista una regla de pull-through cache para `stratio-releases.repo.stratio.com` en la cuenta 717279725338. Si algún pod queda en `ImagePullBackOff`, empezar por ahí.

---

## 3. Qué crear y con qué contenido para `igualdad-dgutierrez`

El proyecto **no tiene** ficheros ni ramas por cliente: grep de "igualdad" en `branch-15.1-0.1`, `branch-15.0-0.1` y `master` no da nada. Un "entorno" es solo un YAML de despliegue (ejemplos en `docs/examples/`, no hay uno de Igualdad) más un directorio `apps-layer` que se monta. El único antecedente de Igualdad es el YAML de la sección 7.2 de la PR.

Ficheros propuestos ya preparados (no están en `/stratio/e/igualdad/`):

- `/stratio/e/igualdad/2-apps-layer-kit/docs/igualdad-dgutierrez.yaml`: el de la PR 7.2 sin cambios, solo con `KEOS_WORKSPACE_DIR: "/stratio/e/igualdad"`. Se parsea bien: tenants `keos` y `dev`.
- `/stratio/e/igualdad/2-apps-layer-kit/docs/dot-env`: contenido del `.env`.

Valores de nuestro clúster y de dónde salen:

| Valor | Valor para nosotros | Dónde se obtiene / quién lo usa |
|---|---|---|
| `external_domain` | `igualdad-dgutierrez.desa.int` | Objeto `keos`. apps-layer lo lee solo (`EXT_DOMAIN`). No se pasa a mano. |
| `cluster_id` | `igualdad-dgutierrez` | Objeto `keos`. Nombre del contenedor keos-installer. |
| Host de las apps | `admin.igualdad-dgutierrez.desa.int` | `CLUSTER_NAME` (`admin`) más `EXT_DOMAIN`. Se puede sobreescribir por app (`ROCKET_HAPROXY_HOST`, `DISCOVERY_HAPROXY_HOST`...). |
| Tenant `keos` | gobierno en `keos-core` | YAML. |
| Tenant de trabajo | `dev` (namespaces `dev-apps`, `dev-datastores`, `dev-rocket`, `dev-intelligence`) | YAML (nombres del cliente, según la PR). |
| Admin | `admin` (contraseña en `secrets.yml` del workspace, cifrada) | Lo lee `getAdminUserId/Pass` de `${WORKSPACE_DIR}/secrets.yml` con `vault-master-key`. |
| StorageClass | `keos` (default, EBS). `efs-igualdad-dgutierrez` es RWX y no es la default | Las apps usan la default. HDFS tiene `HDFS_STORAGE_CLASS_NAME` (vacío = default). Intelligence tiene los PVC `keos` por defecto. Cualquier uso de EFS habría que pasarlo a mano. |
| Bucket Velero `igualdad-dgutierrez-velero-821111360971` | solo en `override_vars` de keos | **apps-layer no lo usa.** Solo `enviroment-ready --backups`, que no se lanza. |
| Zonas Route53 | pública y privada del dominio | La gestiona external-dns. apps-layer no las toca. Solo condiciona el DNS (apartado 2). |
| ECR `717279725338.dkr.ecr.eu-west-1.amazonaws.com` y `oci://.../helm-15.1` | en `keos.yaml` | `getDefaultRegistry()` lo lee de `.spec.docker_registry.url` (lo usa `connectors-management/post-install.sh` para el Job `connectors-loader`). El resto lo resuelve CCT. |
| Universo | `15.1.0` | `UNIVERSE_VERSION`; zip y `universe-images.lst` frescos, montados sobre los de la imagen (`fetch-universe.sh`). |
| Credenciales AWS | perfil `cloud-provisioner` de `~/.aws` | Solo para `aws eks get-token` del kubeconfig. Los S3 helpers solo si se define `S3_BUCKET_NAME`. |

Tamaño: `ENVIRONMENT_SIZE: "S"`. Aviso: en tamaño `S`, `connector-dfs-hdfs` pide 4 CPU y 4096 MB de requests, y el hdfs tiene 3 datanodes. Hay holgura en 3 nodos de 16 vCPU, pero conviene revisar `kubectl describe node` si algo queda Pending.

---

## 4. Secuencia de comandos (copiable)

Se asume bash o zsh en la estación, con `docker`, `aws` y `kubectl`. Los pasos 1 y 2 crean ficheros nuevos fuera de `/stratio/e/igualdad/` salvo el directorio `apps-layer` (decisión vuestra, ver nota).

### Paso 0. Comprobaciones previas (solo lectura)

```bash
export AWS_PROFILE=cloud-provisioner
export KUBECONFIG=/stratio/e/igualdad/1-aws-cluster/estado/kubeconfig-igualdad-dgutierrez

# keos install terminado: no debe seguir el contenedor del instalador
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep keos-installer
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'          # debe salir vacío
kubectl -n keos-ops get keos keos -o jsonpath='{.metadata.annotations.keos\.stratio\.com/version}{"\n"}'   # 1.4.2
kubectl get tenant keos
kubectl -n keos-cct get pods
docker image inspect qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT --format '{{index .RepoDigests 0}}'
```

Esperado: ningún pod no Running, `1.4.2`, tenant `keos` Active/READY, imagen presente (digest `a745cac6...`).

### Paso 1. Directorio apps-layer

Opción A, como en la PR: dentro del workspace. Opción B: fuera del workspace. Recomiendo B para no mezclar `kube-config` con el workspace de keos-installer, pero A también funciona.

```bash
export KEOS_WORKSPACE_DIR=/stratio/e/igualdad
export APPS_LAYER_DIR=/tmp/apps-layer-igualdad-dgutierrez      # opción A (PR). Opción B: p. ej. $HOME/apps-layer-igualdad-dgutierrez
mkdir -p "$APPS_LAYER_DIR"

# kubeconfig con exec "aws eks get-token" (AWS_PROFILE=cloud-provisioner), validado dentro de la imagen
aws eks update-kubeconfig --name igualdad-dgutierrez --region eu-west-1 \
  --profile cloud-provisioner --kubeconfig "$APPS_LAYER_DIR/kube-config"
# alternativa: cp /stratio/e/igualdad/1-aws-cluster/estado/kubeconfig-igualdad-dgutierrez "$APPS_LAYER_DIR/kube-config"

cat > "$APPS_LAYER_DIR/.env" <<'EOF'
export DOCKER_DIND_ENABLED=false
export KEOS_WORKSPACE_DIR=/stratio/e/igualdad
export KEOS_INSTALLER_EXTRA_ARGS="--net host"
EOF

cp /stratio/e/igualdad/2-apps-layer-kit/docs/igualdad-dgutierrez.yaml \
   "$APPS_LAYER_DIR/igualdad-dgutierrez.yaml"
```

Por qué `.env` lleva `KEOS_WORKSPACE_DIR` y `KEOS_INSTALLER_EXTRA_ARGS`: [CÓDIGO] el `entrypoint.sh` usa esas dos variables en su `docker run` del contenedor keos-installer **antes** de que `apps-installer` lea el YAML. El `.env` sí se lee antes. Si `KEOS_WORKSPACE_DIR` no está, toma `/workspace`, y el daemon del host montaría `/workspace` del host (vacío) en el contenedor keos-installer. La sección 7.1 de la PR no lo pone en `.env`. [SUPOSICIÓN: no lo he ejecutado de punta a punta; es lectura de código]

Validación del paso 1:

```bash
ls -l "$APPS_LAYER_DIR"                                   # kube-config, .env, igualdad-dgutierrez.yaml
KUBECONFIG="$APPS_LAYER_DIR/kube-config" kubectl get nodes      # 3 nodos Ready (con AWS_PROFILE=cloud-provisioner)
python3 -I -c "import yaml,sys;d=yaml.safe_load(open('$APPS_LAYER_DIR/igualdad-dgutierrez.yaml'));print([t['name'] for t in d['tenants']])"
```

### Paso 2. Lanzar el contenedor

Resolver la IP del NLB externo (para `--add-host`; si ya resuelve el DNS, omitir esa opción):

```bash
NLB=$(kubectl -n keos-ingress get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
NLB_IP=$(getent hosts "$NLB" | awk 'NR==1{print $1}')
echo "$NLB $NLB_IP"
```

```bash
docker run -it --rm \
  -v "$APPS_LAYER_DIR":/apps-layer/ \
  -v "$KEOS_WORKSPACE_DIR":/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.aws:/root/.aws:ro \
  --add-host "admin.igualdad-dgutierrez.desa.int:${NLB_IP}" \
  --net host --cgroupns host \
  qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT
```

**ACTUALIZACIÓN:** el zip (y `universe-images.lst`) se descargan siempre frescos y se montan; lo automatiza `scripts/launch-apps-layer.sh` (que invoca `scripts/fetch-universe.sh`). Lo que sigue es el comando manual original, ya no opcional (el zip de la imagen pesa 733687 bytes):

```bash
# ahora obligatorio (lo hace fetch-universe.sh); ademas, universe-images.lst con gh api (rama branch-15.1)
curl -fSL -o "$APPS_LAYER_DIR/kubernetes-universe-descriptors-15.1.0.zip" \
  "http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/kubernetes-universe-descriptors-15.1.0.zip"
# y añadir:  -v "$APPS_LAYER_DIR/kubernetes-universe-descriptors-15.1.0.zip":/apps-layer-automation/universe/kubernetes-universe-descriptors-15.1.0.zip
```

Si `~/.aws:ro` diera errores de escritura de caché en `aws eks get-token`, quitar `:ro`. En la prueba que hice (solo `get-token` y `kubectl`) funcionó con `:ro`. [VERIFICADO]

Salida esperada del entrypoint: "Loading global variables", "Using kubeconfig: /apps-layer/kube-config", y luego el prompt `[apps-layer:15.1 <contexto>] /apps-layer#`. Mientras el contenedor keos-installer arranca verás mensajes `Waiting for keos-installer readiness message`.

Validación del paso 2 (desde otra terminal):

```bash
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep keos-installer_igualdad-dgutierrez
docker logs keos-installer_igualdad-dgutierrez 2>&1 | tail -5       # "Starting interactive session. Use 'keos install' or 'keos help'"
```

### Paso 3. Instalar

Dentro del contenedor:

```bash
cd /apps-layer
apps-installer igualdad-dgutierrez.yaml
```

Qué pasa y qué mirar, paso a paso, desde otra terminal con `KUBECONFIG` y `AWS_PROFILE` como en el paso 0:

1. **Subida de memoria del orquestador a 10Gi y rollout.**
   ```bash
   kubectl -n keos-cct get deploy cct-orchestrator -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
   ```
2. **Carga del universo 15.1.0.** Debe aparecer "Loading Stratio universe 15.1.0" en el log.
3. **Tenant `keos`.** Existe ya, así que se saltan la creación y el rol, y se despliegan las 5 apps de gobierno.
   ```bash
   kubectl -n keos-core get deploy | grep -E 'dg-|governance'
   ```
4. **Tenant `dev`.** Se crea con Capsule, se crean los grupos y roles de Gosec, y `assign-gov-roles.sh` genera el certificado del admin (aquí falla si no resuelve el DNS).
   ```bash
   kubectl get tenant dev
   kubectl get ns | grep '^dev-'
   ```
5. **Apps de `dev`, por tandas:**
   1. postgres `pg-meta`, postgres `pg-data`, hdfs y connectors.
   2. agents y pgbouncers.
   3. virtualizer.
   4. rocket, eureka-agent, `connector-dfs-hdfs` y dg-datarest-pgi.
   5. discovery e intelligence.
   ```bash
   kubectl get pgcluster,hdfscluster,pgbouncer -n dev-datastores
   kubectl get pods -A | grep -E '^dev-'
   ```
6. **Final.** Mensaje `Apps succesfully installed on N minutes.` y rollback del orquestador (`helm -n keos-cct history cct`).

Validación global tras el paso 3:

```bash
kubectl get pods -n dev-apps,dev-datastores,dev-rocket,dev-intelligence 2>/dev/null || \
  for n in dev-apps dev-datastores dev-rocket dev-intelligence keos-core; do echo "== $n"; kubectl get pods -n $n; done
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
kubectl get ingress -A | grep -E 'dev-|keos-core'
# CCT: estado de cada aplicación (desde dentro del contenedor, con las funciones del proyecto)
```

Acceso web: `https://admin.igualdad-dgutierrez.desa.int/` (misma resolución DNS que arriba). Usuario `admin` (contraseña en `secrets.yml`).

### Paso 4. Reintentar

[CÓDIGO] Volver a ejecutar `apps-installer igualdad-dgutierrez.yaml` es seguro: salta tenants existentes, grupos y apps con `status success` y `health ready`. Las apps fallidas o a medias se vuelven a renderizar y desplegar. Si falla una app, el script marca `STATUS=fail` y no sigue con el resto de tenants. Los logs de cada app salen por la consola, y los JSON renderizados quedan en `${WORKSPACE_DIR}/apps/<app>/<APP_NAME>.<NS>.json` (es decir, `/stratio/e/igualdad/apps/...`).

Para acotar un reintento, copiar el YAML y dejar solo las apps pendientes. Ejemplo: un `igualdad-dgutierrez-retry.yaml` con el tenant `dev` y solo el grupo que falló.

### Paso 5. Desinstalar una app o todo (solo documentación)

- [CÓDIGO] El proyecto no tiene un comando de desinstalación completo. Hay una función `deleteCCTService <app> <ns> <json> [force]` en `scripts/utils/global-functions.sh` que hace `PUT /v2/uninstall/<app>.<ns>?force=<true|false>` al orquestador con el JSON renderizado. [SUPOSICIÓN: se puede usar así dentro del contenedor tras `source` de `b-log.sh` y `global-functions.sh`, y no lo he probado]
- Los datos (PVC de Postgres y HDFS) pueden sobrevivir a la desinstalación. [SUPOSICIÓN]
- Para borrar todo el clúster, usar la skill `legacy-eks-cluster` (desinstalar), que ya cubre los recursos de AWS.

---

## 5. Riesgos e incógnitas

1. **Orden de lanzamiento frente a `keos install`**: no ejecutar apps-layer hasta que acabe el instalador (apartado 2).
2. **DNS de `admin.igualdad-dgutierrez.desa.int`** (apartado 2): sin `--add-host` o `/etc/hosts` falla `assign-gov-roles.sh` en `dev`. También lo usa `datamarket-agent`/`pit` (`createUserCert`) y `intelligence/post-upgrade.sh` (JupyterHub). En el YAML de la PR no se despliegan los dos primeros.
3. **`.env` incompleto en la PR** (apartado 4, paso 1): mi `.env` lo corrige. Es lectura de código, no probado de punta a punta.
4. **SNAPSHOT mutable**: el tag `15.1-0.1.0-SNAPSHOT` puede cambiar. Para reproducibilidad usar el digest `qa.int.stratio.com/stratio/apps-layer-automation@sha256:a745cac6f9a30b68e9e5ff5312c0b584ac78ffb2dc955ad3430661617de6d37a`.
5. **Pull-through cache de ECR** para las imágenes `stratio-releases.repo.stratio.com` de las apps (apartado 2, punto 4): no verificado.
6. **Contaminación del workspace**: [CÓDIGO] apps-layer escribe en `${WORKSPACE_DIR}` (que aquí es `/stratio/e/igualdad`): `keos-tenant.yaml`, `dev-tenant.yaml`, `apps/`, `*_group.json`, `*-users_role.json`, y **`admin.key` y `admin.cert`** (certificado y clave privada del admin generados por `createUserCert`). No subir esos ficheros a git; borrar la clave tras la instalación si no se necesita.
7. **Memoria del orquestador**: se sube a 10Gi con requests igual a limits. En los nodos actuales hay sitio (61 GiB asignables por nodo), pero si el pod queda Pending, comprobar los nodos.
8. **El `trap EXIT` hace `helm rollback cct <revisión>`**: si abortáis a medias con Ctrl+C, el rollback se ejecuta igualmente. Es el comportamiento esperado, no un fallo.
9. **Tamaño `S`**: `ENVIRONMENT_SIZE` distinto de `S`, `PIT` o (en el kit) `CUSTOM` rompe las plantillas (apartado 0 y 1). `CUSTOM` solo funciona con el overlay del kit, que no es upstream.
10. **El PR dice "customer-like"**: los recursos del cliente son tamaño M/M+parches en el lado GitOps; con apps-layer solo se tiene `S` o `PIT`. Si queréis recursos del cliente, hay que sobreescribir variables (`CPU_REQUESTS`, `MEMORY_REQUESTS`, etc.) por app en `env:`, **y con `S`/`PIT` en muchas apps `sizes/` las pisa** (por eso la guía usa `CUSTOM`; ver la nota del apartado 1). [SUPOSICIÓN confirmada después leyendo `deploy-apps.sh`; el kit lo implementa como `ENVIRONMENT_SIZE=CUSTOM`.]
11. **Rama del repo**: la 15.1 aún es `0.1.0-SNAPSHOT`, sin tag final. Sin garantías de estabilidad.
12. **Credenciales por defecto**: `connectors-management/pre-install.sh` escribe en Vault una contraseña fija (`Stratio%1234`) para `connectors-secret`. Es un valor por defecto del proyecto, aceptable en desarrollo.
13. **Checkout local sucio** (`/stratio/aws/apps-layer-automation`): no usarlo para construir una imagen sin revisar los cambios sin commitear.

## 6. Qué no he podido verificar

- Una ejecución real de `apps-installer` (no lanzada, por ser solo lectura).
- Que el contenedor `keos-installer:1.4.2` arranque en modo detached no interactivo con `VAULT_MASTER_KEY` y `SKIP_CONFIRMATION` (por el código de `/docker_entrypoint.sh` debería: `export_secrets.py` usa la clave y salta las confirmaciones, pero no lo he ejecutado).
- Resolución de las imágenes de las apps por ECR (pull-through cache).
- Tiempo total y consumo de recursos de las apps en tamaño `S`.
- Conectividad desde esta estación al NLB externo (SG con `0.0.0.0/0` según `override_vars`; solo he comprobado que el hostname del NLB resuelve a IPs públicas).
- La corrección funcional de la lista de apps y variables del cliente (viene de la PR, que cita `pods.yaml` de PLT-4418; no he podido ver ese fichero).
- Que `keos` y `dev` en `ENVIRONMENT_SIZE: S` no choquen con los recursos que el cliente espera.
