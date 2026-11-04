---
name: legacy-eks-uninstall
description: Desinstala un clúster EKS "legacy" instalado con la skill legacy-eks-cluster y deja la cuenta AWS limpia y reutilizable, usando el finder y el remover de aws-marketplace-toolkit (PR #51 / PLT-5240 mergeada) con un filtro que protege lo que no debe borrarse (VPC por defecto, claves KMS de AWS, roles de servicio, OrganizationAccountAccessRole, la identidad del llamador). Confirma con la persona usuaria el clúster instalado y la cuenta antes de borrar. Úsala cuando se pida "desinstalar/eliminar/borrar/limpiar el clúster de igualdad", "dejar la cuenta de fábrica / limpia / como estaba", "ejecutar el finder y el remover", o "limpiar la cuenta AWS tras una instalación/migración". Para desmontar el clúster paso a paso con CAPI (y apps-layer/contenedores locales) sigue existiendo teardown.sh en legacy-eks-cluster.
---

# legacy-eks-uninstall

Deja la cuenta AWS donde se instaló un clúster legacy (cloud-provisioner + keos-installer + apps-layer, y lo que se hiciera después sobre ella) **como si nunca hubiera pasado nada**, sin perder el acceso por CLI/consola. El trabajo pesado lo hace el **remover** de Stratio (`aws-marketplace-toolkit`); esta skill
(1) identifica y confirma el clúster, (2) ejecuta el **finder**, (3) **filtra** lo que no debe borrarse, (4) ejecuta el remover en pasadas y (5) verifica el resultado.

`SK` = directorio de esta skill. Los scripts son autocontenidos y **solo leen AWS** (un guard bloquea cualquier operación que no sea `describe|list|get`); los borrados los hace únicamente el remover. Los ficheros de cada ejecución (sin secretos) van a `<dir-del-clúster>/uninstall/`.

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

## Reglas

- **Nunca** `apply` sin haber hecho `plan` en esta sesión y sin la confirmación explícita del paso 2 y la del paso 4. Los flags `--confirm-*` los escribes tú **solo después** de esas confirmaciones.
- **Nunca** editar a mano `clean.json`/`context.json` ni "arreglar" el filtro para que borre algo: el script lo detecta (sha256) y es lo que se revisó. Para proteger algo extra: `UNINSTALL_PROTECTED_IDS` / `UNINSTALL_PROTECTED_NAMES` en `cluster.env` y volver a `plan`.
- **No tocar el clúster** (ni kubectl, ni helm, ni escalar controladores): lo pidió así el flujo. Como CAPA/Flux viven dentro del EKS pueden recrear recursos durante una pasada; las pasadas siguientes lo recogen y la regla "recursos no revisados" lo vigila.
- Si el remover se corta por `timeout` (código 124) casi seguro es un reintento sin límite de subnets/ENI (limitación conocida, ver `references/ownership-and-protection.md`): mira el log de la pasada, no subas el timeout a ciegas.
- Si `plan` falla por handlers ausentes, la cuenta no se puede dejar limpia con este remover: parar y avisar, no usar `SKIP_HANDLER_CHECK`.
- No borrar nada de la cuenta a mano salvo que la persona lo pida (p. ej. una instance profile huérfana que `verify` señale).

## Qué queda fuera de AWS (no lo toca; recordarlo al final)

Perfil local `cloud-provisioner` en `~/.aws` (su clave ya no existe), línea de `/etc/hosts`, estado GitOps en git (`clusters/<cluster>` en flux-stratio/keos-fleet; los pushes solo al repo oficial), el directorio de trabajo `clusters/<cluster>` (conserva `cluster.env`, `logs/` y ahora `uninstall/`) y los contenedores locales `keos-installer*`/`apps-layer-*` (los limpia la fase A de `legacy-eks-cluster/scripts/teardown.sh`).

## Ficheros

```
scripts/uninstall.sh          identify | plan | apply | verify
scripts/filter-resources.sh   filtro PURO (jq): clasifica cada recurso en protected / shared / owned / unowned
scripts/lib.sh                utilidades; resolución del toolkit; awsx de solo lectura
references/ownership-and-protection.md   reglas del filtro, motivos, límites conocidos
tests/run-offline-tests.sh    55 pruebas con aws/python falsos (sin AWS); mock/ y fixtures/ ficticios
```
Pruebas: `bash $SK/tests/run-offline-tests.sh` (no toca AWS).
