# Pasos 0-15 (+ 13b y 14h opcionales): comando, validación OK/KO y qué hacer si falla

Convenciones: `SK` = directorio de la skill (el de este fichero, `..`). `DIR` = `./clusters/<cluster>` (directorio de trabajo).
**Progreso**: en cada paso la skill marca `doing`/`done`/`fail`/`skip` con `bash $SK/scripts/progress.sh --dir $DIR <estado> <ID>` y pega en la respuesta la lista markdown que imprime (regla 11 de `SKILL.md`). IDs: `0 1 2 3 4 5 6 7 8 9 10 11 12 13 13b 14 14f 14g 14h` (el `14` agrupa 14a-14e, `14f` es lanzar `apps-installer`, `14g` comprobar las apps, el `2` incluye el 2b; el paso `8-11` se marca de uno en uno). El `done` se marca solo tras la validación OK de cada paso.
Cada paso termina con una **validación de solo lectura que ejecuta la skill**; no se pasa al siguiente hasta que da OK.
Los pasos que crean recursos se previsualizan siempre en **dry-run** (`provision.sh <paso>` sin `--apply`) y se aplican
solo tras el OK explícito de la persona usuaria. Todo bloque para la persona usuaria empieza por `export AWS_PAGER=""`.

Bloque de arranque para cualquier terminal nuevo de la persona usuaria (zsh o bash):

```bash
export AWS_PAGER=""
SK=/stratio/e/igualdad/.claude/skills/legacy-eks-cluster      # ajustar si la skill vive en otra ruta
cd <directorio-desde-el-que-se-trabaja> && DIR=./clusters/<cluster> && source "$DIR/cluster.env"
```

## 0. Preparación y variables

1. Variables a partir de **cuenta + nombre** (no crea nada en AWS):
   `bash $SK/scripts/init-cluster.sh --account <cuenta> --name <cluster>` (ver tabla en `SKILL.md`).
   Si imprime `PREGUNTAR: ...` (0 o varios perfiles de administración candidatos) se pregunta a la persona usuaria y se fija con
   `init-cluster.sh --dir $DIR --set ADMIN_PROFILE=<perfil>`.
2. Binario de cloud-provisioner (solo si `CLOUD_PROVISIONER_BIN` quedó vacío). Los releases de GitHub no traen binarios:
   se compila desde el tag (Go lo resuelve con `GOTOOLCHAIN=auto`; hacen falta varios GB libres):
   ```bash
   git clone --depth 1 --branch "$CLOUD_PROVISIONER_VERSION" https://github.com/Stratio/kind.git ~/src/cloud-provisioner-$CLOUD_PROVISIONER_VERSION
   cd ~/src/cloud-provisioner-$CLOUD_PROVISIONER_VERSION && FORCE_HOST_GO=1 GOTOOLCHAIN=auto make clean build && ./bin/cloud-provisioner version
   ```
   y `init-cluster.sh --dir $DIR --set CLOUD_PROVISIONER_BIN=<ruta absoluta>`. Sin `--build-stratio-image`, cloud-provisioner **descarga**
   `$ECR_REGISTRY/stratio/cloud-provisioner:<versión>`, así que esa imagen debe existir (paso 2b).
3. **Validación**: `bash $SK/scripts/check-prereqs.sh --dir $DIR`. OK si no hay `KO`: herramientas (aws jq yq envsubst kubectl helm docker),
   daemon docker, binario con la versión esperada, `sts` del `ADMIN_PROFILE` = cuenta, sin EKS ni VPC con ese nombre, nombres de rol libres,
   bucket libre (los nombres S3 son globales; `403` = existe en otra cuenta), espacio en disco.
   *Si falla*: el mensaje dice qué. Perfil sin credenciales/MFA caducado => renovar sesión; bucket ocupado => `--set VELERO_BUCKET=...`.
4. La persona usuaria exporta `VAULT_PASSWORD` en SU terminal (nunca se escribe en ficheros ni se pide en la sesión).

## 1. Usuario IAM `cloud-provisioner` (crea recursos)

`bash $SK/scripts/provision.sh iam-user --dir $DIR` (dry-run) y luego `--apply`. Crea usuario + `AdministratorAccess` + access key guardada
en el perfil `$CP_PROFILE` sin imprimirla. IAM es global por cuenta: si el usuario ya existe **no** se crea otra key (máximo 2) salvo `--new-key`
y solo si el perfil local no tiene claves. **Validación** (la propagación de IAM tarda segundos; reintentar):
`aws sts get-caller-identity --profile $CP_PROFILE` => `Account` = cuenta y `Arn` termina en `user/cloud-provisioner`; una key `Active`;
`AdministratorAccess` adjunta (`iam list-attached-user-policies`). *Si falla*: esperar y reintentar; no crear keys a ciegas.

## 2. Policy `ecr-pull-through-cache-machinepool` (crea recursos)

`provision.sh ecr-policy --dir $DIR [--apply]`. Una vez por cuenta; es la de `spec.security.aws.nodegroup_extra_policy_arn`.
**Validación**: `aws iam get-policy --policy-arn "$ECR_POLICY_ARN"` y acciones `ecr:BatchImportUpstreamImage`, `ecr:CreateRepository`.

## 2b. Acceso al ECR central (lectura)

