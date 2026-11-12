# PLAN: skill `legacy-eks-cluster`

Objetivo: convertir la guía validada `GUIA-INSTALACION-LEGACY.md` (hoy en `1-aws-cluster/` del workspace igualdad) (pasos 0-13, más el paso 14 apps-layer, ver abajo) en una skill reutilizable que, a partir
de **número de cuenta AWS + nombre de clúster**, aprovisione un EKS "legacy" (cloud-provisioner con
`gitops_enabled: false` + prerrequisitos AWS + keos-installer), y que incluya una desinstalación segura
(escrita y probada solo con mocks, **no ejecutada**).

## Plan seguido

1. **Leer fuentes** (solo lectura): guía, plantillas y scripts de `/stratio/e/igualdad/` (antes de la reorganizacion: raiz; ahora `1-aws-cluster/`), PR keos-fleet#220
   (guía `instalacion-cliente-legacy.md`; el nombre `legacy-latest.md` era un snapshot local de esa guía, no un fichero de la PR), doc de Stratio/kind (`installation.adoc`, manual de operaciones) y el código de
   cloud-provisioner (`kind-src`) para ver cómo se borra un clúster. Lecturas AWS de solo lectura (SG, CloudFormation,
   roles CAPA, OIDC, tags del EKS) con el perfil `cloud-provisioner` para anclar el descubrimiento por tags.
2. **Diseño de la skill**: una sola skill con `SKILL.md` (flujo + reglas de interacción) y `references/`, `scripts/`,
   `templates/`. Los scripts son autocontenidos y trabajan sobre un **directorio de trabajo por clúster**
   (`./clusters/<cluster>/`, relativo al directorio desde donde se invoque; `--dir` para cambiarlo).
3. **Escribir** plantillas (generalizadas, con `INGRESS_EXTERNAL_LB`), scripts, referencias y SKILL.md.
4. **Probar offline**: render con datos ficticios (111111111111 / `demo-x`), `bash -n`, `yq`/`jq`, y el teardown con un
   `aws` falso (registra llamadas) para demostrar dry-run sin operaciones de escritura, guarda de identidad protegida y
   aborto con cuenta incorrecta.
5. **Informe final** conciso.

## Decisiones

- **Nombre y estructura**: `legacy-eks-cluster`; una skill (el teardown comparte variables, nombres derivados y JSON de
  VPC con el aprovisionamiento; separarlas duplicaría la fuente de verdad).
- **Directorio de trabajo**: `./clusters/<cluster>/` con `cluster.env`, `<cluster>.json`, `cluster.yaml`, `secrets.yml`,
  `keos.yaml`, `override_vars/`, `.kube/`, `.work/`, `backup/`, `logs/`. cloud-provisioner y keos-installer escriben en
  el cwd, así que la persona usuaria hace `cd` ahí antes de lanzarlos. Nunca dentro de la skill.
- **Plantillas con override por clúster**: si existe `<dir>/templates/<x>.tpl` se usa en vez de la de la skill.
- **Una sola fuente de variables**: `init-cluster.sh --account --name` deriva todo y escribe `cluster.env`; los demás
  scripts hacen `source` de él. Sin secretos en ficheros salvo `cluster.yaml`/`secrets.yml` (chmod 600).
- **Perfil de administración**: se descubre con `aws configure list-profiles` + `aws configure get role_arn|sso_account_id`
  (nunca se leen secretos); 0 o >1 candidatos => se pregunta.
- **Pasos que crean recursos** (usuario IAM, policy ECR, zonas, IAM de external-dns/velero, bucket, EFS) en un único
  `provision.sh <paso> [--apply]`: **dry-run por defecto**, comprueba la cuenta y etiqueta lo que crea
  (`keos.stratio.com/owner=<cluster>`, `managed-by=legacy-eks-cluster`) para que el teardown pueda demostrar pertenencia.
- **Salida AWS**: los scripts usan `aws ... --output json | jq` (no `--query`) para ser robustos entre aws v1/v2 y
  mockeables, y siempre con `AWS_PAGER=""` (no `--no-cli-pager`, no existe en v1).
