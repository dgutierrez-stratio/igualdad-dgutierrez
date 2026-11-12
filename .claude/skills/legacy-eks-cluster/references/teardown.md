# Desinstalación segura (`scripts/teardown.sh`)

> Escrito y probado **solo con mocks** (ver `tests/run-offline-tests.sh`). Nunca se ha ejecutado contra AWS. Antes de usarlo de verdad: dry-run, leer la salida entera y
> revisar los puntos de "criterio humano" del final.

## Principios

- **Dry-run por defecto**: `teardown.sh --dir $DIR` lista exactamente qué borraría (con IDs) y no escribe nada. En dry-run cualquier operación AWS/kubectl/docker que no sea de lectura
  aborta el script (red de seguridad). Solo `--apply` borra, y antes pide **escribir el nombre del clúster y el número de cuenta**.
- **Cuenta**: `sts get-caller-identity` debe devolver la cuenta de `cluster.env`; si no, aborta sin tocar nada.
- **Pertenencia, no patrones**: el EKS debe llevar `kubernetes.io/cluster/<C>`; la VPC se identifica por `<C>.json` **y** tag `Name=<C>` (deben coincidir, y con la del EKS); EFS por `creation-token`/tag;
  zonas por tag owner / `CallerReference <C>-*` / VPC asociada (si ninguna prueba sirve: `--accept-zone <id>` explícito); bucket y roles/policies por nombre derivado exacto (+ tag owner si lo
  tienen: si pertenece a otro clúster, aborta). **Ambiguo => aborta** (varias VPC/EFS/zonas, etc.).
- **Guarda de recursos protegidos** en CADA borrado (`guard`) y un pre-chequeo estático de todos los nombres IAM planificados: denylist (`OrganizationAccountAccessRole`, `AWSServiceRole*`, `AWSReservedSSO_*`),
  el ARN/nombre del llamador (`sts get-caller-identity`, incluido el rol base si es `assumed-role`), el `role_arn` de los perfiles implicados (`aws configure get role_arn`, nunca `credentials`) y
  `PROTECTED_IAM_NAMES`/`PROTECTED_ARNS` (variables de entorno opcionales). No toca `~/.aws/credentials` ni `~/.aws/config`.
- **Reanudable e idempotente**: cada fase redescubre el estado real; lo que ya no existe se salta ("ya no existe"). Si falla a mitad, se vuelve a lanzar (opcionalmente `--phase N,M`).
  `logs/teardown-state.env` (sin secretos) guarda VPC, issuer OIDC y EFS para poder seguir cuando el EKS ya no existe.
- **Log**: `logs/teardown-<fecha>.log` (acciones, sin secretos).
- **apps-layer primero (fase A)**: los contenedores de apps-layer y su directorio efímero se limpian ANTES de tocar el EKS; el bucket S3 de apps-layer (`DeletionPolicy Retain`, con datos del usuario) **se conserva salvo `--delete-s3-requisites`** + confirmación tecleando el nombre del bucket. Solo se tocan contenedores por **nombre exacto** (`apps-layer-<C>`, `keos-installer_<C>`) y con la imagen esperada; el directorio efímero solo si se llama `apps-layer-<C>`, es propio y no es un enlace simbólico.
- **Tolera instalaciones incompletas**: si `keos install` no llegó a crear NLB, PVC ni namespaces `keos-*`, la fase 1 lo dice y sigue.

## Orden (inverso a la creación) y comprobación previa de cada fase

