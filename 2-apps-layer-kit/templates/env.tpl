# ${APPS_LAYER_DIR}/.env  (chmod 600). Generado por 2-apps-layer-kit (templates/env.tpl).
# Lo carga con "source" el entrypoint del contenedor; sus variables las heredan apps-installer y los hooks.
# Dentro de un contenedor ya arrancado: source /apps-layer/.env
# Las lineas secretas (S3_BUCKET_ACCESS_KEY, S3_BUCKET_SECRET_KEY, LLM_TOKEN) no vienen de esta plantilla:
# las anaden s3-requisites.sh env e import-llm-token.sh y el render las conserva. No subir a git.
# Con ENABLE_BACKUPS_BUCKET=true, s3-requisites.sh env anade ademas BACKUPS_S3_BUCKET_{ACCESS_KEY,SECRET_KEY,NAME,REGION}
# (apps-layer-automation NO las usa: son para hacer `source` al migrar a GitOps); el render tambien las conserva.
export DOCKER_DIND_ENABLED=false
export KEOS_WORKSPACE_DIR=${KEOS_WORKSPACE_DIR}
export KEOS_INSTALLER_EXTRA_ARGS="${KEOS_INSTALLER_EXTRA_ARGS}"
export AWS_REGION=${AWS_REGION}
