# Instalación de un clúster EKS "legacy" con cloud-provisioner

> **Nota:** la skill `legacy-eks-cluster` (`.claude/skills/legacy-eks-cluster/`) es la versión **reutilizable por cuenta + clúster**
> de esta guía (parte solo del nº de cuenta y del nombre del clúster, deriva las variables, aprovisiona y desinstala con guardas).
> Esta guía es el procedimiento manual validado para **este** clúster (`igualdad-dgutierrez`) y su referencia de lectura.
>
> **Dónde estamos:** esta guía vive en `1-aws-cluster/` del workspace `/stratio/e/igualdad/` (índice general en `../README.md`).
> **La raíz del workspace es también el workspace de keos-installer** (se monta como `/workspace`): `keos.yaml`, `secrets.yml`,
> `override_vars/`, `pki/`, `requirements/`, `logs/`, `.kube/` y `.config/` **no se mueven**. Los scripts y plantillas están en
> `1-aws-cluster/`; lo generado con secretos o estado, en `1-aws-cluster/estado/`.
> **Convención:** salvo que se indique otra cosa, los comandos se ejecutan **desde la raíz del workspace** (`cd /stratio/e/igualdad`).

Guía reutilizable para crear un clúster como el del cliente (cloud-provisioner con `gitops_enabled: false`),
basada en `instalacion-cliente-legacy.md` de la PR Stratio/keos-fleet#220 (PLT-4419), sincronizada con su HEAD **`1a1bbda`** (2026-11-05; sincronización anterior `2d36d7d`, 2026-10-29). Entre ambas solo cambian, para el legacy, tres notas técnicas (grupo de administración de discovery, PVC de backup `Pending`, JVM de HDFS: no aplica a S3) y una reescritura de la guía; ver `README.md` raíz y `references/gotchas.md` de la skill. Todo lo específico de
un entorno (nombre, cuenta, dominio, red, versiones) está en `cluster.env` (raíz del workspace); para otro clúster basta con otro
`cluster.env` y repetir los pasos (los scripts de render aceptan la ruta de otro `cluster.env` como argumento).

Se ejecuta por pasos y cada paso termina con una **validación**: no se pasa al siguiente hasta que da OK.
Los pasos 1-3 y 8-11 crean recursos en AWS. Los pasos 5 (cloud-provisioner) y 13 (`keos install`) se lanzan a mano en otro terminal, y también el **13b opcional** (post-install, dentro del contenedor keos-installer) y el **14h opcional** (backups y reporters, dentro del contenedor de apps-layer).
**Opciones post-install (13b/14h): ninguna es obligatoria** según la guía de origen (todo lo que describe es "como el clúster del cliente"); la única excepción es un requisito técnico condicional (`useSecret: false` de Velero con IRSA, paso 12). Se activan con flags `export ENABLE_X=true` en `cluster.env` (todos `false` por defecto) y **tres de ellos cambian `keos.yaml`, así que hay que decidirlos antes del paso 13** (ver paso 12).

## Ficheros

| Fichero (ruta desde la raíz del workspace) | Para qué |
|---|---|
| `cluster.env` (raíz), plantilla `1-aws-cluster/cluster.env.example` | Variables del clúster. Sin secretos. Única configuración; la leen también los scripts del kit (`2-apps-layer-kit`). |
| `1-aws-cluster/create-test-vpc.sh` | Crea VPC + subnets (públicas y privadas) + NAT. Escribe por defecto `1-aws-cluster/estado/${CLUSTER_NAME}.json`. |
| `1-aws-cluster/cluster.yaml.tpl` | Plantilla del descriptor de cloud-provisioner. |
| `1-aws-cluster/render-cluster.sh` | Genera `1-aws-cluster/estado/cluster.yaml` a partir de la plantilla, `cluster.env`, el JSON de la VPC y las claves IAM. |
| `1-aws-cluster/estado/cluster.yaml` | Generado. **Contiene access/secret key**: permisos 600, no se sube a git. |
| `1-aws-cluster/estado/` | Estado y generados con secretos (700): `cluster.yaml`, `${CLUSTER_NAME}.json`, `kubeconfig-${CLUSTER_NAME}` (600), log de la VPC y `.work/` (JSON de políticas IAM). Ignorado por git. |
| `1-aws-cluster/keos.yaml.tpl`, `1-aws-cluster/override_vars.yaml.tpl`, `1-aws-cluster/render-keos.sh` | Fase 2: generan `keos.yaml` y `override_vars/<cluster>.yaml` **en la raíz del workspace** para keos-installer (con `ENABLE_BACKUP_VELERO=true`, además `override_charts_values/keos-backup-velero.yaml`). |
| `1-aws-cluster/render-postinstall.sh` | Paso 13b (opcional): **solo imprime** los comandos post-install a lanzar dentro del contenedor keos-installer, según los flags de `cluster.env`. No ejecuta nada ni escribe ficheros. |
| `secrets.yml`, `keos.yaml`, `keos.yaml.cloud-provisioner`, `override_vars/`, `.kube/config` (todos en la raíz) | Generados por cloud-provisioner / keos-installer (credenciales cifradas con `VAULT_PASSWORD`; kubeconfig con token de corta vida). **No mover.** |
| `2-apps-layer-kit/` | Fase 3 (apps-layer con S3). Ver `2-apps-layer-kit/README.md`. |
| `docs/` | Arquitectura (HTML) y `docs/backup-originales/` (versiones previas a la fase 2 y backup de objetos de CAPI). |

## Progreso

| Paso | Qué | Estado |
|---|---|---|
| 0 | Preparación y variables | ✅ |
| 1 | Usuario IAM `cloud-provisioner` | ✅ |
| 2 | Policy de pull through cache de ECR | ✅ |
| 2b | Acceso al ECR central (comprobación) | ✅ |
| 3 | VPC y subnets | ✅ |
| 4 | Renderizar `cluster.yaml` | ✅ |
| 5 | cloud-provisioner (lo lanzas tú) | ✅ |
| 6 | Validación del clúster | ✅ |
| 7 | Variables derivadas del clúster | ✅ |
| 8 | Zonas Route53 | ✅ |
| 9 | Rol IRSA de external-dns | ✅ |
| 10 | Bucket y rol IRSA de velero | ✅ |
| 11 | EFS (+ permiso IAM en el rol de nodos) | ✅ |
| 12 | Workspace de keos-installer (`render-keos.sh`) | ✅ |
| 13 | `keos install` (lo lanzas tú) | ⬜ |
| 13b | Post-install opcional: monitoring, Velero, backups programados, central logging, falco (`render-postinstall.sh`; lo lanzas tú) | ⬜ opcional |
| — | Fase 3: apps-layer con S3 (fuera de esta guía: `2-apps-layer-kit/README.md`) | ➡️ siguiente |
| 14h | Backups y reporters de la plataforma con `enviroment-ready` (opcional, fase 3; sección «Fase 3» más abajo; lo lanzas tú) | ⬜ opcional |
| 14 | Limpieza (solo cuando toque) | ⬜ |