- **Teardown** (`scripts/teardown.sh`): fases 0-9 en orden inverso a la creación, dry-run por defecto, `--apply` + confirmación
  escribiendo nombre del clúster y cuenta; descubrimiento por tags/nombres derivados/JSON de VPC (aborta si ambiguo);
  guarda de recursos protegidos (denylist + ARN del llamador + `role_arn` de los perfiles) aplicada en **cada** borrado;
  reanudable (descubre el estado real en cada ejecución y guarda un snapshot sin secretos de lo no recuperable una vez
  borrado el EKS: issuer OIDC, VPC, EFS); log sin secretos; verificación final por tags (`resourcegroupstaggingapi`) y por nombre.
- **Borrado del clúster EKS**: no existe `cloud-provisioner delete cluster` que toque AWS (solo borra el contenedor kind).
  El mecanismo documentado (manual de operaciones de Stratio/kind) es: `create cluster --avoid-creation` (kind local sin
  crear nada), pausar `keoscluster-controller-manager`, `clusterctl move` del EKS al kind local, `delete cl --all` en el
  kind, `delete cluster`. Se implementa como fase 2 asistida (pausas de confirmación) más un fallback explícito por API EKS.
- **Recursos de cuenta compartidos** (rol `eks-nodegroup...`, pila CloudFormation de CAPA, policy ECR, usuario
  `cloud-provisioner`): fase 9 aparte, `--purge-account-shared`, solo si no queda otro EKS en la cuenta, y el usuario IAM se
  borra el último y no puede ser la identidad del llamador (hay que ejecutarla con el perfil de administración).
- **Protegido siempre**: perfil `igualdad` / `OrganizationAccountAccessRole`, la identidad del llamador y los `role_arn` de
  los perfiles configurados; no se toca `~/.aws`.

## Ampliación: paso 14 apps-layer-automation y fase A del teardown

- **No se duplica el kit**: la skill no copia `2-apps-layer-kit`; `scripts/apps-layer.sh` lo localiza (`--kit`, `APPS_LAYER_KIT`, `<skill>/../../../2-apps-layer-kit`, `<dir>/2-apps-layer-kit`) y lo parametriza desde `<dir>/cluster.env`
  (`CLUSTER_ENV_FILE`, `KEOS_WORKSPACE_DIR=<dir>`, `KIT_AWS_PROFILE=$CP_PROFILE`, `KUBECONFIG_SRC=<dir>/kubeconfig-<cluster>`). Una sola fuente de verdad (plantillas, render, check, launch, S3).