| Fase | Qué borra | Comprobación previa (solo lectura) | OK / KO |
|---|---|---|---|
| 0 | — | `sts` = cuenta; guarda estática; `eks describe-cluster` (tags), VPC por JSON+Name, issuer OIDC | OK: todo coincide. KO: cuenta distinta, tags ausentes, VPC ambigua |
| A apps-layer | contenedores `apps-layer-<C>` y `keos-installer_<C>` (stop + rm); directorio efímero `${TMPDIR:-/tmp}/apps-layer-<C>` (shred + rm); con `--delete-s3-requisites`: `s3-requisites.sh delete` del kit (vacía objetos/versiones/delete markers/multipart -> borra stack `<C>-requisites`, bucket `<C>-internal-<cuenta>`, usuario IAM `<C>-s3`, access key y secreto) | imagen de cada contenedor; propietario/enlace del directorio; stack con tag `cluster=<C>` u output `InternalS3BucketName` = bucket (si es de otro clúster, aborta); `head-bucket --expected-bucket-owner`; guarda sobre `<C>-s3` | OK: sin contenedores ni directorio; sin flag, el stack/bucket quedan "conservados a propósito". KO: imagen inesperada, stack ajeno, kit no encontrado con el flag |
| 1 in-cluster | Ingress, Services `LoadBalancer`, escala a 0 deploy/sts de namespaces de aplicación (no `kube-*`, `cert-manager`, `capi-*`, `capa-*`, `cluster-<C>`, `flux-system`), PVC y PV | kubeconfig propio `kubeconfig-<C>` (fuera de `.kube/`); su `server` = endpoint del EKS; `kubectl get ingress,svc,pvc,pv` | OK: sin LB ni PV al terminar. KO: API inalcanzable (endpoint privado: lanzar desde la VPC o `--skip-incluster`), un controlador recrea los LB |
| 2 cluster | el EKS y sus nodegroups (uno por AZ) vía CAPA | EKS/nodegroups existen; contenedor kind `<C>-control-plane` (si existe, imagen `cloud-provisioner`); `cluster.yaml`+`secrets.yml`+binario presentes | OK: `describe-cluster` -> NotFound, sin nodegroups, objeto `Cluster` desaparecido. KO: `clusterctl move` sin `Clusters=1`, timeout |
| 3 efs | mount targets -> (espera) -> access points -> file system | EFS único del clúster (token/tag), owner | OK: `describe-file-systems` sin él |
| 4 route53 | registros (todo menos NS/SOA del apex, incluidos los de external-dns) -> zonas privada y pública | por zona: prueba de pertenencia | OK: zonas inexistentes |
| 5 s3 | versiones/delete markers/multipart -> bucket (`--keep-bucket` lo omite) | `head-bucket --expected-bucket-owner`, tag owner, nombre con clúster y cuenta | OK: `head-bucket` 404 |
| 6 iam | roles `C-external-dns`, `VELERO_ROLE`, `C-iam-service-role`; policies `C-external-dns`, `C-velero`, `C-efs-csi` (**antes se desadjunta del rol de nodos de cuenta**); OIDC provider; log group `/aws/eks/C/cluster` | EKS ya inexistente; `list-entities-for-policy` solo con roles esperados; sin usuarios/grupos | OK: `get-role/get-policy` NoSuchEntity. KO: policy adjunta a un rol inesperado => aborta |
| 7 network | `create-test-vpc.sh --delete`: NAT -> EIP (de los NAT y tag `Name=C-nat*`) -> IGW -> subnets -> RT -> SG sobrantes -> NACL -> VPC | sin instancias, LB, endpoints ni ENI `in-use` en la VPC; `available` ENIs se borran | OK: VPC inexistente. KO: BLOCKER (algo vivo depende de la VPC) => aborta |
| 8 local | contenedor kind retenido; `override_charts_values/` (con `ENABLE_BACKUP_VELERO`) y ficheros que apps-layer deja en el workspace (`apps/`, `*-tenant.yaml`, `*_group.json`, `*-users_role.json` en el grupo A; `admin.key` y `admin.cert` en el B); con `--delete-local`, ficheros (grupo A regenerables, grupo B secretos con `shred`); **`cluster.env` y `logs/` se conservan** | imagen del contenedor; propietario de los ficheros | OK: sin contenedor. `.kube/`/`secrets.yml` de root: imprime `sudo rm -rf` para la persona usuaria (la skill no usa sudo) |
| 9 shared | solo con `--purge-account-shared`: pila CloudFormation CAPA, policy ECR, usuario IAM `cloud-provisioner` (**el último**) | ningún EKS en ninguna región habilitada; `eks-nodegroup...` sin policies de cliente ajenas; el llamador NO es `cloud-provisioner`; confirmación `PURGE <cuenta>` | OK: pila/policy/usuario inexistentes |
| V | — | `resourcegroupstaggingapi` por `kubernetes.io/cluster/C`, `sigs.k8s.io/cluster-api-provider-aws/cluster/C`, `keos.stratio.com/owner=C`; EKS, VPC, NAT, EIP, ENI, volúmenes, SG, EFS, bucket, zonas, roles, policies, OIDC, log groups, contenedor kind | OK: nada. Sale con código 2 si queda algo tras `--apply` |