`bash $SK/scripts/check-prereqs.sh --dir $DIR --ecr` (hace `docker login` con `$CP_PROFILE`, token de 12 h en `~/.docker/config.json`, y
`docker manifest inspect $ECR_REGISTRY/stratio/cloud-provisioner:$CLOUD_PROVISIONER_VERSION`). OK si hay login e imagen accesible.
*Si falla*: `denied/not authorized` => pedir a quien administre la cuenta del ECR (`717279725338`) que permita leer a `AWS_ACCOUNT_ID`;
`not found` => cambiar `CLOUD_PROVISIONER_VERSION`.

## 3. VPC y subnets (crea recursos)

```bash
bash $SK/scripts/create-test-vpc.sh --name "$CLUSTER_NAME" --azs "$VPC_AZS" --region "$AWS_REGION" --profile "$CP_PROFILE" \
  --vpc-cidr "$VPC_CIDR" --nat-mode "$VPC_NAT_MODE" --expect-account "$AWS_ACCOUNT_ID" --output "$DIR/${CLUSTER_NAME}.json"
```
3 AZ, una subnet pública y una privada por AZ, NAT `single` (uno compartido; `per-az` x3 coste), tags `Name`, `keos.stratio.com/owner`,
`managed-by`. Aborta si ya existe una VPC con ese `Name`. Tarda unos minutos (espera al NAT).
**Validación** (la skill, solo lectura): VPC `available` con `enableDnsSupport`/`enableDnsHostnames` a `True`; `2 x VPC_AZS` subnets repartidas por AZ;
NAT `available`; route table `-public` sale por `igw-…` y las `-private-N` por `nat-…`. *Si falla a medias*: no relanzar; borrar con
`create-test-vpc.sh --delete --name ... --expect-account ...` (dry-run por defecto).

## 4. Descriptor `cluster.yaml`

`bash $SK/scripts/render-cluster.sh --dir $DIR` (usa `<cluster>.json` y las claves del perfil `$CP_PROFILE`; `chmod 600`; **contiene secretos**).
**Validación**: permisos `-rw-------`; `grep -c '\${' $DIR/cluster.yaml` = 0; 2 documentos (`KeosCluster`, `ClusterConfig`); `gitops_enabled: false`;
las 3 subnets pertenecen a `vpc_id`, en AZ distintas y privadas (`MapPublicIpOnLaunch=False`, `aws ec2 describe-subnets`);
`nodegroup_extra_policy_arn` = `ECR_POLICY_ARN`; **`helm_repository.url` = `oci://$ECR_REGISTRY/$CP_HELM_PATH`** (termina en `/helm`; NO `/helm-15.1`, que es solo para keos-installer/`keos.yaml`: con `helm-15.1` cloud-provisioner falla con `cert-manager ... not found`; si `CP_HELM_PATH` falta en `cluster.env` el render usa `helm`) y **`control_plane.aws.logging.authenticator: true`**
(`yq -r 'select(.kind=="KeosCluster")|.spec.helm_repository.url,.spec.control_plane.aws.logging.authenticator' $DIR/cluster.yaml`). Ambos vienen de la PR (desde `2d36d7d`, vigentes en `1a1bbda`) y no llevan flag. `cluster_operator_version` sigue en `0.7.4` (la guía de la PR también lo fija). (El render ya valida lo estructural; las subnets se comprueban contra AWS.)

## 5. cloud-provisioner (lo lanza LA PERSONA USUARIA en otro terminal, ~20-40 min)

Primero `--validate-only` (no crea nada ni escribe `secrets.yml`; debe terminar en `Cluster descriptor is valid`):

```bash
export AWS_PAGER=""
cd <proyecto>/clusters/<cluster> && source ./cluster.env
export VAULT_PASSWORD='...'                    # solo en tu terminal
export AWS_PROFILE="$CP_PROFILE"
"$CLOUD_PROVISIONER_BIN" create cluster --name "$CLUSTER_NAME" --descriptor cluster.yaml --vault-password "$VAULT_PASSWORD" --validate-only
"$CLOUD_PROVISIONER_BIN" create cluster --name "$CLUSTER_NAME" --descriptor cluster.yaml --vault-password "$VAULT_PASSWORD" --retain --delete-previous 2>&1 | tee "logs/create-$CLUSTER_NAME.log"
```
(`--vault-password` queda en el historial/`ps`; si se omite, el binario pide la contraseña por teclado.) Es **imprescindible** lanzarlo desde el directorio
del clúster: deja ahí `secrets.yml`, `keos.yaml`, `.kube/config`, `backup/` y `override_vars/`.
Mientras corre la skill monitoriza en solo lectura: `eks describe-cluster` (CREATING -> ACTIVE), `eks list-nodegroups`, instancias `pending/running`,
`tail` del log. Con `gitops_enabled: false` cloud-provisioner instala su propio Flux (release `flux` en `kube-system`), cluster-autoscaler y
keoscluster-controller.
*Si falla*: copiar el error a la sesión **antes de relanzar**. Tras un fallo a medias `--delete-previous` borra el kind local, pero lo creado en
AWS puede quedar: revisar recursos huérfanos (EKS, nodegroups, SG, ENI, pila CloudFormation, OIDC) antes de reintentar.

## 6. Validación del clúster