- **Dry-run por defecto**: `s3 apply` sin `--apply` solo hace `plan`; `render` es `--dry-run` salvo `--apply`; `launch` solo imprime y rechaza `--run/--force` (la skill nunca ejecuta el `docker run`); `s3 delete` se rechaza (lo hace el teardown).
- **Directorio efímero** `${TMPDIR:-/tmp}/apps-layer-<cluster>` (700): una `APPS_LAYER_DIR` exportada se ignora avisando (gotcha real: pisó el defecto y `s3-requisites.sh env` escribió el `.env` en la ruta vieja). En el kit se añadió además un aviso mínimo en `lib.sh` (`warn_unexpected_apps_layer_dir`).
- **Universo siempre fresco** (requisito del usuario): zip del Nexus de QA (curl + `unzip -t`) y `universe-images.lst` de `Stratio/kubernetes-universe` (gh api, `branch-<major>.<minor>`), montados sobre los embebidos en la imagen; exige `gh` autenticado y VPN, y para si faltan.
  El kit fija por defecto `CONNECTORS_LOADER_VERSION=2.2.0` en el YAML del tenant (como la PR Stratio/keos-fleet#220, probada solo en HDFS); el hook entonces ignora el `.lst` para el loader, pero el `.lst` fresco sigue siendo obligatorio (lo usan intelligence → analytic-environment y connectors si no hay pin). Para usar el loader del `.lst` (2.2.3) pon `CONNECTORS_LOADER_VERSION=` vacía en `kit.env`.
- **Teardown fase A** (primera, antes del EKS): contenedores por nombre exacto + imagen, directorio efímero (solo `apps-layer-<C>`, propio, no enlace; shred), requisitos S3 informados y **conservados por defecto**; `--delete-s3-requisites` delega en `s3-requisites.sh delete` del kit tras teclear el nombre del bucket (el bucket es `Retain` y puede tener datos).
  La guarda de identidades protegidas se aplica también a `<C>-s3`. Fase 8 incorpora lo que apps-layer deja en el workspace (`admin.key`/`admin.cert` como secretos).
- **Bucket de backups opcional (migración a GitOps)**: recurso más del stack `<C>-requisites` (parámetro `EnableBackupsBucket`, `Condition: CreateBackups`; defecto desactivado => nada cambia). El kit lo gestiona (`ENABLE_BACKUPS_BUCKET`, `BACKUPS_BUCKET_NAME`, `BACKUPS_USER_NAME`; `s3-requisites.sh plan|apply|env|status|backups-info|delete [--delete-backups]`); la skill solo lo envuelve (`apps-layer.sh s3 backups-info`, reenvío de las variables) y el teardown fase A lo informa y lo **conserva siempre** salvo `--delete-s3-requisites --delete-backups` + teclear el nombre del bucket de backups. `apps-layer.sh` no lo usa: es para el consumidor GitOps (keos-fleet `backups.s3BucketName`/`s3BucketRegion` y `BACKUPS_S3_BUNDLE`).
- **Estado del clúster de referencia** `igualdad-dgutierrez`: stack `igualdad-dgutierrez-requisites` CREATE_COMPLETE, bucket `igualdad-dgutierrez-internal-821111360971`; apps-layer lanzado por la persona usuaria (nunca ejecutado de punta a punta por la skill).

## Supuestos (a revisar por la persona usuaria)

- El pivote `clusterctl move` EKS -> kind local conserva `AWSClusterControllerIdentity/RoleIdentity` y permite a CAPA
  borrar el clúster; está documentado pero **no se ha podido probar** (habría que destruir un clúster).
- No hay `keos uninstall` documentado en las fuentes disponibles; se borran LB/Ingress/PVC desde el clúster y se confía
  en el borrado del clúster para el resto.
- `clusterctl` debe existir en el equipo (o usarse el del contenedor kind); su versión debe casar con la de CAPI.
- El borrado de VPC asume VPC creada por `create-test-vpc.sh` (tags `Name=<cluster>*`).

## Ajustes incorporados durante la ejecución (correcciones verificadas por la coordinación)

- Un managed nodegroup **por AZ** (`<cluster>_<NODEGROUP_NAME>-mp-0/1/2`): validaciones y teardown los descubren con `eks list-nodegroups`.
- EBS de nodos `Encrypted=False`: documentado como riesgo (`references/open-risks.md`, nº 5).
- `.kube/` y `secrets.yml` pasan a ser de root tras `keos install`: la skill y el teardown usan un kubeconfig propio `kubeconfig-<cluster>` fuera de `.kube/`
  y, si un fichero no es del usuario, imprimen el `sudo rm` en vez de ejecutarlo.
- Hasta que acaba `keos install` no hay NLB/PVC/`keos-*`: la fase 1 lo tolera.

## Resultado de las pruebas offline (`tests/run-offline-tests.sh`)

Estado de esa tanda (sincronización con la PR a `2d36d7d`, 2026-10-29; ver al final la de `1a1bbda`): **skill 216/216, kit 640/640** (tras la ampliación del paso 14 eran 113 y 351). Antes (solo aprovisionamiento/teardown): 56/56. Esa primera tanda: 56/56 OK con datos ficticios (111111111111 / `demo-x`) y `aws`/`kubectl`/`docker` falsos: `bash -n` de todos los scripts, render de las 3 plantillas sin `${` y con `yq` parseando,
dry-run del teardown sin ninguna operación de escritura, guarda (llamador = recurso a borrar, `OrganizationAccountAccessRole`, fase 9 como `cloud-provisioner`), cuenta incorrecta,
confirmaciones erróneas / sin tty, y orden de borrado en `--apply` simulado. Nuevos: `apps-layer.sh` contra un kit falso (delegación de variables, `APPS_LAYER_DIR` ignorada, dry-run de `s3 apply`/`render`, rechazo de `launch --run`, prereqs con `gh`/tenant/cuenta), y fase A del teardown (dry-run sin escrituras, orden A antes de 1, contenedores por nombre/imagen, enlace simbólico, stack ajeno, guarda de `<C>-s3`, `--delete-s3-requisites` con confirmación del bucket). No probado: shellcheck (no instalado), ninguna operación real en AWS, `clusterctl move`, `keos install`.

## Sincronización con la PR keos-fleet#220 a `2d36d7d` (2026-10-29; antes `a47a1bc`)

Solo cambian en la PR la guía `instalacion-cliente-legacy.md` y dos scripts de cliente que **no** se adoptan (`cct-ajustes-cliente.sh`, `keos-cluster-snapshot.sh`). La guía no marca nada post-`keos install` como obligatorio, así que por decisión de la persona usuaria todo es **opcional por flags** (todos `false`, solo `true|false`) y la skill **avisa y pregunta** (AskUserQuestion) en lugar de activarlos; lo único aplicado sin flag es lo que ya usábamos:
- **Sin flag**: `helm_repository.url` = `oci://<ECR>/${CP_HELM_PATH}` (`helm`; `helm-15.1` es solo de keos-installer) y `logging.authenticator: true` en `cluster.yaml.tpl`.
- **Flags que cambian `keos.yaml`/`override_vars`** (decidir antes de `keos install`, aplicar con `init-cluster.sh --set` y re-ejecutar `render-keos.sh`): `ENABLE_BACKUP_VELERO` (`keos.backup.storage_class`, `velero_enable_snapshot_volumes`, `override_charts_values/keos-backup-velero.yaml` con `useSecret: false`: requisito técnico con IRSA en keos-installer 1.4.2), `KEOS_ENABLE_CLAMAV`, `ENABLE_FALCO` (en `keos.yaml` siempre `enabled: false`; el flag solo añade su activación al 13b).
- **Paso 13b (nuevo, opcional)**: `scripts/render-postinstall.sh --dir` **solo imprime** los comandos (`keos monitoring` + parche PLT-5162, `keos backup velero` + BSL, `keos backup schedule vault idp`, `keos central-logging`, falco) según `ENABLE_MONITORING`, `ENABLE_BACKUP_VELERO`, `ENABLE_BACKUP_SCHEDULE`, `ENABLE_CENTRAL_LOGGING`, `ENABLE_FALCO`; la persona usuaria los ejecuta dentro del contenedor keos-installer. Copia equivalente en `1-aws-cluster/render-postinstall.sh`.
- **Paso 14**: `ENVIRONMENT_SIZE=CUSTOM` (overlay propio del kit + `CUSTOM_SIZES_FILE`; no existe `sizes/CUSTOM` upstream) y **14h opcional**: `apps-layer.sh backups-env` (delega en `backups-env.sh` del kit: escribe `backups.env`; `enviroment-ready --backups/--reporter` lo lanza la persona usuaria). El wrapper no limita `ENVIRONMENT_SIZE`.
- **Teardown**: `override_charts_values/` entra en el grupo A de la fase 8 (local, regenerable); `backups.env` va en el directorio efímero ya cubierto por la fase A; no hay recursos AWS nuevos.
- **Deliberadamente no adoptado ni implementado**: flavour `custom` (documentado el mecanismo), valores/hosts/sizing del cliente, `cct-ajustes-cliente.sh`, `keos-cluster-snapshot.sh`, `PgBackup`/PVC escalonados a mano y la sección 9 de la guía (parar/arrancar el clúster) como **follow-up para una skill nueva**.
- **Riesgos nuevos o reformulados** (`references/open-risks.md`): nº 17 (formato `BACKUPS_S3_BUNDLE`, sigue abierto), 18-21 (parche pushgateway no persistente, flags probados solo con mocks, `CUSTOM`/`enviroment-ready`/`backups-env` sin ejecutar, sizing en clústeres pequeños).
- Pruebas: la skill añade la sección 10 (render con/sin flags, `render-postinstall`, espejo en `1-aws-cluster/`), las del wrapper (`backups-env`, `CUSTOM`) y la de `override_charts_values/` en la fase 8; el kit, `CUSTOM` y `backups-env.sh`. Todo con mocks: ninguna operación real en AWS ni contra `apps-installer`.

## Sincronización con la PR keos-fleet#220 a `1a1bbda` (2026-11-12; antes `2d36d7d`)

HEAD de la PR `1a1bbdaf` (2026-11-05), sin comentarios ni reviews. Desde `2d36d7d`: 10 commits de Francisco con algo legacy; el diff de los bloques de código de su guía solo muestra tres cosas técnicas; el resto es condensación (1307 → 1044 líneas), renombrado del directorio a `clusters/igualdad-keos-desa-gitops/` y un documento nuevo de migración a GitOps. Alcance: solo lo que afecta al aprovisionamiento/configuración del legacy.

| Origen en la PR | Efecto en nuestra instalación | Decisión |
|---|---|---|
| `a471c0fa` JVM opts de HDFS (`ParallelGCThreads=0` con CPU request < 1) | Ninguno (kit S3, sin hdfs) | Documentado (gotcha, variante HDFS) |
| `a73962b6` `DISCOVERY_ADMIN_GROUP` debe existir en GoSec (si no, 403 y `apps-installer` se detiene) | Ninguno: usamos `<tenant>-stratio-owners`; pero nada lo protegía | Documentado + comentario en `tenant.yaml.tpl` + test que fija las líneas de `DISCOVERY_ADMIN_GROUP` e `INTELLIGENCE_ADMIN_GROUPS` |
| `4899e64c` PVC `<pgcluster>-backup-pvc` quedan `Pending` hasta el primer backup | Ya usamos ese nombre; `check-apps-layer.sh` no mira PVC | Documentado (gotchas, steps 14h, guía, README del kit) |
| `a56b77fb` guía resumida + tabla "Qué se ha copiado del cliente" | Nueva numeración de la guía (6.2 `override_vars`, 6.3 `override_charts_values`, 6.4 instalación, "Operación" sin número) | Mapa del `README.md` actualizado; filas nuevas en "Known upstream deltas not adopted" |
| Prosa eliminada: `sis` y `ldapsync-internal` en `Error` ~10 min tras arrancar | No documentado antes | Documentado (gotchas, README) |
| functional-monitoring: ahora es un "prerrequisito ya subido al ECR" | Es del ECR de Francisco; nuestras notas siguen siendo más completas | Documentado en gotchas |
| `migracion-legacy-gitops.md` (nuevo) | Lista lo que el legacy debe ofrecer para migrar (flux y vpa en `kube-system`, `keos-operator`, IRSA external-dns, velero IRSA con BSL `Available`, EFS): ya lo produce el workspace | No adoptado; puntero en README |
| `de0ccd4c` clave KMS: `cancel-key-deletion` por ARN | Aplica si tras migrar se borra la clave | Nota en `teardown.md` y `legacy-eks-uninstall` |
| Commits de `dgutierrez` (GitOps): clamav con StorageClass `keos` (PLT-5195), rocket 4.1.0, credencial S3 | No cambia ningún flag | Notas para quien migre, en gotchas |

Decisiones de la persona usuaria: la deriva de `apps-layer-automation@branch-15.1-0.1` desde 10-29 (`ffecfe8f` y `KEOS_WORKSPACE_DIR`, `a9460607` Rocket Guaranteed, tags `15.1-0.1.0-M1/M2`, `.lst` de `branch-15.1` ya en 15.1.1) **queda fuera**: se tratará con su pull de la imagen; solo se documenta `M2` como alternativa en `kit.env.example`. keos-installer se queda en 1.4.2 como la guía; como salvaguarda el parche `sed` de PLT-5162 se omite con `KEOS_INSTALLER_VERSION` >= 1.4.9 (la 1.4.9 lo corrige; con el `sed` se corrompería el ConfigMap).