## Comandos

```bash
export AWS_PAGER=""
bash $SK/scripts/teardown.sh --dir $DIR                        # 1) dry-run: leer TODO
bash $SK/scripts/teardown.sh --dir $DIR --apply                # 2) borrado real, fases A,1-8 + verificación (pide nombre y cuenta); el bucket S3 de apps-layer se CONSERVA
bash $SK/scripts/teardown.sh --dir $DIR --apply --phase A --delete-s3-requisites   # además vacía y borra bucket+stack+usuario S3 de apps-layer (teclear el nombre del bucket)
bash $SK/scripts/teardown.sh --dir $DIR --apply --phase A --delete-s3-requisites --delete-backups   # ADEMÁS el bucket de BACKUPS opcional con sus versiones (irreversible; teclear su nombre)
bash $SK/scripts/teardown.sh --dir $DIR --apply --phase 3,4,5  # reanudar solo ciertas fases
bash $SK/scripts/teardown.sh --dir $DIR --apply --delete-local # además, ficheros locales (pregunta por grupos)
# Recursos de CUENTA (aparte, con el perfil de administración, NUNCA con el usuario cloud-provisioner):
bash $SK/scripts/teardown.sh --dir $DIR --apply --phase 9 --purge-account-shared --profile "$ADMIN_PROFILE"
```
El `--apply` lo lanza la persona usuaria en su terminal (las confirmaciones exigen una terminal interactiva). La fase 2 abre el kind local con `cloud-provisioner create cluster ... --avoid-creation`, que pide
la contraseña del vault por teclado, y hace pausas de confirmación (a-e) antes de cada paso destructivo.

## Borrado del clúster (fase 2): el mecanismo real

`cloud-provisioner delete cluster` (`pkg/cmd/kind/delete`) es el `delete cluster` de kind: **solo borra el contenedor local, no toca AWS**. El borrado en AWS lo hace CAPA al borrar el objeto `Cluster` CAPI.
Tras `create cluster`, la gestión CAPI se movió (`clusterctl move`) al propio EKS, así que hay que traerla de vuelta a un kind local. Procedimiento oficial (manual de operaciones de Stratio/kind,
"Deletion of the cluster"), que implementa la fase 2:

1. `cloud-provisioner create cluster --name <C> --descriptor cluster.yaml --avoid-creation [--delete-previous]` crea el kind local con CAPx y cluster-operator **sin crear nada en AWS** (`--avoid-creation`
   es incompatible con `--retain`/`--keep-mgmt`; `--delete-previous` elimina un contenedor retenido de la instalación).
2. Pausar el controlador: `kubectl -n kube-system scale deployment keoscluster-controller-manager --replicas 0` (en el EKS).
3. `clusterctl --kubeconfig <EKS> move -n cluster-<C> --to-kubeconfig <kind>`; la salida debe contener `Moving Cluster API objects Clusters=1` (la skill lo exige antes de continuar). El token de acceso al EKS
   que usa `clusterctl` dentro del contenedor es de 15 min, se genera en un fichero 600 y se borra después.
4. En el kind: `kubectl -n cluster-<C> delete cl --all` -> CAPA borra nodegroups, EKS y los SG/ENI que creó (la VPC es **no gestionada**: CAPA no la borra) y el rol `C-iam-service-role`.
   La skill espera a que desaparezcan (nodegroups, EKS, objeto Cluster) y si hay timeout se detiene en vez de forzar.
5. `cloud-provisioner delete cluster --name <C>` borra el contenedor kind.

Requisitos: `cluster.yaml` y `secrets.yml` del clúster, el binario de la misma versión, y la contraseña del vault. El backup de objetos (`./backup/objects`, con Secrets de kubeconfig) ya existe tras la instalación.
**Fallback `--method aws-api`**: `eks delete-nodegroup` (cada uno) y `eks delete-cluster` directamente; no usa CAPI y puede dejar objetos huérfanos en el kind retenido y SG de CAPA (se limpian en fase 7); exige escribir `FORCE`.