---

## 0. Preparación

### 0.1 Binario de cloud-provisioner

cloud-provisioner es el proyecto [Stratio/kind](https://github.com/Stratio/kind) (fork de kind). Sus releases de
GitHub no traen binarios; se compila desde el tag de la versión elegida (`CLOUD_PROVISIONER_VERSION`) o se usa un
binario ya disponible (el empaquetado se sube a un Nexus interno). Compilar necesita Go (el `go.mod` pide 1.26, el
`go` del sistema puede ser más antiguo: con `GOTOOLCHAIN=auto` descarga el toolchain) y varios GB libres en disco.

```bash
# Solo si no tienes ya el binario de esa versión
git clone --depth 1 --branch "$CLOUD_PROVISIONER_VERSION" https://github.com/Stratio/kind.git ~/src/cloud-provisioner-$CLOUD_PROVISIONER_VERSION
cd ~/src/cloud-provisioner-$CLOUD_PROVISIONER_VERSION
FORCE_HOST_GO=1 GOTOOLCHAIN=auto make clean build      # deja bin/cloud-provisioner
./bin/cloud-provisioner version                        # debe mostrar $CLOUD_PROVISIONER_VERSION
cd -
```

El binario resultante es el que va en `CLOUD_PROVISIONER_BIN` (ruta absoluta). Importante: sin `--build-stratio-image`,
cloud-provisioner **descarga** la imagen de arranque `$ECR_REGISTRY/stratio/cloud-provisioner:<versión del binario>`,
así que esa imagen tiene que existir en el ECR con ese tag (ver paso 2b).

### 0.2 Variables

```bash
cd /stratio/e/igualdad                  # raíz del workspace (todos los comandos de la guía parten de aquí)
cp 1-aws-cluster/cluster.env.example cluster.env   # solo la primera vez; ajustar CLUSTER_NAME, cuenta, versión, etc.
# editar cluster.env y rellenar CLOUD_PROVISIONER_BIN con la ruta absoluta del binario
source ./cluster.env
export AWS_PAGER=""                      # evita que el paginador de aws deje colgado el terminal
export VAULT_PASSWORD='...'             # solo en tu terminal; no se escribe en ningún fichero
```

`ADMIN_PROFILE` es un perfil con acceso de administrador a la cuenta (aquí `igualdad`, un rol asumido sobre la
cuenta 821111360971). `CP_PROFILE` (`cloud-provisioner`) es el perfil del usuario IAM que crea el paso 1.

**Validación**

```bash
for t in aws jq yq envsubst kubectl helm docker; do command -v $t >/dev/null && echo "ok  $t" || echo "FALTA $t"; done
type -a aws | head -3; aws --version                                              # los scripts bash usan el primer aws del PATH: debería ser la v2 (la v1 vale, pero avisa)
docker info >/dev/null 2>&1 && echo "ok  docker en marcha" || echo "FALTA docker en marcha"
"$CLOUD_PROVISIONER_BIN" --help >/dev/null 2>&1 && echo "ok  cloud-provisioner" || echo "FALTA CLOUD_PROVISIONER_BIN"
"$CLOUD_PROVISIONER_BIN" version | grep -q "$CLOUD_PROVISIONER_VERSION" && echo "ok  versión $CLOUD_PROVISIONER_VERSION" || echo "KO  la versión del binario no coincide"
[ -n "$VAULT_PASSWORD" ] && echo "ok  VAULT_PASSWORD definido" || echo "FALTA VAULT_PASSWORD"
df -h / | tail -1                                                                  # hay que tener varios GB libres para las imágenes de kind
aws sts get-caller-identity --profile "$ADMIN_PROFILE" --query Account --output text   # = $AWS_ACCOUNT_ID
aws eks list-clusters --region "$AWS_REGION" --profile "$ADMIN_PROFILE" --query 'clusters' --output text
```

OK si: todo `ok`, la cuenta coincide con `AWS_ACCOUNT_ID` y no existe ya un clúster con el mismo nombre.

## 1. Usuario IAM para cloud-provisioner

Usuario `cloud-provisioner` con `AdministratorAccess` en la cuenta. Su access key se guarda en el perfil
`$CP_PROFILE` sin mostrarla por pantalla: son las mismas claves que van en `spec.credentials.aws` del descriptor.
IAM es global por cuenta: se crea una sola vez por cuenta. Si el usuario ya existe, **no crees otra key
sin mirar** (el máximo es 2 por usuario): revisa con `aws iam list-access-keys`.

```bash
aws iam get-user --user-name cloud-provisioner --profile "$ADMIN_PROFILE" --query User.Arn --output text   # NoSuchEntity = hay que crearlo

aws iam create-user --user-name cloud-provisioner --profile "$ADMIN_PROFILE"
aws iam attach-user-policy --user-name cloud-provisioner \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess --profile "$ADMIN_PROFILE"

read -r ACCESS_KEY_ID SECRET_ACCESS_KEY < <(aws iam create-access-key --user-name cloud-provisioner \
  --profile "$ADMIN_PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
aws configure set aws_access_key_id "$ACCESS_KEY_ID" --profile "$CP_PROFILE"
aws configure set aws_secret_access_key "$SECRET_ACCESS_KEY" --profile "$CP_PROFILE"
aws configure set region "$AWS_REGION" --profile "$CP_PROFILE"
unset ACCESS_KEY_ID SECRET_ACCESS_KEY
```

**Validación** (la propagación de IAM puede tardar unos segundos: reintenta)

```bash
aws sts get-caller-identity --profile "$CP_PROFILE"     # Arn = arn:aws:iam::<cuenta>:user/cloud-provisioner
aws iam list-access-keys --user-name cloud-provisioner --profile "$CP_PROFILE" --query 'AccessKeyMetadata[].[AccessKeyId,Status]' --output text
aws iam list-attached-user-policies --user-name cloud-provisioner --profile "$CP_PROFILE" --query 'AttachedPolicies[].PolicyName' --output text
```

OK si: `Account` = `AWS_ACCOUNT_ID`, `Arn` termina en `user/cloud-provisioner`, una key `Active` y `AdministratorAccess` adjunta.

## 2. Policy del pull through cache de ECR

Una vez por cuenta. Permite a los nodos importar imágenes del registry upstream en el pull through cache de ECR;
es la que se referencia en `spec.security.aws.nodegroup_extra_policy_arn` del descriptor.

```bash
aws iam get-policy --policy-arn "$ECR_POLICY_ARN" --profile "$CP_PROFILE" --query Policy.Arn --output text 2>/dev/null \
  || aws iam create-policy --policy-name "$ECR_POLICY_NAME" --profile "$CP_PROFILE" --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    { "Action": ["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"], "Effect": "Allow", "Resource": ["*"] }
  ]
}'
```

**Validación**

```bash
aws iam get-policy --policy-arn "$ECR_POLICY_ARN" --profile "$CP_PROFILE" --query 'Policy.[Arn,DefaultVersionId]' --output text
aws iam get-policy-version --policy-arn "$ECR_POLICY_ARN" --version-id v1 --profile "$CP_PROFILE" \
  --query 'PolicyVersion.Document.Statement[0].Action' --output text
```

OK si: el ARN coincide con `ECR_POLICY_ARN` y las acciones son `ecr:BatchImportUpstreamImage` y `ecr:CreateRepository`.

## 2b. Acceso al ECR central (comprobación previa, lectura)

Esta policy solo da permiso del lado IAM. La URL del registry (`$ECR_REGISTRY`, cuenta `717279725338`) es de otra
cuenta, y cloud-provisioner la usa con las claves del usuario `cloud-provisioner` **antes** de que existan los nodos:
`docker pull` de la imagen de arranque, descarga de los charts OCI (`/helm-15.1`, `$KEOS_HELM_PATH`) y las imágenes con prefijo
(`/docker.io`, `/quay.io`, `/ghcr.io`, `/registry.k8s.io`, `/public.ecr.aws`) de las reglas de pull through cache, que
viven en esa cuenta y no hay que crearlas en la tuya. Que la cuenta destino pueda leer ese registry lo decide la
política del registry/repositorios de `717279725338`, no algo que se configure aquí. Se asume que ya lo permite; esta
comprobación lo confirma en segundos en vez de al cabo de minutos de instalación:

```bash
aws ecr get-login-password --region "$AWS_REGION" --profile "$CP_PROFILE" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker manifest inspect "$ECR_REGISTRY/stratio/cloud-provisioner:$CLOUD_PROVISIONER_VERSION" >/dev/null \
  && echo "ok  imagen de arranque accesible" || echo "KO  no se puede leer la imagen de arranque"
```

OK si: el login da `Login Succeeded` y la imagen es accesible. Si falla con `denied`/`not authorized`, hay que pedir a
quien administre la cuenta `717279725338` que permita la lectura a la cuenta `AWS_ACCOUNT_ID`. Si falla con
`not found`, esa versión no está publicada en el registry: cambiar `CLOUD_PROVISIONER_VERSION`.
Nota: el `docker login` guarda un token (12 h) en `~/.docker/config.json`.

## 3. VPC y subnets

VPC `$VPC_CIDR` en `$VPC_AZS` AZs, con una subnet pública y una privada por AZ y los NAT Gateways según
`$VPC_NAT_MODE` (`single` = uno compartido). El script aborta si ya existe una VPC con ese `Name`.
Tarda unos minutos (espera a que el NAT esté `available`).

```bash
bash 1-aws-cluster/create-test-vpc.sh --name "$CLUSTER_NAME" --azs "$VPC_AZS" --region "$AWS_REGION" \
  --profile "$CP_PROFILE" --vpc-cidr "$VPC_CIDR" --nat-mode "$VPC_NAT_MODE" --output "1-aws-cluster/estado/${CLUSTER_NAME}.json"
```

**Validación**

```bash
VPC_ID=$(jq -r .vpc_id "1-aws-cluster/estado/${CLUSTER_NAME}.json"); echo "$VPC_ID"
cpaws() { aws --profile "$CP_PROFILE" --region "$AWS_REGION" "$@"; }   # función (en zsh una variable con opciones no se divide en palabras)
cpaws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].[State,CidrBlock]' --output text                 # available <cidr>
cpaws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text    # True
cpaws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text # True
cpaws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[].[AvailabilityZone,SubnetId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' --output text | sort
cpaws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC_ID" --query 'NatGateways[].[NatGatewayId,State]' --output text
cpaws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,Routes[?DestinationCidrBlock==`0.0.0.0/0`]|[0].GatewayId,Routes[?DestinationCidrBlock==`0.0.0.0/0`]|[0].NatGatewayId]' --output text
```

OK si: VPC `available` con DNS support y hostnames a `True`; `2 × VPC_AZS` subnets repartidas por AZ; NAT(s) `available`;
la route table `-public` sale por `igw-…` y las `-private-N` por `nat-…`.

## 4. Descriptor `cluster.yaml`

Se genera, no se edita a mano. `render-cluster.sh` lee `cluster.env` (raíz), `vpc_id` y las subnets privadas de
`1-aws-cluster/estado/${CLUSTER_NAME}.json` y las claves del perfil `$CP_PROFILE`, y escribe
`1-aws-cluster/estado/cluster.yaml`; falla si falta algo o queda algún `${...}` sin resolver. Para otro clúster:
`1-aws-cluster/render-cluster.sh /ruta/otro/cluster.env` (overrides por entorno: `OUT`, `TPL`, `NETWORK_JSON`, `STATE_DIR`).

Según la PR (desde `2d36d7d`) el descriptor lleva `helm_repository.url: oci://$ECR_REGISTRY/$KEOS_HELM_PATH` (por defecto `helm-15.1`; antes era `/helm`; si `KEOS_HELM_PATH` falta en `cluster.env`, el render usa `helm-15.1`) y
`control_plane.aws.logging.authenticator: true` (antes `false`; sin flag). `cluster_operator_version` se mantiene en `0.7.4` (la guía de la PR también lo fija).

```bash
1-aws-cluster/render-cluster.sh
```

**Validación**

```bash
CY=1-aws-cluster/estado/cluster.yaml
ls -l "$CY" | cut -c1-10                                             # -rw-------
grep -c '\${' "$CY"                                                  # 0
yq -r '[.kind, .metadata.name] | @tsv' "$CY"                         # KeosCluster y ClusterConfig con el nombre esperado
yq -r 'select(.kind=="KeosCluster") | [.spec.external_domain, .spec.region, .spec.networks.vpc_id, (.spec.networks.subnets|length)] | @tsv' "$CY"
yq -r 'select(.kind=="KeosCluster") | .spec.networks.subnets[].subnet_id' "$CY" | while read s; do
  aws ec2 describe-subnets --subnet-ids "$s" --profile "$CP_PROFILE" --region "$AWS_REGION" \
    --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone,MapPublicIpOnLaunch]' --output text; done
yq -r 'select(.kind=="ClusterConfig") | .spec.gitops_enabled' "$CY"  # false
yq -r 'select(.kind=="KeosCluster") | .spec.security.aws.nodegroup_extra_policy_arn' "$CY"   # = ECR_POLICY_ARN
yq -r 'select(.kind=="KeosCluster") | .spec.helm_repository.url' "$CY"                       # oci://<ECR>/helm-15.1
yq -r 'select(.kind=="KeosCluster") | .spec.control_plane.aws.logging.authenticator' "$CY"   # true
```

OK si: permisos `600`, ningún `${`, las 3 subnets pertenecen a `vpc_id`, están en AZs distintas, son privadas
(`MapPublicIpOnLaunch` = `False`), `gitops_enabled` es `false`, `helm_repository.url` termina en `/helm-15.1` y `authenticator` es `true`.

## 5. cloud-provisioner (lo lanzas tú, en otro terminal)

En el otro terminal, **desde la raíz del workspace** (cloud-provisioner escribe `secrets.yml`, `keos.yaml` y
`override_vars/` en el directorio actual, y esa raíz es la que luego monta keos-installer como `/workspace`), con
`cluster.env` cargado y `VAULT_PASSWORD` exportado:

```bash
cd /stratio/e/igualdad
source ./cluster.env
export VAULT_PASSWORD='...'
export AWS_PROFILE="$CP_PROFILE"

"$CLOUD_PROVISIONER_BIN" create cluster --name "$CLUSTER_NAME" --descriptor 1-aws-cluster/estado/cluster.yaml \
  --vault-password "$VAULT_PASSWORD" --retain --delete-previous
```

Antes de lanzarlo en serio, valida el descriptor (lee `1-aws-cluster/estado/cluster.yaml`, comprueba credenciales y permisos de AWS; **no** crea
nada ni escribe `secrets.yml`). Debe terminar con `Cluster descriptor is valid`:

```bash
"$CLOUD_PROVISIONER_BIN" create cluster --name "$CLUSTER_NAME" --descriptor 1-aws-cluster/estado/cluster.yaml \
  --vault-password "$VAULT_PASSWORD" --validate-only
```

El `create` real descarga la imagen de arranque del ECR, crea un clúster kind local en Docker y deja en la raíz del workspace
`secrets.yml` (credenciales cifradas con `VAULT_PASSWORD`; guarda esa contraseña, se pide en ejecuciones posteriores) y
`keos.yaml` (el descriptor para keos-installer). Según la documentación de Stratio/kind, tras la primera ejecución la
sección `credentials` ya no se lee del descriptor sino de `secrets.yml`.

Mientras corre (decenas de minutos) se puede seguir su avance desde aquí, solo lectura:

```bash
cpaws() { aws --profile "$CP_PROFILE" --region "$AWS_REGION" "$@"; }   # función (en zsh una variable con opciones no se divide en palabras)
cpaws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.[status,version]' --output text    # CREATING → ACTIVE
cpaws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --output text
cpaws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text
cpaws route53 list-hosted-zones-by-name --dns-name "$EXTERNAL_DOMAIN" --query 'HostedZones[].[Name,Id,Config.PrivateZone]' --output text
cpaws ecr describe-pull-through-cache-rules --query 'pullThroughCacheRules[].[ecrRepositoryPrefix,upstreamRegistryUrl]' --output text
```

Con `gitops_enabled: false`, cloud-provisioner instala su propio Flux (release `flux` en `kube-system`) y lo que
gestiona a través de él (cluster-autoscaler, keoscluster-controller), igual que en el clúster del cliente.

Si algo falla, copia el error en esta sesión antes de relanzar. Tras un fallo a medias, `--delete-previous` borra el
clúster local previo, pero los recursos creados en AWS pueden quedar: revisarlos antes de reintentar.

## 6. Validación del clúster

Kubeconfig: cloud-provisioner deja `.kube/config` (raíz; tras `keos install` pasa a ser de root), pero su token caduca
en minutos. Generar uno propio fuera de `.kube/`, en el directorio de estado (600; lo reutiliza el kit de apps-layer):

```bash
export KUBECONFIG="$PWD/1-aws-cluster/estado/kubeconfig-$CLUSTER_NAME"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$CP_PROFILE" --kubeconfig "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
```

```bash
cpaws() { aws --profile "$CP_PROFILE" --region "$AWS_REGION" "$@"; }   # función (en zsh una variable con opciones no se divide en palabras)
cpaws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.[status,version,identity.oidc.issuer]' --output text
# cloud-provisioner crea un managed nodegroup POR AZ (<cluster>_<NODEGROUP_NAME>-mp-0/1/2): quantity/min/max se reparten entre ellos
for ng in $(cpaws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query nodegroups --output text); do
  cpaws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
    --query 'nodegroup.[nodegroupName,status,scalingConfig.minSize,scalingConfig.maxSize,scalingConfig.desiredSize,instanceTypes[0]]' --output text
done
kubectl get nodes -o wide
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'          # vacío
kubectl get pods -A --no-headers | grep -Ei 'ImagePull|ErrImage' || echo "sin errores de pull"
helm ls -A                                                                          # release flux en kube-system
kubectl get pods -A --no-headers | grep -Ei 'flux|autoscaler|keoscluster'
cpaws iam list-open-id-connect-providers --output text
cpaws route53 list-hosted-zones-by-name --dns-name "$EXTERNAL_DOMAIN" --query 'HostedZones[].[Name,Config.PrivateZone]' --output text
```

OK si: clúster y los 3 nodegroups `ACTIVE` (1 por AZ, min 1 / max 2 / desired 1 cada uno con `NODE_*` 3/6), versión `1.35`, `NODE_QTY` nodos `Ready`, ningún pod fuera de
`Running`/`Completed`, ningún `ImagePullBackOff` (confirma que la cuenta puede tirar del ECR `$ECR_REGISTRY`),
release `flux` presente, proveedor OIDC asociado y zona Route53 de `$EXTERNAL_DOMAIN` creada.

## Fase 2: de cloud-provisioner a `keos install`

Basada en las secciones 5 y 6.1-6.4 de la PR (HEAD `1a1bbda`; la guía de la PR se renumeró: antes 6.2 incluía `override_charts_values` y 6.3 era la instalación). Con el clúster creado, keos-installer 1.4.2 necesita en la
cuenta: zonas DNS y rol IRSA de external-dns, bucket y rol IRSA de velero, y el EFS de su StorageClass. Los pasos
8-11 **crean recursos en AWS**; se hacen uno a uno con confirmación. Los ficheros temporales (JSON de políticas)
van a `1-aws-cluster/estado/.work/` (variable `$WORK` del paso 7), no a `/tmp`.

Cada terminal nuevo necesita el bloque del paso 7 (las variables derivadas no se guardan en ningún fichero).

### 7. Variables derivadas del clúster (solo lectura)

```bash
export AWS_PAGER=""
cd /stratio/e/igualdad && source ./cluster.env
export AWS_PROFILE="$CP_PROFILE" AWS_DEFAULT_REGION="$AWS_REGION"
export WORK=1-aws-cluster/estado/.work         # JSON de políticas IAM temporales (relativo a la raíz del workspace)
mkdir -p "$WORK"

export VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
export SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.subnetIds' --output text)
export CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
export OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.identity.oidc.issuer' --output text | sed 's#^https://##')
: "${OIDC_ISSUER:?clúster no encontrado, no seguir}"
export PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones --output text --query "HostedZones[?!(Config.PrivateZone) && Name=='${EXTERNAL_DOMAIN}.'].Id")
export PRIVATE_ZONE_ID=$(aws route53 list-hosted-zones --output text --query "HostedZones[?Config.PrivateZone && Name=='${EXTERNAL_DOMAIN}.'].Id")
echo "vpc=$VPC_ID sg=$CLUSTER_SG oidc=$OIDC_ISSUER"; echo "subnets=$SUBNET_IDS"; echo "zonas: pública='$PUBLIC_ZONE_ID' privada='$PRIVATE_ZONE_ID'"
```

OK si: `vpc` es el de `1-aws-cluster/estado/${CLUSTER_NAME}.json`, `subnets` son las 3 privadas y `oidc` no está vacío.

### 8. Zonas DNS de `$EXTERNAL_DOMAIN` (crea recursos)

Una zona pública y otra privada asociada a la VPC. Solo se crea la que falte (cloud-provisioner con
`dns.manage_zone: true` **no** ha creado ninguna en esta cuenta). La delegación NS de la zona pública en el dominio
padre `desa.int` no forma parte de la PR; no hace falta para que `keos install` funcione dentro de la VPC.

```bash
[ -n "$PUBLIC_ZONE_ID" ]  || aws route53 create-hosted-zone --name "$EXTERNAL_DOMAIN" --caller-reference "${CLUSTER_NAME}-public-$(date +%s)" >/dev/null
[ -n "$PRIVATE_ZONE_ID" ] || aws route53 create-hosted-zone --name "$EXTERNAL_DOMAIN" --caller-reference "${CLUSTER_NAME}-private-$(date +%s)" \
  --vpc VPCRegion="$AWS_REGION",VPCId="$VPC_ID" >/dev/null
export PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones --output text --query "HostedZones[?!(Config.PrivateZone) && Name=='${EXTERNAL_DOMAIN}.'].Id")
export PRIVATE_ZONE_ID=$(aws route53 list-hosted-zones --output text --query "HostedZones[?Config.PrivateZone && Name=='${EXTERNAL_DOMAIN}.'].Id")
echo "pública=$PUBLIC_ZONE_ID privada=$PRIVATE_ZONE_ID"
aws route53 get-hosted-zone --id "$PRIVATE_ZONE_ID" --query 'VPCs[].VPCId' --output text   # = $VPC_ID
```

OK si hay exactamente una zona pública y una privada y la privada tiene la VPC del clúster.

### 9. Rol IRSA de external-dns (crea recursos)

Lo asume la ServiceAccount `kube-system/external-dns` y solo modifica registros de esas dos zonas.

```bash
cat > "$WORK"/external-dns-trust.json <<EOF
{ "Version": "2012-10-17", "Statement": [ { "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": { "StringEquals": {
    "${OIDC_ISSUER}:sub": "system:serviceaccount:kube-system:external-dns",
    "${OIDC_ISSUER}:aud": "sts.amazonaws.com" } } } ] }
EOF
cat > "$WORK"/external-dns-policy.json <<EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["route53:ChangeResourceRecordSets"],
    "Resource": ["arn:aws:route53:::${PUBLIC_ZONE_ID#/}", "arn:aws:route53:::${PRIVATE_ZONE_ID#/}"] },
  { "Effect": "Allow", "Action": ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"],
    "Resource": ["*"] } ] }
EOF
aws iam create-role --role-name "${CLUSTER_NAME}-external-dns" --assume-role-policy-document file://$WORK/external-dns-trust.json >/dev/null
aws iam create-policy --policy-name "${CLUSTER_NAME}-external-dns" --policy-document file://$WORK/external-dns-policy.json >/dev/null
aws iam attach-role-policy --role-name "${CLUSTER_NAME}-external-dns" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-external-dns"
aws iam list-attached-role-policies --role-name "${CLUSTER_NAME}-external-dns" --output text
```

OK si el rol existe con la policy adjunta y `sub` = `system:serviceaccount:kube-system:external-dns`.

### 10. Bucket y rol IRSA de velero (crea recursos)

Bucket `$VELERO_BUCKET` (los nombres son globales, lleva la cuenta en el nombre) y rol `$VELERO_ROLE` (el de la PR,
`role_igualdad-desa-velero`, es el del cliente y chocaría con otro clúster en la cuenta). Lo asume la ServiceAccount
`keos-backup/velero-server`.

```bash
aws s3api create-bucket --bucket "$VELERO_BUCKET" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
cat > "$WORK"/velero-trust.json <<EOF
{ "Version": "2012-10-17", "Statement": [ { "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": { "StringEquals": {
    "${OIDC_ISSUER}:sub": "system:serviceaccount:keos-backup:velero-server",
    "${OIDC_ISSUER}:aud": "sts.amazonaws.com" } } } ] }
EOF
cat > "$WORK"/velero-policy.json <<EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags", "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot"], "Resource": "*" },
  { "Effect": "Allow", "Action": ["s3:GetObject", "s3:DeleteObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], "Resource": ["arn:aws:s3:::${VELERO_BUCKET}/*"] },
  { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": ["arn:aws:s3:::${VELERO_BUCKET}"] } ] }
EOF
aws iam create-role --role-name "$VELERO_ROLE" --assume-role-policy-document file://$WORK/velero-trust.json >/dev/null
aws iam create-policy --policy-name "${CLUSTER_NAME}-velero" --policy-document file://$WORK/velero-policy.json >/dev/null
aws iam attach-role-policy --role-name "$VELERO_ROLE" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-velero"
aws s3api head-bucket --bucket "$VELERO_BUCKET" && echo "bucket OK"
aws iam list-attached-role-policies --role-name "$VELERO_ROLE" --output text
```

### 11. EFS (crea recursos; incluye un permiso IAM sobre el rol de nodos)

EFS cifrado con un mount target en cada subnet privada. Los mount targets llevan el security group de los nodos
(`$CLUSTER_SG`), que ya admite todo el tráfico entre sus miembros (no hace falta regla NFS ni SG propio).

```bash
export EFS_ID=$(aws efs create-file-system --creation-token "$CLUSTER_NAME" --encrypted --tags Key=Name,Value="$CLUSTER_NAME" --query FileSystemId --output text)
until [ "$(aws efs describe-file-systems --file-system-id "$EFS_ID" --query 'FileSystems[0].LifeCycleState' --output text)" = available ]; do sleep 5; done
for SUBNET_ID in $(echo "$SUBNET_IDS"); do
  aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUBNET_ID" --security-groups "$CLUSTER_SG" >/dev/null
done
echo "$EFS_ID"
```

Política del sistema de archivos (montaje solo vía mount target y con TLS):

```bash
cat > "$WORK"/efs-fs-policy.json <<EOF
{ "Version": "2012-10-17", "Statement": [ { "Sid": "AccessThroughMountTarget", "Effect": "Allow", "Principal": {"AWS": "*"},
  "Action": ["elasticfilesystem:ClientRootAccess", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientMount"],
  "Resource": "arn:aws:elasticfilesystem:${AWS_REGION}:${AWS_ACCOUNT_ID}:file-system/${EFS_ID}",
  "Condition": { "Bool": { "aws:SecureTransport": "true", "elasticfilesystem:AccessedViaMountTarget": "true" } } } ] }
EOF
aws efs put-file-system-policy --file-system-id "$EFS_ID" --policy file://$WORK/efs-fs-policy.json >/dev/null
```

Permisos IAM del csi-controller. keos-installer no configura IRSA para el driver, así que usa el rol de los nodos
(`eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io` en EKS). La PR le añade la policy de ejemplo del driver.
**Ojo:** es un rol **de cuenta** (lo comparten todos los clústeres EKS que cree cloud-provisioner aquí) y todos los pods
de los nodos heredan permisos de EFS; además la policy se descarga de `master` sin versión fija: revísala antes de crearla.

```bash
curl -fsSL -o "$WORK"/efs-csi-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/master/docs/iam-policy-example.json
jq -r '.Statement[] | [.Effect, (.Action|join(","))] | @tsv' "$WORK"/efs-csi-policy.json     # revisar
aws iam create-policy --policy-name "${CLUSTER_NAME}-efs-csi" --policy-document file://$WORK/efs-csi-policy.json >/dev/null
aws iam attach-role-policy --role-name eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-efs-csi"
```

OK si: EFS `available`, 3 mount targets `available`, la política del FS aplicada y la policy adjunta al rol de nodos:

```bash
aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'MountTargets[].[SubnetId,LifeCycleState]' --output text
aws efs describe-file-system-policy --file-system-id "$EFS_ID" --query 'FileSystemId' --output text
aws iam list-attached-role-policies --role-name eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io --output text
```

### 12. Workspace de keos-installer (genera ficheros locales)

`1-aws-cluster/render-keos.sh` genera `keos.yaml` y `override_vars/${CLUSTER_NAME}.yaml` **en la raíz del workspace**
(`WORKSPACE_DIR`, por defecto el directorio padre del script) desde `keos.yaml.tpl` y `override_vars.yaml.tpl` (de `1-aws-cluster/`;
localiza el EFS por su creation-token). Conserva el `keos.yaml` que dejó cloud-provisioner en `keos.yaml.cloud-provisioner`
(también en la raíz). Lee `cluster.env` de la raíz (o el que le pases como argumento). Diferencias con el de cloud-provisioner: `flavour: production`, chart repo `/${KEOS_HELM_PATH}`
(no `/helm`) y el EFS (`providers: custom, csi-aws`). **Con todos los flags opcionales a `false` (defecto) la salida es idéntica a la de antes de la sincronización con `2d36d7d`.**

```bash
1-aws-cluster/render-keos.sh
diff keos.yaml.cloud-provisioner keos.yaml
```

**Opciones que cambian `keos.yaml` / `override_vars`: decidir AHORA, antes del paso 13.** Son opcionales (la guía de la PR las instala para el cliente, pero no las marca como obligatorias; ver abajo la
única excepción técnica). Se activan descomentando `export <FLAG>=true` en `cluster.env` (los flags se leen solo de ahí: un `ENABLE_X=true` exportado en la shell se ignora; solo `true` o `false`; cualquier otro valor aborta el render) y **repitiendo `render-keos.sh`**:

| Flag (defecto `false`) | Efecto en el render | Para qué |
|---|---|---|
| `ENABLE_BACKUP_VELERO` | `keos.yaml`: `keos.backup.storage_class: ${EFS_SC_NAME}`; `override_vars`: `velero_enable_snapshot_volumes: true`; fichero nuevo `override_charts_values/keos-backup-velero.yaml` con `credentials.useSecret: false` | Prepara `keos backup velero` (paso 13b). Sin `storage_class` el PVC `ReadWriteMany` de `keos backup create vault` queda `Pending` en EBS (`keos`, que no lo admite); `velero_enable_snapshot_volumes` viene desactivado desde keos-installer 1.4 |
| `KEOS_ENABLE_CLAMAV` | `keos.yaml`: `keos.security.clamav.enabled: true` | En 1.4.2 lo despliega `keos install` (el cliente lo instaló a mano en `kube-system`) |
| `ENABLE_FALCO` | `keos.yaml`: `keos.security.falco` con `enabled: false` **siempre** + `opensearch_output: true` | Falco con salida a OpenSearch. Con `enabled: true` el precheck de `keos install` falla ("Falco cannot be enabled during cluster installation"); se activa después (paso 13b) |

`ENABLE_MONITORING`, `ENABLE_CENTRAL_LOGGING` y `ENABLE_BACKUP_SCHEDULE` **no cambian ningún fichero**: solo añaden bloques al paso 13b y se pueden decidir después de `keos install`.

**Requisito técnico (no opcional si usas Velero):** con IRSA (`velero_object_storage_configuration_aws_iam_role_sa_enabled: true`, que ya llevan nuestras plantillas) keos-installer 1.4.2 pasa al chart `credentials.secretContents: {}` pero no `useSecret: false`: el chart crea un
Secret vacío y define `AWS_SHARED_CREDENTIALS_FILE`, y velero-plugin-for-aws v1.13.2 no usa el token de IRSA, así que la BackupStorageLocation queda `Unavailable` (`no EC2 IMDS role found`). Por eso `ENABLE_BACKUP_VELERO=true` genera
`override_charts_values/keos-backup-velero.yaml` (keos-installer copia estos ficheros, con nombre `<namespace>-<release>.yaml`, al ConfigMap `<namespace>/02-<release>-helm-chart-override-values` al desplegar cada chart). El render es idempotente: si ya existe con `useSecret: false` no lo toca; si existe con otro contenido lo conserva como `.bak.<epoch>`.

**No se adopta** de la guía: `flavour: custom` (valores del cliente: kyverno 3 réplicas, kerberos, un nodo de OpenSearch, `*_index_replicas: 0`), `kube-system-vpa.yaml` y `keos-cct-cct.yaml` (VPA y `HEAP_PERCENTAGE` del cliente). Si se quiere el flavour: volcar
`/stratio/ansible/inventory/group_vars/flavours/production.yml` de la imagen 1.4.2 (`docker run --rm --entrypoint cat "$KEOS_INSTALLER_IMAGE" ...`) a `override_vars/flavours/custom.yml`, editar `keos_flavour_app_definition` y poner `flavour: custom`.

**Validación** de las opciones elegidas (con las tres a `false` no debe aparecer nada de esto):

```bash
yq -r '.keos.backup.storage_class // "-"' keos.yaml                          # efs-<cluster> con ENABLE_BACKUP_VELERO
grep -n velero_enable_snapshot_volumes override_vars/${CLUSTER_NAME}.yaml    # true con ENABLE_BACKUP_VELERO
yq -r '.credentials.useSecret' override_charts_values/keos-backup-velero.yaml  # false (solo con ENABLE_BACKUP_VELERO)
yq -r '.keos.security // "-"' keos.yaml                                      # clamav.enabled true / falco.enabled false según flags
grep -c '\${' keos.yaml override_vars/${CLUSTER_NAME}.yaml                    # 0 y 0
```

**Decisión pendiente:** cloud-provisioner también dejó `override_vars/ingress-nginx.yaml` (solo LB interno,
`ingress_external_lb: false`), que **contradice** `ingress_external_lb: true` del override de la PR. Si se dejan los dos,
no está claro cuál gana. Lo razonable es mover el generado a `override_vars/ingress-nginx.yaml.cloud-provisioner.bak`
(fuera de `*.yaml`) o quitar las claves duplicadas (`render-keos.sh` de la skill ya lo hace con `INGRESS_EXTERNAL_LB=true`).

### 13. `keos install` (lo lanzas tú, en otro terminal)

Requisitos: acceso a `qa.int.stratio.com` (VPN/login de docker) y al socket de Docker. Se lanza **desde la raíz del
workspace**, que es lo que se monta como `/workspace` (no muevas ahí `keos.yaml`, `secrets.yml`, `override_vars/`, `pki/`,
`requirements/`, `logs/`, `.kube/`, `.config/`). keos-installer 1.4.2:

```bash
cd /stratio/e/igualdad && source ./cluster.env
docker run -ti -v "$PWD":/workspace -v /var/run/docker.sock:/var/run/docker.sock "$KEOS_INSTALLER_IMAGE"
```

Al arrancar pide una contraseña para `secrets.yml`. **Ya existe** un `secrets.yml` en la raíz del workspace, cifrado por
cloud-provisioner con tu `VAULT_PASSWORD`: usa **esa misma** contraseña (si pide credenciales de AWS, son la access y la
secret key del usuario `cloud-provisioner`). Dentro de la shell que abre:

```bash
keos install
```

Si el EFS se añadiera después de instalar: `keos edit keos -n keos-ops` para alinear el objeto con `keos.yaml` y
`keos system-services --tags aws-csi` para relanzar el driver.

`keos install` **no** despliega la monitorización (`keos-metrics`) ni Velero (`keos-backup`), ni central logging ni falco: son el paso 13b, opcional. Si activaste `KEOS_ENABLE_CLAMAV`, lo despliega este mismo `keos install`.
Antes de lanzarlo, confirma que repetiste `render-keos.sh` tras decidir los flags del paso 12 (`keos.yaml` y `override_charts_values/` los lee `keos install`).

### 13b. Post-install opcional (lo lanzas tú, dentro del contenedor keos-installer)

Mismo contenedor y shell que el paso 13 (donde acabas de ejecutar `keos install`; si lo cerraste, vuelve a abrirlo con el mismo `docker run`). **Ninguna opción es obligatoria** según la guía de origen: es lo que tiene el clúster del cliente. Decide cuáles quieres; los comandos los genera
`1-aws-cluster/render-postinstall.sh` a partir de los flags de `cluster.env` (todos `false` por defecto; estos tres no cambian `keos.yaml`, así que se pueden decidir también ahora). El script **solo imprime** por stdout (no ejecuta nada ni escribe ficheros) y, sin flags, imprime un aviso con las opciones.

```bash
cd /stratio/e/igualdad                       # desde el host: ver qué se lanzaría con los flags actuales
1-aws-cluster/render-postinstall.sh          # o: 1-aws-cluster/render-postinstall.sh /ruta/otro/cluster.env
# copiar los comandos impresos a la shell del contenedor keos-installer, en el orden en que salen
```

| Opción (flag en `cluster.env`) | Comandos (dentro del contenedor) | Qué hace y requisitos |
|---|---|---|
| Monitorización (`ENABLE_MONITORING`) | `keos monitoring` + parche PLT-5162 | Prometheus (2 réplicas, sin almacenamiento a largo plazo), Alertmanager, Grafana y Thanos query, más los exporters activados en `override_vars` (blackbox, pushgateway, ldap-query, certificates). Tras `keos monitoring` la HelmRelease `pushgateway` de `keos-metrics` queda con `ValuesError ... yaml: line 119` (fallo de plantilla de keos-installer 1.4.2, PLT-5162: probes con dos espacios de más en el ConfigMap `00-pushgateway-helm-chart-default-values`; un override no lo evita). El script imprime el parche (`sed` + `jq` + `kubectl patch cm`) y lo omite si `prometheus_pushgateway_enabled` no es `true` en el override. **El parche NO persiste: se pierde si se vuelve a lanzar `keos monitoring`.** `ldap-query-exporter` (chart e imagen 1.1.3) y `functional-monitoring` (imagen 0.3.1) están ya en el ECR `717279725338` según la guía |
| Velero (`ENABLE_BACKUP_VELERO`) | `keos backup velero` + `kubectl -n keos-backup get bsl aws` | Usa el bucket y el rol IRSA del paso 10 (variables `velero_*` de `override_vars`). La `BackupStorageLocation` `aws` debe quedar `Available`. Requiere haber renderizado con el flag **antes** de `keos install` (paso 12: `storage_class`, snapshots y `override_charts_values/keos-backup-velero.yaml`, imprescindible con IRSA). El script avisa si falta ese fichero |
| Backups programados (`ENABLE_BACKUP_SCHEDULE`) | `keos backup schedule vault idp` | CronJobs diarios: IdP a las 00:00 y vault a las 00:05, 7 días de retención (`keos_backup.<módulo>.cronjob.schedule` y `keos_backup.<módulo>.retention_days` en `override_vars`), sin `control-plane` (no aplica en EKS). La guía lo lanza después de Velero; el script avisa si no activaste Velero |
| Central logging (`ENABLE_CENTRAL_LOGGING`) | `keos central-logging` | `keos-logs`: fluentd y OpenSearch. No se adoptan los `*_index_replicas: 0` del cliente (índices sin réplicas con un solo nodo de datos) |
| Falco (`ENABLE_FALCO`) | `sed -i ... /workspace/keos.yaml`, `kubectl -n keos-ops patch keos keos ...`, `keos falco` | Falco con salida a OpenSearch: necesita central logging (el script avisa). `keos.yaml` se instaló con `falco.enabled: false`; `keos falco` exige `true` en `keos.yaml` **y** que coincida con el CR `keos` de `keos-ops`, así que se cambia **en los dos sitios** (el `sed` edita el `keos.yaml` del host a través del montaje; un nuevo `render-keos.sh` lo volvería a `false`). Requiere haber renderizado con el flag antes de `keos install` |

**Validación** (desde el host, con tu kubeconfig propio): `kubectl -n keos-metrics get hr` (todas `Ready`, `pushgateway` incluida), `kubectl -n keos-backup get bsl aws` (`Available`), `kubectl -n keos-logs get pods`, y lo que corresponda a falco. **No probado:** estos bloques solo se han verificado con mocks; ninguno se ha ejecutado contra un clúster real.

## Fase 3 (opcional): backups y reporters de la plataforma — «14h» en la skill (lo lanzas tú)

Solo después de `keos install` y de las apps. No es un paso de esta guía: en la skill el paso 14 es apps-layer y este es su parte opcional «h» (por eso el 14 de esta guía, la eliminación, viene después). La guía de la PR (secciones 7.5 y 7.6) crea con `enviroment-ready` los backups de IdP, etcd de vault y postgres, y los reporters. **Ninguno es obligatorio.**
`2-apps-layer-kit/scripts/backups-env.sh` solo **escribe** `backups.env` en el directorio efímero de apps-layer (`${TMPDIR:-/tmp}/apps-layer-<cluster>`, modo 600, sin comillas, sin secretos: `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_BUCKET_NAME` = `VELERO_BUCKET`, `AWS_IAM_ROLE_NAME` = `VELERO_ROLE`, y `SC_POSTGRES` si lo defines; `.bak` si cambia)
e imprime los avisos. No ejecuta `enviroment-ready`, ni docker, ni kubectl, ni aws.

```bash
cd /stratio/e/igualdad && unset APPS_LAYER_DIR             # una APPS_LAYER_DIR vieja pisa el directorio efímero
2-apps-layer-kit/scripts/backups-env.sh --dry-run          # muestra el contenido sin escribir
2-apps-layer-kit/scripts/backups-env.sh                    # escribe backups.env (el contenedor lo ve como /apps-layer/backups.env)
# dentro del contenedor de apps-layer (el que imprime launch-apps-layer.sh), con las apps ya instaladas:
#   cd /apps-layer && enviroment-ready --backups backups.env
```

- **Qué hace `--backups` en el clúster**: `keos backup create idp vault` (backup puntual; volúmenes en `keos-backup`), escribe `override_vars/velero.yaml` en el workspace si no existe y **relanza `keos backup velero`**, y para cada PgCluster (`postgreskeos`, `pg-meta`, `pg-data` en el cliente) crea un PVC `<pg>-backup-pvc` de 40Gi y un `PgBackup` diario a las 01:00 si no existen. Esos PVC quedan `Pending` (StorageClass `WaitForFirstConsumer`) hasta la primera ejecución de cada backup: es normal, no un fallo.
  Los diarios de IdP y vault son los del paso 13b (`keos backup schedule vault idp`). El cliente los tiene escalonados con PVC de 50/50/80Gi, creados a mano antes: es sizing del cliente, **no se adopta**.
- **Es el bucket y el rol IRSA de Velero** (paso 10), no el bucket opcional `ENABLE_BACKUPS_BUCKET` de la fase 3 (ese es otro, con usuario IAM de claves estáticas, para migrar a GitOps). Comprueba después `kubectl -n keos-backup get bsl aws` (`Available`); con IRSA exige el override `keos-backup-velero.yaml` del paso 12.
- **Reporters (aún más opcional)**: `enviroment-ready --reporter backups.env` (exige un fichero aunque no lo use) crea el namespace `keos-reports`, la `GlobalNetworkPolicy` `allow-all-traffic-from-keos-reports` y tres HelmReleases (`postgresql-statistics-report`, `keos-versions-reporter`, `functional-monitoring`). Avisos de la guía:
  (1) el chart más alto de `helm-15.1` es `functional-monitoring` 0.3.1 y su imagen `stratio/functional-monitoring:0.3.1` **no estaba** en el ECR (`ImagePullBackOff`): hubo que subirla desde `qa.int.stratio.com`; el universe 15.1 espera la 0.3.2, cuyo chart no está en el ECR; (2) el hook post-install de `functional-monitoring` falla con `i/o timeout` hacia
  `thanos-query.keos-metrics:9090` porque la GlobalNetworkPolicy usa `namespaceSelector: name == 'keos-reports'` y el namespace no lleva esa etiqueta; el parche cambia el selector a `kubernetes.io/metadata.name == 'keos-reports'` (comando en el aviso de `backups-env.sh`) y **un nuevo `--reporter` lo pisa**.
- **No probado**: ni `enviroment-ready` ni `backups-env.sh` se han ejecutado contra `apps-installer` ni un clúster real.

## 14. Eliminación de los recursos de AWS

Solo cuando haya que desmontar el entorno, y lo hace el propietario del entorno con su script (entorno conda
`marketplace`), fuera de esta guía y de la sesión asistida. Perfil `$CP_PROFILE`, región `$AWS_REGION`.

Si se instaló apps-layer con `2-apps-layer-kit`, antes hay que borrar su stack S3 (`2-apps-layer-kit/scripts/s3-requisites.sh delete`). Los ficheros locales nuevos (`override_charts_values/`, `backups.env` en el directorio efímero de apps-layer) son regenerables y sin secretos.
Después de la limpieza, comprobar que no quedan VPC, NAT Gateways, EIP ni volúmenes, y decidir si se eliminan el
usuario IAM `cloud-provisioner` y la policy de los pasos 1-2 (si ya no van a usarse en la cuenta).