Kubeconfig **propio** (el `.kube/config` de cloud-provisioner lleva un token que caduca en minutos, y tras `keos install` `.kube/` pasa a ser de root):
`aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$CP_PROFILE" --kubeconfig "$DIR/kubeconfig-$CLUSTER_NAME"` (chmod 600).
Validar: EKS `ACTIVE` y versión `1.35`; **nodegroups: uno gestionado por AZ** (`<cluster>_<NODEGROUP_NAME>-mp-0/1/2`, cada uno min 1/max 2/desired 1 para
quantity 3, min 3, max 6): se descubren con `eks list-nodegroups`, todos `ACTIVE` y suma de `desiredSize` = `NODE_QTY`; `NODE_QTY` nodos `Ready`;
ningún pod fuera de `Running/Completed`; sin `ImagePullBackOff` (confirma acceso al ECR); `helm ls -A` con `flux`, `cluster-autoscaler`, `cluster-operator`;
`kubectl get keoscluster -A` en `Provisioned`; proveedor OIDC asociado; **zona Route53 de `$EXTERNAL_DOMAIN` NO creada** (cloud-provisioner no las crea aunque
`dns.manage_zone: true`: paso 8). Los EBS de los nodos salen `Encrypted=False` aunque la plantilla pide `encrypted: true`: ver `open-risks.md` (riesgo 5).

### 6b. Imagen de cluster-autoscaler (a revisar con la persona usuaria)
La doc de Stratio/kind indica que con MachinePools EKS y `deploy_autoscaler: true` hay que sustituir la imagen por
`stratio-releases.repo.stratio.com/autoscaling/cluster-autoscaler:v1.35.2` (réplica en el registry del clúster + override en el ConfigMap
`02-cluster-autoscaler-helm-chart-override-values`). **No estaba en la guía validada**; la skill lo menciona y la persona usuaria decide.

## 7. Variables derivadas del clúster (solo lectura)

`eval "$(bash $SK/scripts/derive-cluster-vars.sh --dir $DIR)"` => `VPC_ID SUBNET_IDS CLUSTER_SG OIDC_ISSUER PUBLIC_ZONE_ID PRIVATE_ZONE_ID`.
OK si `VPC_ID` = el de `<cluster>.json`, `SUBNET_IDS` son las 3 privadas y `OIDC_ISSUER` no está vacío. (No se guardan: cada terminal nuevo repite esto;
`provision.sh` ya lo hace por sí mismo.)

## 8-11. Prerrequisitos de keos-installer (crean recursos; uno a uno, con OK)

| Paso | Comando (dry-run primero) | Validación OK |
|---|---|---|
| 8 zonas Route53 | `provision.sh zones` | exactamente 1 zona pública + 1 privada; la privada con la VPC del clúster |
| 9 IRSA external-dns | `provision.sh external-dns` | rol `${CLUSTER}-external-dns` con la policy adjunta y `sub` = `system:serviceaccount:kube-system:external-dns` |
| 10 bucket + IRSA velero | `provision.sh velero` | `head-bucket` OK; rol `$VELERO_ROLE` con policy; `sub` = `system:serviceaccount:keos-backup:velero-server` |
| 11 EFS | `provision.sh efs` | EFS `available`, 3 mount targets `available` (SG del clúster), política del FS con TLS solo vía mount target |
| 11 permisos CSI | `provision.sh efs-csi` y `--apply --ack-shared-node-role` | `${CLUSTER}-efs-csi` adjunta al rol de nodos |

El paso `efs-csi` modifica el rol **de cuenta** `eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io` (lo comparten todos los clústeres que cree
cloud-provisioner en la cuenta y todos los pods de los nodos heredan EFS): requiere OK explícito, revisar la policy descargada de `master` sin versión fija.
La delegación NS de la zona pública en `desa.int` queda fuera de alcance. `provision.sh status` lista lo existente.

## 12. Workspace de keos-installer (y DECISIÓN de las opciones que cambian `keos.yaml`)

`bash $SK/scripts/render-keos.sh --dir $DIR` genera `keos.yaml` (conserva el de cloud-provisioner como `keos.yaml.cloud-provisioner`) y
`override_vars/<cluster>.yaml`, y mueve `override_vars/ingress-nginx.yaml` (de cloud-provisioner, solo LB interno) a `.cloud-provisioner.bak` cuando
`INGRESS_EXTERNAL_LB=true`. **Validación**: `diff keos.yaml.cloud-provisioner keos.yaml` (cambia `flavour: production`, chart repo `/${KEOS_HELM_PATH}` y el EFS
con `providers: custom, csi-aws`); sin `${`; YAML válido. Revisar `INGRESS_EXTERNAL_CIDRS` (por defecto `0.0.0.0/0`) o usar `INGRESS_EXTERNAL_LB=false`.
**Con los flags opcionales a `false` (defecto) la salida es idéntica a la anterior a esta sincronización.**

**12a. AVISAR y PREGUNTAR antes del paso 13 (obligatorio para la skill).** Tres flags opcionales **cambian `keos.yaml`/`override_vars`** y se aplican durante `keos install`; la guía de origen no los marca como obligatorios (son lo que tiene el cliente), así que la skill **no los activa por su cuenta**.
Antes de entregar el bloque del paso 13, explica en una línea cada uno y pregunta con **AskUserQuestion** (multiSelect; opción "ninguno") cuáles activar:

| Flag (defecto `false`, solo `true\|false`) | Qué cambia | Notas |
|---|---|---|
| `ENABLE_BACKUP_VELERO` | `keos.yaml`: `keos.backup.storage_class: ${EFS_SC_NAME}`; `override_vars`: `velero_enable_snapshot_volumes: true`; **`override_charts_values/keos-backup-velero.yaml`** con `credentials.useSecret: false` | Prepara `keos backup velero` (13b). Sin `storage_class` el PVC RWX de `keos backup create vault` queda `Pending` en EBS. El fichero es **requisito técnico con IRSA** (keos-installer 1.4.2 no pasa `useSecret: false`: la BSL queda `Unavailable`, `no EC2 IMDS role found`); idempotente (no pisa uno con `useSecret: false`; otro contenido -> `.bak.<epoch>`) |
| `KEOS_ENABLE_CLAMAV` | `keos.yaml`: `keos.security.clamav.enabled: true` | Lo despliega `keos install` en 1.4.2 |
| `ENABLE_FALCO` | `keos.yaml`: `keos.security.falco` con `enabled: false` **siempre** + `opensearch_output: true` | Con `true` el precheck de `keos install` falla ("Falco cannot be enabled during cluster installation"); el flag solo añade la activación al 13b. Necesita central logging |

Aplicar **solo lo elegido**: `bash $SK/scripts/init-cluster.sh --dir $DIR --set ENABLE_X=true` (añade `export ENABLE_X=true` a `cluster.env`; los flags se leen **solo de `cluster.env`**: un `ENABLE_X=true` exportado en la shell se ignora) y **volver a ejecutar `render-keos.sh`**. Si no elige ninguno, no se cambia nada.
`ENABLE_MONITORING`, `ENABLE_CENTRAL_LOGGING` y `ENABLE_BACKUP_SCHEDULE` no cambian ficheros (solo el 13b): se pueden decidir después de `keos install`.
**Validación** (solo lectura): `yq -r '.keos.backup.storage_class // "-"' $DIR/keos.yaml`; `grep velero_enable_snapshot_volumes $DIR/override_vars/<cluster>.yaml`; `yq -r '.credentials.useSecret' $DIR/override_charts_values/keos-backup-velero.yaml` (= `false`); `yq -r '.keos.security // "-"' $DIR/keos.yaml` (`falco.enabled` siempre `false`); sin `${`.
Un valor distinto de `true|false` aborta el render. *Si ya se hizo `keos install` sin el flag*: no hay un camino validado para cambiar lo que pasa por `keos.yaml` (falco lo cubre el 13b; Velero sin el override de `useSecret` deja la BSL `Unavailable`); decirlo, no improvisar.
**No se adopta** el `flavour: custom` de la guía (valores del cliente); mecanismo si se quiere: volcar `/stratio/ansible/inventory/group_vars/flavours/production.yml` de la imagen 1.4.2 a `override_vars/flavours/custom.yml` y editar `keos_flavour_app_definition`.

## 13. `keos install` (lo lanza LA PERSONA USUARIA)

**Solo tras la pregunta del 12a** (y el re-render si activó algo). Requiere acceso a `qa.int.stratio.com` (VPN/login docker) y al socket de Docker. Desde el directorio del clúster:

```bash
export AWS_PAGER=""
cd <proyecto>/clusters/<cluster> && source ./cluster.env
docker run -ti -v "$PWD":/workspace -v /var/run/docker.sock:/var/run/docker.sock "$KEOS_INSTALLER_IMAGE"
# dentro:  keos install
```
Pide una contraseña para `secrets.yml`: ya existe uno cifrado por cloud-provisioner con la misma `VAULT_PASSWORD` (**compatibilidad no verificada**: comprobar
que acepta esa contraseña; si pide credenciales AWS son las del usuario `cloud-provisioner`). Tras la ejecución `.kube/` pasa a ser de root: usar siempre el
kubeconfig propio `kubeconfig-<cluster>`. Si el EFS se añadiera después: `keos edit keos -n keos-ops` y `keos system-services --tags aws-csi`.
Hasta que acaba no existen NLB, PVC ni namespaces `keos-*`. `keos install` **no** despliega monitorización (`keos-metrics`), Velero (`keos-backup`), central logging ni falco: es el 13b.

## 13b. Post-install OPCIONAL (avisar, preguntar, imprimir; lo ejecuta LA PERSONA USUARIA dentro del contenedor)

Solo cuando `keos install` ha terminado (validar en solo lectura: tenant `keos` Active, `cct-orchestrator` Running; ver 14a). **Ninguna opción es obligatoria** según la guía de origen. La skill:
1. **Avisa** de que tras `keos install` el clúster **no** tiene monitorización, Velero, backups programados, central logging ni falco (el del cliente sí), y de qué hace cada opción y su riesgo:

| Opción (flag) | Comandos que imprime `render-postinstall.sh` | Avisos |
|---|---|---|
| Monitorización (`ENABLE_MONITORING`) | `keos monitoring` + parche PLT-5162 | Prometheus, Alertmanager, Grafana, Thanos query + exporters de `override_vars`. La HelmRelease `pushgateway` de `keos-metrics` queda con `ValuesError ... yaml: line 119` (probes con dos espacios de más en el CM `00-pushgateway-helm-chart-default-values`, keos-installer 1.4.2); el parche (`sed`+`jq`+`kubectl patch cm`) **no persiste: se pierde si se relanza `keos monitoring`**. Se omite si `prometheus_pushgateway_enabled` no es `true` en el override |
| Velero (`ENABLE_BACKUP_VELERO`) | `keos backup velero` + `kubectl -n keos-backup get bsl aws` | La BSL debe quedar `Available`. Exige el render con el flag **antes** de `keos install` (12a: `storage_class`, snapshots y `override_charts_values/keos-backup-velero.yaml`); si falta el fichero el script avisa |
| Backups programados (`ENABLE_BACKUP_SCHEDULE`) | `keos backup schedule vault idp` | IdP 00:00, vault 00:05, 7 días de retención, sin `control-plane` (no aplica en EKS); la guía lo lanza tras Velero (el script avisa si no se activó) |
| Central logging (`ENABLE_CENTRAL_LOGGING`) | `keos central-logging` | `keos-logs`: fluentd + OpenSearch |
| Falco (`ENABLE_FALCO`) | `sed -i ... /workspace/keos.yaml`; `kubectl -n keos-ops patch keos keos ...`; `keos falco` | Necesita central logging (el script avisa). `keos.yaml` se instaló con `falco.enabled: false`; `keos falco` exige `true` en `keos.yaml` **y** en el CR `keos` de `keos-ops`: dos sitios. Un nuevo `render-keos.sh` lo devuelve a `false` en el fichero |

2. **Pregunta** con AskUserQuestion (multiSelect, opción "ninguna") cuáles quiere. Antes de entregar Velero o falco, comprueba en solo lectura que `keos.yaml` lo lleva (`yq -r '.keos.backup.storage_class' $DIR/keos.yaml`, `yq -r '.keos.security.falco.enabled' $DIR/keos.yaml` = `false`, y el override de Velero); si no, **avisa** en vez de entregar comandos que fallarán.
3. Aplica lo elegido: `init-cluster.sh --dir $DIR --set ENABLE_X=true` (solo `true|false`).
4. Ejecuta `bash $SK/scripts/render-postinstall.sh --dir $DIR`: **solo imprime** (no ejecuta nada ni escribe); sin flags imprime un AVISO con las opciones. Entrega su salida en **un único bloque copiable** (regla 2: empieza por `export AWS_PAGER=""`) para pegar **dentro del contenedor keos-installer** (el del `docker run` del paso 13). **La skill nunca lo ejecuta.**
   Copia equivalente para uso manual sin la skill: `1-aws-cluster/render-postinstall.sh [ENV_FILE]`.
5. **Validación** (solo lectura, kubeconfig propio): `kubectl -n keos-metrics get hr` (todas `Ready`; `pushgateway` tras el parche), `kubectl -n keos-backup get bsl aws` (`Available`), `kubectl -n keos-logs get pods`, falco según corresponda. *Si falla*: copiar el error; no relanzar `keos monitoring` sin recordar que pierde el parche.
**No probado**: los bloques 13b solo se han verificado con mocks (salida de `render-postinstall.sh`), nunca contra un clúster real.

## 14. apps-layer-automation (DESPUÉS de `keos install`; variante S3)

Instala los tenants `keos` (gobierno) y `dev` (virtualizer, rocket, discovery, intelligence, genai...) con la imagen `qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-M2`
sobre Command Center (CCT), **con S3 en vez de HDFS**. La skill NO reimplementa nada: `scripts/apps-layer.sh` parametriza el kit `2-apps-layer-kit` (en el workspace igualdad:
`/stratio/e/igualdad/2-apps-layer-kit`; otro sitio: `APPS_LAYER_KIT=<ruta>` o `--kit`) desde `<dir>/cluster.env`. El workspace de keos (`<dir>`, donde está `keos.yaml`) se monta como `/workspace`.

```bash
export AWS_PAGER=""; unset APPS_LAYER_DIR          # una APPS_LAYER_DIR vieja pisa el defecto (gotchas.md); el script la ignora avisando
AL="bash $SK/scripts/apps-layer.sh --dir $DIR"      # sin subcomando: ayuda. `$AL env` imprime lo que se pasa al kit (sin secretos)
```
Variables (de `cluster.env` o `kit.env` del kit; solo las dos entradas de la skill son obligatorias): `CLUSTER_NAME`, `AWS_ACCOUNT_ID`, `AWS_REGION`, `EXTERNAL_DOMAIN` (`<cluster>.desa.int`),
`TENANT_NAME=dev`, `ENABLE_GENAI=true` (exige `LLM_TOKEN`), `KEOS_PROFILE=full|minimal`, `ENVIRONMENT_SIZE=S` (**`S`, `PIT` o `CUSTOM`**; otro valor aborta; ver abajo), `CUSTOM_SIZES_FILE` (solo con `CUSTOM`), `UNIVERSE_VERSION=15.1.0`,
`UNIVERSE_BRANCH` (def. el tag `UNIVERSE_VERSION`, `15.1.0`; ref del `.lst`), imagen `...apps-layer-automation:15.1-0.1.0-M2` (inmutable; haz `docker pull` antes). Directorio de ejecución **efímero**
`${TMPDIR:-/tmp}/apps-layer-<cluster>` (700, con secretos; regenerable con `render`), montado en `/apps-layer`.

