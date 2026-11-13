---
name: legacy-eks-uninstall
description: Desinstala un clúster EKS "legacy" instalado con la skill legacy-eks-cluster y deja la cuenta AWS limpia y reutilizable, usando el finder y el remover de aws-marketplace-toolkit (PR #51 / PLT-5240 mergeada) con un filtro que protege lo que no debe borrarse (VPC por defecto, claves KMS de AWS, roles de servicio, OrganizationAccountAccessRole, la identidad del llamador). Después limpia lo LOCAL de esa instalación (contenedores docker, directorio efímero de apps-layer y ficheros generados del workspace) con backup previo. Confirma con la persona usuaria el clúster instalado y la cuenta antes de borrar. Úsala cuando se pida "desinstalar/eliminar/borrar/limpiar el clúster de igualdad", "dejar la cuenta de fábrica / limpia / como estaba", "limpiar el workspace/los dockers para reinstalar", "ejecutar el finder y el remover", o "limpiar la cuenta AWS tras una instalación/migración". Para desmontar el clúster paso a paso con CAPI (y apps-layer/contenedores locales) sigue existiendo teardown.sh en legacy-eks-cluster.
---

# legacy-eks-uninstall

Deja la cuenta AWS donde se instaló un clúster legacy (cloud-provisioner + keos-installer + apps-layer, y lo que se hiciera después sobre ella) **como si nunca hubiera pasado nada**, sin perder el acceso por CLI/consola. El trabajo pesado lo hace el **remover** de Stratio (`aws-marketplace-toolkit`); esta skill
(1) identifica y confirma el clúster, (2) ejecuta el **finder**, (3) **filtra** lo que no debe borrarse, (4) ejecuta el remover en pasadas, (5) verifica el resultado y (6) limpia lo **local** de la instalación (contenedores docker, directorio efímero de apps-layer, ficheros generados del workspace) dejando un backup.

`SK` = directorio de esta skill. Los scripts son autocontenidos y **solo leen AWS** (un guard bloquea cualquier operación que no sea `describe|list|get`); los borrados los hace únicamente el remover. Los ficheros de cada ejecución (sin secretos) van a `<dir-del-clúster>/uninstall/`. La fase local solo toca contenedores docker del clúster, `/tmp/apps-layer-<cluster>` y los ficheros generados listados abajo; **nunca** `~/.aws`, `/etc/hosts`, git, `cluster.env` ni `logs/`, y no usa `sudo`.

## Supuestos (si no se cumplen, parar)

- **PR Stratio/aws-marketplace-toolkit#51 (PLT-5240) mergeada**: el remover tiene los handlers de EFS, Route53 y ASG. `plan` lo comprueba y aborta si faltan.
- Toolkit en `/stratio/aws/aws-marketplace-toolkit` (o `MARKETPLACE_TOOLKIT`), y el entorno conda `marketplace` (`MARKETPLACE_PYTHON` para otra ruta).
- El clúster se instaló con `legacy-eks-cluster`: existe `./clusters/<cluster>/cluster.env` con `CLUSTER_NAME`, `AWS_ACCOUNT_ID`, `AWS_REGION` y `ADMIN_PROFILE` (perfil de **administración**, p. ej. el que asume `OrganizationAccountAccessRole`; nunca el usuario `cloud-provisioner`, porque se borra).
- La cuenta es **dedicada** a ese clúster. El contexto lo comprueba (un solo EKS en todas las regiones, ninguna VPC ajena); si no, los recursos de id opaco (volúmenes, NLB, EFS...) quedan **excluidos** como "ajenos" en vez de borrarse.

## Flujo (ejecútalo en este orden; cada paso espera a la persona usuaria donde se indica)

1. **Identificar** — `$SK/scripts/uninstall.sh identify` lista los clústeres instalados (`CANDIDATO ...`). Si hay varios o ninguno, pregunta cuál (AskUserQuestion). Con el elegido: `identify --dir <dir>` valida que el perfil opera en la cuenta del `cluster.env` y que el EKS lleva sus tags de pertenencia (si no, aborta). Guarda VPC y OIDC del clúster mientras el EKS existe.
2. **CONFIRMAR con la persona usuaria** (AskUserQuestion, no seguir sin respuesta): muestra nombre, cuenta, región, perfil y estado del EKS tal como los imprime `identify`, y pregunta:
   - si es **ese** clúster y **esa** cuenta;
   - si se **conservan** los recursos compartidos de la instalación (pila CAPA, roles/policies `*.cluster-api-provider-aws.sigs.k8s.io`, policy ECR, usuario `cloud-provisioner`): por defecto se **borran** (cuenta "de fábrica"); `--keep-shared` los conserva.
   Avisa de que se pierden de forma irreversible los **datos**: buckets S3 (con sus versiones), EFS, volúmenes EBS y los secretos del clúster.
3. **Plan (no borra nada)** — `uninstall.sh plan --dir <dir> [--keep-shared]`: foto previa del acceso (`OrganizationAccountAccessRole`), finder, filtro y `remover --dry-run`. Muestra a la persona el resumen (**a borrar por tipo, protegidos, ajenos, compartidos**). Si hay **ajenos**, enséñalos y pregunta; por defecto NO se borran (`--include-unowned` solo si lo pide expresamente tras verlos). El plan queda fijado por sha256.
4. **Confirmación final y ejecución** — pide un "sí" explícito a borrar (mostrando cuenta, clúster y nº de recursos) y entonces:
   `uninstall.sh apply --dir <dir> --confirm-cluster <cluster> --confirm-account <cuenta>` (en segundo plano, `run_in_background`: tarda decenas de minutos; no hagas sondeos, avisa al terminar). Hace hasta 4 pasadas (finder → filtro → remover, con `timeout` de 1200 s por pasada) y para si una pasada repite exactamente los mismos recursos (sin progreso) o si aparecen recursos que **no estaban en el plan revisado**. Termina con `verify`.
5. **Verificar e informar** — `verify` (solo lectura; sale con 2 si queda algo): ¿queda algo del clúster o compartido?, ¿sigue idéntico `OrganizationAccountAccessRole` (confianza y políticas) respecto a la foto previa?, ¿sin instance profiles huérfanas? Informa de qué se borró, qué se protegió, qué quedó y por qué. Recuerda lo que queda **fuera de AWS** (abajo).

6. **Limpieza local (plan, no borra)** — solo cuando `verify` salió OK (la propia skill lo exige: EKS, VPC y zonas inexistentes y `clean-after.json` vacío; si no, se niega, porque aquí se destruyen kubeconfig y secretos que aún harían falta). `uninstall.sh local-plan --dir <dir> [--root <raíz-del-workspace>]` lista:
   - **contenedores docker** del clúster: `<cluster>-control-plane` (kind retenido), `keos-installer_<cluster>`, `apps-layer-<cluster>` y los de nombre aleatorio cuyo bind-mount sea el directorio del clúster o la raíz indicada. Solo imágenes `cloud-provisioner`, `keos-installer` o `apps-layer-automation`; **los demás contenedores no se tocan**.
   - el **directorio efímero** `/tmp/apps-layer-<cluster>` (claves S3 y token del LLM): shred + borrado.
   - los **ficheros generados**: secretos (`secrets.yml`, `cluster.yaml`, `kubeconfig-*`, `admin.key/cert`, `pki/`, `.kube/`, `.config/`, `.keos_bash_history`) y regenerables (`keos.yaml`, `override_vars/`, `override_charts_values/`, `apps/`, `backup/`, `<cluster>.json`, `*-tenant.yaml`, `*_group.json`, `*-users_role.json`, `.work/`, `requirements/`...). Con `--root` se aplica igual a la raíz del workspace (nunca toca `.claude/`, `docs/`, README ni scripts); si es un repo git, un fichero versionado con cambios sin commit **aborta**.
   - lo que **se conserva**: `cluster.env`, `logs/`, `templates/`, `uninstall/`; lo no reconocido se lista y se conserva.
   Muéstralo y pregunta (AskUserQuestion). Avisa de que lo **no versionado** solo quedará en el backup.
7. **Limpieza local (ejecución)** — con el "sí" explícito: `uninstall.sh local-apply --dir <dir> [--root <raíz>] --confirm-cluster <cluster> --confirm-account <cuenta> [--backup-dir <dir>]`. Orden: (a) **backup** `~/backups/<cluster>-workspace-<fecha>.tar.gz` (permisos 600, sin `requirements/` ni `.work/`, entradas relativas a `/`: se restaura con `tar -xzf <fichero> -C /`); si hay ficheros de `root` ilegibles, los lee un contenedor auxiliar con la imagen local de keos-installer, sin `sudo`; si no hay imagen aborta (salvo `--accept-partial-backup`/`--no-backup`); (b) `docker rm -f` de los contenedores; (c) destruye el directorio efímero; (d) borra los ficheros (los de `root` con el mismo contenedor auxiliar; lo que no se pueda lo imprime como `sudo rm -rf …` y sale con 2). Si entre el plan y la ejecución aparece algo nuevo, aborta.
   Al terminar la skill imprime lo que queda **fuera de su alcance**: la línea de `/etc/hosts` (con el comando `sudo sed` para quitarla), el perfil `cloud-provisioner` de `~/.aws` (el paso 1 de la instalación lo regenera) y el estado GitOps en git.

## Reglas

- **Nunca** `apply` ni `local-apply` sin haber hecho el `plan`/`local-plan` correspondiente en esta sesión y sin la confirmación explícita del paso 2 y la del paso 4 (y la del paso 7 para lo local). **Nunca** `--no-backup` salvo que la persona lo pida expresamente tras saber qué se pierde. Los flags `--confirm-*` los escribes tú **solo después** de esas confirmaciones.
- **Nunca** editar a mano `clean.json`/`context.json` ni "arreglar" el filtro para que borre algo: el script lo detecta (sha256) y es lo que se revisó. Para proteger algo extra: `UNINSTALL_PROTECTED_IDS` / `UNINSTALL_PROTECTED_NAMES` en `cluster.env` y volver a `plan`.
- **No tocar el clúster** (ni kubectl, ni helm, ni escalar controladores): lo pidió así el flujo. Como CAPA/Flux viven dentro del EKS pueden recrear recursos durante una pasada; las pasadas siguientes lo recogen y la regla "recursos no revisados" lo vigila.
- **Recursos de la migración a GitOps (Loki)**: el bucket `<cluster>-loki` y el rol `loki-<cluster>` (PR keos-fleet#220 §4.4; los crea `gitops-prereqs.sh` o a mano) son `owned` por nombre y se borran con el resto; **Loki no es legacy** pero estos recursos sí son del clúster. Si hay que conservarlos, `UNINSTALL_PROTECTED_IDS`/`UNINSTALL_PROTECTED_NAMES` antes del `plan` (ver `references/ownership-and-protection.md`). La clave KMS `alias/flux-<cluster>` queda como `unowned` (no se borra).
- Si el remover se corta por `timeout` (código 124) casi seguro es un reintento sin límite de subnets/ENI (limitación conocida, ver `references/ownership-and-protection.md`): mira el log de la pasada, no subas el timeout a ciegas.
- Si `plan` falla por handlers ausentes, la cuenta no se puede dejar limpia con este remover: parar y avisar, no usar `SKIP_HANDLER_CHECK`.
- No borrar nada de la cuenta a mano salvo que la persona lo pida (p. ej. una instance profile huérfana que `verify` señale). Lo mismo para contenedores o ficheros que la fase local no liste.

## Qué queda fuera (no lo toca ni con la fase local; recordarlo al final)

Perfil local `cloud-provisioner` en `~/.aws` (su clave ya no existe; la instalación lo regenera), línea de `/etc/hosts` (la skill imprime el `sudo sed`), estado GitOps en git (`clusters/<cluster>` en flux-stratio/keos-fleet; los pushes solo al repo oficial) y el repositorio git del workspace.

## Ficheros

```
scripts/uninstall.sh          identify | plan | apply | verify | local-plan | local-apply
scripts/filter-resources.sh   filtro PURO (jq): clasifica cada recurso en protected / shared / owned / unowned
scripts/lib.sh                utilidades; resolución del toolkit; awsx de solo lectura
references/ownership-and-protection.md   reglas del filtro, motivos, límites conocidos
tests/run-offline-tests.sh    120 pruebas con aws/python/docker falsos (sin AWS ni docker real); mock/ y fixtures/ ficticios
```
Pruebas: `bash $SK/tests/run-offline-tests.sh` (no toca AWS).
