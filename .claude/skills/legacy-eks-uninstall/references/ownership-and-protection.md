# Protección y pertenencia (filter-resources.sh)

El finder lista **todo** lo que hay en la cuenta/región y el remover borra **todo** lo que le pasen: no tiene protecciones propias (la whitelist del finder solo cubre
`OrganizationAccountAccessRole`, algunos `AWSServiceRoleFor*`, `CloudHealth-*` y el stack `CHTRole`). Por eso el filtro decide, para cada `(tipo, id)`, en este orden:

| Clase | Qué es | Destino |
|---|---|---|
| `protected` | VPC por defecto (`isDefault`) y sus subnets, route tables, SG y ENI; claves KMS con `KeyManager=AWS`; workgroup Athena `primary`; roles `AWSServiceRole*`, `AWSReservedSSO_*`, `OrganizationAccountAccessRole`; el rol/usuario del llamador; `UNINSTALL_PROTECTED_IDS/NAMES` | **nunca** se pasa al remover (ni con `--include-unowned`) |
| `shared` | pila `cluster-api-provider-aws-sigs-k8s-io`, roles/policies `*.cluster-api-provider-aws.sigs.k8s.io`, policy `ecr-pull-through-cache-machinepool`, usuario `cloud-provisioner` | se borran (cuenta "de fábrica"); con `--keep-shared` pasan a `protected` |
| `owned` | nombre con el del clúster (IAM, S3, secretos, stacks, log groups), EKS y VPC del clúster, miembros de su VPC, zonas Route53 de su dominio, OIDC de su EKS; con cuenta dedicada, los tipos opacos (volúmenes, EIP, NLB/TG, ASG, EFS, instancias, ENI, NAT...) | se borran |
| `unowned` | cualquier otra cosa (nombres sin relación, VPC no identificada, tipos no previstos, claves KMS propias del cliente) | se **excluyen** e informan; solo con `--include-unowned` |

`filter-resources.sh` termina con una aserción: si algo `protected` aparece en `clean.json` aborta (código 3) y borra el fichero.

## Por qué cada protegido (comprobado en la cuenta de igualdad, 2026-11)

- **VPC por defecto**: el remover borra subnets y route tables e incluso desacopla y borra el IGW antes de la VPC (`_delete_vpc`). Se recrea con `create-default-vpc`, pero con IDs nuevos.
- **KMS gestionadas por AWS** (`alias/aws/ebs|efs|secretsmanager`): `schedule_key_deletion` falla, pero no hay motivo para intentarlo (y la automation de Stratio usa `--no-kms`).
- **Roles de servicio** (`AWSServiceRoleForAutoScaling`, `…EKSNodegroup`, `…ElasticFileSystem`) no están en la whitelist del finder; AWS los recrea solo en el primer uso.
- **`OrganizationAccountAccessRole`**: el acceso a la cuenta. Solo se comprueba su confianza y sus políticas (foto previa vs. verify); no hay roles SSO en estas cuentas.
- **Caller**: nunca se borra la identidad con la que se ejecuta; `ADMIN_PROFILE` no puede ser el usuario `cloud-provisioner`.

## Cuenta dedicada

`context` consulta todas las regiones habilitadas: si hay otro EKS, o una VPC no por defecto que no es la del clúster, `dedicated_account=false` y los tipos de id opaco que no estén dentro de la VPC del clúster se tratan como `unowned`. Sirve para no barrer lo de otro entorno que comparta cuenta.

## Pasadas y seguridad de la ejecución

- `plan` fija el sha256 de `clean.json` y la lista `planned.lst`; `apply` aborta si cambian. En cada pasada nueva se vuelve a ejecutar finder + filtro y, si aparece algo que no estaba en `planned.lst`, aborta (salvo `--accept-new`).
- Cada pasada corre con `timeout` (1200 s por defecto). Si dos pasadas seguidas tienen exactamente los mismos recursos, se para (sin progreso).
- Fallos esperables en una primera pasada con el remover actual: `ResourceInUseException` al borrar el EKS (no espera a los nodegroups) y subnets/SG/VPC mientras tanto. La segunda pasada los resuelve.

## Límites conocidos (del remover, no de la skill)

1. `_delete_eks_cluster` no espera a los nodegroups (pendiente en PLT-5240): hace falta una segunda pasada.
2. `_delete_subnet` y `_delete_ec2_network_interface` reintentan cada 30 s **sin límite**: si algo retiene una ENI (por ejemplo la de EKS mientras el cluster existe) el proceso no termina; el `timeout` por pasada es la red de seguridad.
3. El finder no lista **instance profiles** (`verify` las señala si quedan).
4. Solo opera en una región (la del `cluster.env`); `context` avisa de EKS en otras.