**14a. Prerrequisitos (solo lectura)**: `$AL prereqs`. OK si: `keos install` terminado (tenant `keos` **Active**, `cct-orchestrator` **Running** en `keos-cct`, hostname del NLB en
`keos-ingress/ingress-nginx-controller`), `sts` del `CP_PROFILE` = cuenta, docker, `keos.yaml` en el workspace, herramientas, acceso a `qa.int.stratio.com` (VPN; aviso si no resuelve) y
**`gh` autenticado con acceso a `Stratio/kubernetes-universe`** (para el `universe-images.lst` fresco; si no: **PARAR** y pedir `gh auth login` / acceso). Aviso si hay otro contenedor
`keos-installer` en marcha (un `keos install` sin terminar escribe en el mismo workspace). *Si falla*: tenant no Active / pods CCT no Running => `keos install` no ha terminado, no seguir.
`$AL plan` hace además `s3-requisites plan` + `render --dry-run` sin escribir nada.

**Tamaños (`ENVIRONMENT_SIZE`)**: apps-layer solo conoce `S` y `PIT` y carga `apps/<app>/sizes/<tamaño>` **después** del env: en las apps que exportan valores fijos (17 de 38 en `branch-15.1-0.1` en el conjunto upstream completo con HDFS; 15 de 36 en nuestro kit S3) **pisa** lo que pongas en el YAML. Con `ENVIRONMENT_SIZE=CUSTOM` (`init-cluster.sh --dir $DIR --set ENVIRONMENT_SIZE=CUSTOM`; solo si la persona usuaria quiere los recursos de la guía/propios, avisando)
no se carga ningún `sizes/` y el kit inyecta en el `env:` de cada app las variables de recursos de su **overlay propio** `templates/sizes-custom.env` (valores de la guía de la PR para las apps que cubre y de `sizes/S` para el resto; sin hosts ni valores del cliente). **No existe `sizes/CUSTOM` upstream**: es mecanismo nuestro. `CUSTOM_SIZES_FILE=<ruta absoluta>` (en `cluster.env`/`kit.env`) usa una copia editada y **sustituye por completo** al overlay del kit.
`render` **aborta** con `app X: falta VAR` si a alguna app le falta una variable de la lista cerrada del kit (`custom_required_vars` en `lib.sh`) y `check` lo repite; con `S`/`PIT` el render es idéntico al de siempre. Quirks: discovery, intelligence y rocket no consumen `MEMORY_LIMITS`; `governance-map` cruza memorias; solo postgres/pgbouncer llevan unidad. **Avisar de la cabida**: los requests del overlay suman aprox. 8,6 vCPU y 45 GB (más ~2 vCPU y 8 GB de los workers de rocket; estimación del propio overlay) y los límites ~60 vCPU: pueden no caber en clústeres pequeños (3 x m6a.4xlarge sí). **No verificado** contra `apps-installer`. Detalle: `2-apps-layer-kit/README.md`, sección `ENVIRONMENT_SIZE=CUSTOM`.

**14b. Requisitos AWS de la variante S3** (crean recursos; dry-run primero): `$AL s3 plan` (solo lectura: qué existe y qué crearía) y, con OK explícito, **la persona usuaria** en SU terminal
`$AL s3 apply --apply` (pide terminal y escribir el clúster). Crea el stack CloudFormation `<cluster>-requisites`: bucket `<cluster>-internal-<cuenta>` (versionado, cifrado, **DeletionPolicy Retain**),
usuario IAM `<cluster>-s3` con `s3:*` solo sobre ese bucket, su access key y el secreto en Secrets Manager. Luego `$AL s3 env`: lee el secreto SIN imprimirlo y deja `S3_BUCKET_ACCESS_KEY`,
`S3_BUCKET_SECRET_KEY` y `AWS_REGION` solo en `<APPS_LAYER_DIR>/.env` (600). **Validación**: `$AL s3 status` => stack `CREATE_COMPLETE`, bucket accesible, usuario y secreto existen, las tres
variables "presente". *Si falla*: conflictos de nombre (bucket global, usuario/secreto ya usados) => cambiar `S3_BUCKET_NAME`/`S3_USER_NAME`; secreto "programado para borrado" => el kit da el comando.
(Clúster de referencia `igualdad-dgutierrez`: stack `igualdad-dgutierrez-requisites` CREATE_COMPLETE, bucket `igualdad-dgutierrez-internal-821111360971`.)

**14b-bis. Bucket de backups OPCIONAL (migración a GitOps; apps-layer no lo usa)**: recurso más del mismo stack `<cluster>-requisites`, **desactivado por defecto** (`ENABLE_BACKUPS_BUCKET=false`: no cambia nada).
Para activarlo pon en `cluster.env` `export ENABLE_BACKUPS_BUCKET=true` (opcional `BACKUPS_BUCKET_NAME`, def. `<cluster>-backups-<cuenta>`, y `BACKUPS_USER_NAME`, def. `<cluster>-backups`) y ejecuta `$AL s3 plan` (solo lectura;
aborta ante un bucket/usuario/secreto homónimo que no sea del stack) -> la persona usuaria `$AL s3 apply --apply` (sobre el stack existente es una ACTUALIZACIÓN que solo AÑADE bucket versionado+cifrado con **Retain**,
usuario IAM `s3:*` solo sobre él, access key y secreto; el texto de confirmación lo lista) -> `$AL s3 env` (añade `BACKUPS_S3_BUCKET_{ACCESS_KEY,SECRET_KEY,NAME,REGION}` al `.env`, 600, sin imprimir; si falta un `apply` avisa)
-> `$AL s3 backups-info` (solo lectura, sin secretos: bucket, región, usuario, ARN del secreto y el comando `get-secret-value` sin ejecutar). Para keos-fleet: `backups.s3BucketName`/`s3BucketRegion` y `BACKUPS_S3_BUNDLE` (README del kit).
*Si falla*: `apply` rechaza `ENABLE_BACKUPS_BUCKET=false` sobre un stack que ya tiene backups (los quitaría) y cambiar los nombres (sería un reemplazo).
**14c. LLM_TOKEN**: `$AL token <yaml-del-laboratorio>` (o `export LLM_TOKEN=...` y sin argumento). La skill **nunca lee ni imprime el valor**: solo "importado (N caracteres)". Sin espacios ni `* ? [`
(`deploy-apps.sh` exporta el env del tenant sin comillas). Después `render` lo inyecta también en el YAML del tenant (600). Con `ENABLE_GENAI=false` se omiten genai-*, `datamarket-agent` y `pit`.