## Recursos de cuenta compartidos (NO se borran por defecto)

Rol `eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io` y demás `*.cluster-api-provider-aws.sigs.k8s.io` (los borra la pila CloudFormation `cluster-api-provider-aws-sigs-k8s-io`), policy
`ecr-pull-through-cache-machinepool` y usuario IAM `cloud-provisioner`. Se borran solo con `--purge-account-shared` (fase 9) tras comprobar que no queda ningún EKS en la cuenta (todas las regiones
habilitadas) ni policies de cliente ajenas en el rol de nodos, con confirmación adicional `PURGE <cuenta>`. El usuario IAM va el **último** (CAPA usa sus claves dentro del clúster) y no puede ser la identidad del
llamador: la fase 9 se lanza con el perfil de administración. El perfil local `cloud-provisioner` de `~/.aws` queda con una key ya borrada: lo elimina la persona usuaria.

## PROTEGIDO: nunca se borra bajo ninguna opción

El perfil local `igualdad` (rol `OrganizationAccountAccessRole` asumido desde otra cuenta), cualquier rol/usuario cuya identidad coincida con la del llamador, `OrganizationAccountAccessRole`, roles gestionados por
AWS/SSO, y el perfil/credenciales del usuario en `~/.aws`. Si el llamador coincide con algo que el script iba a borrar, aborta antes de tocar nada.

## ¿Y tu script de limpieza? (ahora: skill `legacy-eks-uninstall`)

Desde que existe la skill hermana **`legacy-eks-uninstall`** (empaquetada con esta con `skills/package-skills.sh`), el barrido con finder/remover ya no se hace a mano: esa skill identifica y confirma el clúster, filtra los recursos que no deben borrarse (VPC por defecto, KMS de AWS, roles de servicio, `OrganizationAccountAccessRole`), ejecuta el remover en pasadas y verifica que el acceso a la cuenta queda intacto. Supone mergeada la PR Stratio/aws-marketplace-toolkit#51 (handlers de EFS, Route53 y ASG). Lo que sigue describe el uso manual anterior.