**14d. Universo fresco (OBLIGATORIO antes de cada lanzamiento)**: `$AL fetch` (lo hace también `launch` solo; nunca reutiliza una copia previa) descarga a `<APPS_LAYER_DIR>`:
`kubernetes-universe-descriptors-<UNIVERSE_VERSION>.zip` (curl `-fSL` de `http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/...`, `unzip -t`, mv atómico, imprime tamaño y sha256) y
`<UNIVERSE_VERSION>-universe-images.lst` (`gh api` raw de `Stratio/kubernetes-universe` `ref=15.1.0` (tag de `UNIVERSE_VERSION`); no vacío y con `connectors-loader`). Se montan sobre los embebidos en la imagen
(el `.lst` de la imagen está desfasado: connectors-loader 2.2.0 frente a 2.2.3). El `.lst` fresco sigue siendo obligatorio, pero el kit fija por defecto `CONNECTORS_LOADER_VERSION=2.2.0` (como la PR keos-fleet#220) y el hook ignora el `.lst` para el loader; para usar el del `.lst` (2.2.3) deja `CONNECTORS_LOADER_VERSION=` vacía en `kit.env`. Si cambia `UNIVERSE_VERSION` cambian nombres, URL y rama; **no** se usa un zip/lst de otra versión.

**14e. Render + check**: `$AL render` (dry-run) y `$AL render --apply` (YAML raíz `<cluster>.yaml` y de tenant `<cluster>-<tenant>.yaml`, `.env`, `kube-config` y `aws/` solo con el perfil `cloud-provisioner`);
`$AL check`. **Validación**: termina en `RESULTADO: sin KO` y muestra `LLM_TOKEN OK (N caracteres) → genai-*: genai-api, genai-litellm`; comprueba además `.env` 600 con las claves S3 (nombres), zip y `.lst`
válidos (KO si falta el `.lst` o no contiene `connectors-loader`), YAML sin hdfs y con `connector-s3`, **y `connector-s3` con `INIT_PATH` no vacío (KO si falta o es exactamente `/`: errata `INTI_PATH` y el driver S3 rechaza la raíz; lo fija `S3_INIT_PATH`, def. `/<bucket>`)**. *Si falla*: cada KO dice qué script repetir.

**14f. Lanzamiento (lo ejecuta LA PERSONA USUARIA)**: `$AL launch` descarga el universo fresco e **imprime** el `docker run` (la skill nunca lo ejecuta: `--run`/`--force` rechazados). Monta `<APPS_LAYER_DIR>` en `/apps-layer`,
el workspace en `/workspace`, `docker.sock`, `<APPS_LAYER_DIR>/aws` en `/root/.aws:ro`, el zip y el `.lst` sobre `/apps-layer-automation/universe/`, y lleva `--add-host admin.<EXTERNAL_DOMAIN>:<IP del NLB>`
(`desa.int` no está delegado; `NLB_IP` si no se resuelve) y `--net host --cgroupns host`. Dentro del contenedor:
```bash
source /apps-layer/.env && cd /apps-layer
apps-installer <cluster>.yaml            # tenant keos (gobierno)
# punto de control sscc-s3 (14g) cuando connectors-management esté Running
apps-installer <cluster>-dev.yaml        # tenant dev
```
El entrypoint recrea el contenedor hermano `keos-installer_<cluster>` (hace `docker rm -f` del anterior: **no lances un segundo contenedor apps-layer**), `apps-installer` sube la memoria de `cct-orchestrator`
a 10Gi y hace `helm rollback cct` al salir (también con Ctrl-C). Relanzar es seguro: salta tenants/apps `success`+`ready`. Un contenedor ya arrancado no ve los ficheros nuevos: hay que relanzarlo.

**14g. Checkpoints y validación (solo lectura, `$AL check` y kubectl con el kubeconfig propio)**:
1. **Tras `connectors-management` (tenant dev) — PARAR si falla**: `kubectl -n dev-apps exec <pod connectors-management> -- curl -s "http://connectors-management.dev-apps/v1/api/connector/findByName?name=sscc-s3"`
   (`$AL check --no-aws` lo hace y marca KO). **Vacío => parar** (Ctrl-C; el `trap` hace `helm rollback cct`): virtualizer, rocket, eureka-agent y connector-s3 no funcionarán. Es el **riesgo abierto principal**: sin verificar contra el connectors-loader usado (2.2.0 por defecto; 2.2.3 con `CONNECTORS_LOADER_VERSION` vacía).
2. Imágenes: las de `stratio-releases.repo.stratio.com` llegan por el pull-through de ECR; `ImagePullBackOff` => mirar ahí primero.
3. Apps del tenant en CCT (`check`: pods con `cct.stratio.com/application_id`) y pods `Running/Completed` en `keos-core`, `dev-apps`, `dev-datastores`, `dev-rocket`, `dev-genai`, `dev-intelligence`, `dev-dlc`.
4. Variante S3: **sin** `hdfs` ni `connector-dfs-hdfs`; `connector-s3` (`dg-s3-agent`); virtualizer/rocket/eureka-agent con `s3a://<bucket>`; `pit` con `HDFS_USAGE_POLICY_POLICY_ENABLED=false`; ConfigMap `s3-config` en `dev-rocket`.
*Si falla una app*: copiar el error y relanzar `apps-installer` (reanuda); no borrar nada a mano en CCT (no hay desinstalador completo).

**14h. Backups y reporters de `enviroment-ready` (OPCIONAL, tras las apps; guía §7.5-7.6)**. La skill **avisa y pregunta** (AskUserQuestion) antes de nada; la guía los hace para el cliente, no son obligatorios y **actúan sobre el clúster**. Si acepta:
1. `$AL backups-env --dry-run` (muestra el contenido) y `$AL backups-env`: escribe **solo** `<APPS_LAYER_DIR>/backups.env` (600, 4 líneas **sin comillas**: `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_BUCKET_NAME`=`VELERO_BUCKET`, `AWS_IAM_ROLE_NAME`=`VELERO_ROLE` (nombre, no ARN); `SC_POSTGRES` opcional; `.bak` si cambia) e imprime los avisos. No ejecuta aws/kubectl/docker/`enviroment-ready`.
   Es el bucket y el rol IRSA de **Velero** (paso 10), no el de `ENABLE_BACKUPS_BUCKET` (otro bucket con claves estáticas, para GitOps). Comprueba antes que `aws s3api head-bucket` y `iam get-role` los encuentran (solo lectura) y que Velero está desplegado (13b).
2. **La persona usuaria** lo lanza dentro del contenedor de apps-layer (el que imprimió `launch`): `cd /apps-layer && enviroment-ready --backups backups.env`. Hace `keos backup create idp vault` (puntual), escribe `override_vars/velero.yaml` en el workspace si no existe, **relanza `keos backup velero`** y crea PVC `<pg>-backup-pvc` (40Gi) + `PgBackup` diario 01:00 por PgCluster si no existen.
   Avisar: los PVC `<pgcluster>-backup-pvc` quedan `Pending` (`WaitForFirstConsumer`) hasta el primer backup: es normal. Con IRSA necesita el override `keos-backup-velero.yaml` (12a); los backups diarios de IdP/vault son `keos backup schedule vault idp` (13b). El escalonado y los PVC 50/50/80Gi del cliente **no se adoptan**. Validación: `kubectl -n keos-backup get bsl aws` = `Available`.
3. **Reporters (aún más opcional)**: `enviroment-ready --reporter backups.env` (exige un fichero aunque no lo use) crea el namespace `keos-reports`, la GlobalNetworkPolicy `allow-all-traffic-from-keos-reports` y 3 HelmReleases (`postgresql-statistics-report`, `keos-versions-reporter`, `functional-monitoring`). Avisar: (a) `functional-monitoring` necesita el chart 0.3.1 y la imagen `stratio/functional-monitoring:0.3.1`, que puede no estar en el ECR `717279725338` (`ImagePullBackOff`; hay que subirla desde `qa.int.stratio.com`; el universe 15.1 espera la 0.3.2, cuyo chart no está en `helm-15.1`);
   (b) su hook falla con `i/o timeout` a `thanos-query.keos-metrics:9090` por el selector `name == 'keos-reports'` de la GlobalNetworkPolicy: el parche está en el aviso de `backups-env` y **un nuevo `--reporter` lo pisa**. Subir imágenes al ECR central es infraestructura compartida: no lo hace la skill (README raíz, regla 3).
Con la imagen `15.1-0.1.0-M1/M2` (o un SNAPSHOT posterior al 11-11) `--reporter` exige el workspace montado también en su ruta del host dentro del contenedor: `launch-apps-layer.sh` ya lo monta (ver `ffecfe8f`); si lanzas el `docker run` a mano, añade `-v $KEOS_WORKSPACE_DIR:$KEOS_WORKSPACE_DIR`.
**No probado**: `enviroment-ready`/`backups-env` nunca contra `apps-installer` ni un clúster real.

## 15. Eliminación

Ver `teardown.md` (dry-run por defecto, `scripts/teardown.sh`). **La fase A (apps-layer) va PRIMERO**, antes de borrar el EKS: contenedores `apps-layer-<cluster>` y `keos-installer_<cluster>`, directorio efímero
y, solo con `--delete-s3-requisites`, bucket/stack/usuario S3 (`backups.env` está dentro del directorio efímero: se borra con él; `override_charts_values/` es local regenerable, grupo A de la fase 8). Tu propio finder/remover (conda `marketplace`, `/stratio/aws/aws-marketplace-toolkit/`) sirve como barrido posterior; la skill no lo ejecuta.