> Si el clúster se migró antes a GitOps con KMS (PR keos-fleet#220, `migracion-legacy-gitops.md`) y la clave `alias/flux-<cluster>` quedó programada para borrado, se cancela por **ARN**, no por alias: `aws kms cancel-key-deletion --key-id <arn>` (commit `de0ccd4c`). El finder/remover no la trata como propia de esta instalación (clave de la migración).


Ya tienes el tuyo (entorno conda `marketplace`, `aws-marketplace-finder`/`remover` en `/stratio/aws/aws-marketplace-toolkit/`, que recopila recursos a un JSON y borra los de ese fichero). Úsalo:
- **en lugar de** `teardown.sh` si el clúster ya no responde y quieres un barrido por cuenta/región sin el flujo CAPI, o si `teardown.sh` aborta por algo que no quieres resolver;
- **como verificación posterior** a `teardown.sh` (barre tipos de recurso que la skill no mira) — recuerda que `teardown.sh` no borra recursos de cuenta ni el perfil de acceso.
La skill nunca lo ejecuta. No es incompatible: ambos son idempotentes. Las Lambdas nocturnas de la cuenta limpian EBS/EIP sueltos tras 1 día (ver `gotchas.md`).

## Puntos en los que sigue haciendo falta criterio humano

0. **Fase A**: borrar o conservar el bucket S3 de apps-layer y el bucket de backups opcional (datos del usuario; `Retain` a propósito), y contenedores apps-layer lanzados a mano con otro nombre.
1. **Fase 2** (no probada): versión de `clusterctl` frente a CAPI, identidades AWS tras `move`, tiempos de CAPA, y la contraseña del vault. Si falla `move` NO se borra nada.
2. **Fase 1**: no hay `keos uninstall` documentado; si un controlador recrea los LB hay que desinstalar su release a mano. Endpoint privado del EKS.
3. **Bucket de Velero** con backups reales (`--keep-bucket`).
4. **Zonas** sin prueba de pertenencia (`--accept-zone`), registros DNS que no sean de external-dns.
5. **Fase 9**: si el rol de nodos lleva policies de otros entornos; borrar o no el usuario `cloud-provisioner`.
6. **Ficheros locales de root** (`.kube/`, `secrets.yml` tras `keos install`): `sudo` lo ejecuta la persona usuaria.
7. Recursos fuera de lo que la skill creó (VPC endpoints, peering, etc.): aborta y se decide a mano.

## apps-layer (fase A): orden y qué se borra

Si se instaló apps-layer (paso 14 de `steps.md`, `2-apps-layer-kit`), **va antes de eliminar el clúster EKS** (es la fase A, la primera del orden por defecto):

1. **Contenedores**: `apps-layer-<cluster>` (el `docker run` que imprime `launch`) y `keos-installer_<cluster>` (el hermano que crea su entrypoint). `docker stop -t 30` + `rm`; solo por nombre exacto e imagen esperada
   (`apps-layer-automation` / `keos-installer`). Contenedores de la imagen apps-layer lanzados a mano con otro nombre (p. ej. `adoring_raman`) **no se tocan**: se avisa y los paras tú. Si había un `apps-installer` en curso se interrumpe y su `trap` hace `helm rollback cct`.
2. **Directorio efímero** `${TMPDIR:-/tmp}/apps-layer-<cluster>` (`.env` con claves S3 y `LLM_TOKEN`, YAML del tenant, `kube-config`, `aws/`): shred + borrado. Una `APPS_LAYER_DIR` exportada en el shell solo se borra si se llama `apps-layer-<cluster>`; se avisa de la ubicación antigua `<dir>/apps-layer`, que no se toca.
3. **Requisitos S3**: por defecto se **informa y se conservan** el stack `<cluster>-requisites`, el bucket `<cluster>-internal-<cuenta>` (versionado, `DeletionPolicy: Retain`: borrar el stack no lo borra), el usuario IAM `<cluster>-s3`, su access key y el secreto. Con
   `--delete-s3-requisites` (irreversible) se ejecuta el `s3-requisites.sh delete` del kit tras teclear el nombre del bucket: vacía versiones y delete markers, borra el stack, el bucket y libera el nombre del secreto (el kit pide además escribir clúster y cuenta). Se localiza el kit como en `apps-layer.sh`
   (`APPS_LAYER_KIT`); si no está, aborta sin borrar nada. Comprobaciones de pertenencia: stack con tag `cluster=<C>` u output del bucket; si es de otro clúster, aborta.
   **Bucket de backups opcional** (`<C>-backups-<cuenta>`, usuario/secreto `<C>-backups`, mismo stack, Retain): la fase A lo informa y **lo conserva siempre**, también con `--delete-s3-requisites`; ojo: si el stack lo tenía, al borrar el stack
   se borran su usuario IAM, su access key y su secreto (el bucket y los datos quedan). Solo con `--delete-s3-requisites --delete-backups` y tecleando el **nombre del bucket de backups** (además del de apps-layer) se delega en
   `s3-requisites.sh delete --delete-backups` (vacía versiones y delete markers y lo borra; el kit pide una confirmación extra). `--delete-backups` sin `--delete-s3-requisites` se rechaza. La guarda de protegidos cubre `<C>-backups`.
4. Las apps y el tenant `dev` (namespaces `keos-core`, `dev-*`) **no tienen desinstalador completo** en apps-layer: desaparecen con el EKS; la fase 1 limpia antes Ingress/LB/PVC (el `Service LoadBalancer` del virtualizer, si `VIRTUALIZER_CREATE_LOADBALANCER=true`, y los PVC/EBS de postgres/opensearch/etc.).
5. Lo que apps-layer deja en el workspace (`admin.key`, `admin.cert`, `apps/`, `*-tenant.yaml`, `*_group.json`, `*-users_role.json`) lo lista la fase 8 y se borra con `--delete-local` (la clave del admin en el grupo de secretos).

Nunca se borran el perfil `igualdad`/`OrganizationAccountAccessRole` ni la identidad del llamador, y el usuario IAM `cloud-provisioner` solo con `--purge-account-shared` (fase 9, el último). Si no se usó la skill para borrar y se usa el kit a mano: `2-apps-layer-kit/scripts/s3-requisites.sh delete` **antes** de `teardown.sh`.
