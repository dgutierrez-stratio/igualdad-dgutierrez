# TENANT ${TENANT_NAME} del cluster ${CLUSTER_NAME}, variante S3 (sin hdfs). Generado por 2-apps-layer-kit
# (templates/tenant.yaml.tpl). NO EDITAR A MANO: regenerar con scripts/render-apps-layer.sh.
#%if INJECT_LLM_TOKEN
# ATENCION: este fichero CONTIENE SECRETOS (LLM_TOKEN): no subir a git. Permisos 600.
#%end
# Origen: eosdev/extensions.yaml del caso de uso. Cambios: bucket S3 en el env del tenant, connector-s3 en lugar
# del agente dfs, sin app de almacenamiento distribuido ni variables de conectores desacoplados de ese tipo.
# Las claves S3 (S3_BUCKET_ACCESS_KEY / S3_BUCKET_SECRET_KEY) NO van aqui: viven en ${APPS_LAYER_DIR}/.env
# (s3-requisites.sh env). Sin ellas las apps vuelven a su rama de almacenamiento por defecto y fallan lejos del origen.
# Hosts: ${HOSTS_MODE_TEXT}
# Ejecutar DESPUES del YAML raiz:  cd /apps-layer && apps-installer ${CLUSTER_NAME}-${TENANT_NAME}.yaml
#%if SIZE_CUSTOM
# ENVIRONMENT_SIZE=CUSTOM: las variables de recursos de cada app se inyectan en su env: desde el overlay del kit (templates/sizes-custom.env o CUSTOM_SIZES_FILE);
# apps-layer no carga ningun sizes/ con este valor. Para cambiarlas, edita el overlay y repite el render.
#%end
env:
  UNIVERSE_VERSION: "${UNIVERSE_VERSION}"
  UNIVERSE_VERSION_BUGFIX_ENABLED: false
  USER_ID: "admin"
  USER_NAME: "admin"
  ENVIRONMENT_SIZE: "${ENVIRONMENT_SIZE}"
  KEOS_WORKSPACE_DIR: "${KEOS_WORKSPACE_DIR}"
  KEOS_INSTALLER_EXTRA_ARGS: "${KEOS_INSTALLER_EXTRA_ARGS}"
tenants:
- name: ${TENANT_NAME}
  env:
    S3_BUCKET_NAME: ${S3_BUCKET_NAME}
#%if INJECT_LLM_TOKEN
    # El valor se inyecta al renderizar (desde el entorno o el .env). El tenant env se exporta con
    # export clave=valor sin comillas: el valor no puede llevar espacios ni comodines (el render lo valida).
    LLM_TOKEN: __LLM_TOKEN_PLACEHOLDER__
#%end
#%if LLM_PROVIDER_SET
    LLM_PROVIDER: "${LLM_PROVIDER}"
#%end
#%if LLM_MODEL_SET
    LLM_MODEL: "${LLM_MODEL}"
#%end
    DEPENDENCIES_OPENSEARCH_APP_NAME: opensearch1
    DEPENDENCIES_OPENSEARCH_APP_NAMESPACE_SUFFIX: datastores
    DEPENDENCIES_POSTGRES_APP_NAME: psql
    DEPENDENCIES_POSTGRES_APP_NAMESPACE_SUFFIX: datastores
    DEPENDENCIES_PGBOUNCER_APP_NAME: pool-psql
    DEPENDENCIES_PGBOUNCER_APP_NAMESPACE_SUFFIX: datastores
    DEPENDENCIES_VIRTUALIZER_APP_NAME: virtualizer
    DEPENDENCIES_VIRTUALIZER_APP_NAMESPACE_SUFFIX: apps
    DEPENDENCIES_VIRTUALIZER_API_APP_NAME: virtualizer-api
    DEPENDENCIES_VIRTUALIZER_API_APP_NAMESPACE_SUFFIX: apps
    DEPENDENCIES_VIRTUALIZER_MONITOR_APP_NAME: virtualizer-monitor
    DEPENDENCIES_VIRTUALIZER_MONITOR_APP_NAMESPACE_SUFFIX: apps
    DEPENDENCIES_CONNECTORS_APP_NAMESPACE_SUFFIX: apps
    DEPENDENCIES_DISCOVERY_APP_NAME: discovery
    DEPENDENCIES_DISCOVERY_APP_NAMESPACE_SUFFIX: apps
    DEPENDENCIES_ROCKET_APP_NAME: rocket
    DEPENDENCIES_ROCKET_APP_NAMESPACE_SUFFIX: rocket
    DEPENDENCIES_ROCKET_CATALOG_APP_NAME: rocket-catalog-standalone
    DEPENDENCIES_ROCKET_CATALOG_APP_NAMESPACE_SUFFIX: rocket
#%if GENAI_ON
    DEPENDENCIES_GENAI_GATEWAY_APP_NAMESPACE_SUFFIX: genai
    DEPENDENCIES_GENAI_LITELLM_APP_NAME: genai-litellm
    DEPENDENCIES_GENAI_API_APP_NAME: genai-api
    DEPENDENCIES_GENAI_API_APP_NAMESPACE_SUFFIX: genai
#%end
    DEPENDENCIES_EUREKA_AGENT_APP_NAME: eureka-agent
    DEPENDENCIES_EUREKA_AGENT_APP_NAMESPACE_SUFFIX: datastores
  apps:
  - parallel:
    - name: postgres
    - name: kafka
      env:
        APP_NAME: kafka1
    - name: connectors-management
      env:
        APP_NAMESPACE_SUFFIX: apps
#%if LOADER_PIN_SET
        # variable del kit CONNECTORS_LOADER_VERSION (def. 2.2.0, como Stratio/keos-fleet#220): el hook IGNORA el connectors-loader del universe-images.lst.
        # Vacia en kit.env => esta linea no se renderiza y el hook usa el .lst fresco (2.2.3 en branch-15.1).
        CONNECTORS_LOADER_VERSION: ${CONNECTORS_LOADER_VERSION}
#%end
    - name: opensearch
      env:
        APP_NAME: opensearch1
  - parallel:
    - name: postgres-agent
      env:
        DOMAINS_ENABLED: true
    - name: opensearch-agent
      env:
        APP_NAME: opensearch1-agent
    - name: pgbouncer
  - parallel:
    - name: opensearch-dashboards
      env:
        APP_NAME: opensearch1-dashboards
    - name: virtualizer
      env:
        APP_NAMESPACE_SUFFIX: apps
        VIRTUALIZER_DECOUPLED_CONNECTOR_POSTGRES: true
        VIRTUALIZER_CREATE_LOADBALANCER: ${VIRTUALIZER_CREATE_LOADBALANCER}
        VIRTUALIZER_CACHE_ON_DEMAND: false
        VIRTUALIZER_FACADE_AUTH_MODE: local
        VIRTUALIZER_HASH_FILTERED_COLUMNS: false
#%if GENAI_ON
    - name: genai-litellm
#%if TENANT_HOSTS_ON
      env:
        GENAI_HAPROXY_HOST: genai.${tenantId}.${external_domain}
        GENAI_HAPROXY_PATH: "/genai-litellm"
#%end
  - parallel:
    - name: genai-api
      env:
        GENAI_OPENSEARCH_ENABLED: true
#%if TENANT_HOSTS_ON
        GENAI_HAPROXY_HOST: genai.${tenantId}.${external_domain}
        GENAI_HAPROXY_PATH: "/genai-api"
#%end
#%end
  - parallel:
    - name: rocket-catalog-standalone
      env:
#%if TENANT_HOSTS_ON
        ROCKET_HAPROXY_HOST: rocket.${tenantId}.${external_domain}
#%end
        ROCKET_DECOUPLED_CONNECTOR_POSTGRES: true
    - name: rocket
      env:
#%if TENANT_HOSTS_ON
        ROCKET_HAPROXY_HOST: rocket.${tenantId}.${external_domain}
#%end
        ROCKET_OPENSEARCH_CONNECTOR_ENABLED: true
        ROCKET_DECOUPLED_CONNECTOR_POSTGRES: true
        ROCKET_INTELLIGENCE_ENABLED: true
#%if GENAI_ON
        ROCKET_GENAI_ENABLED: true
#%end
        ROCKET_OPENSEARCH_ENABLED: true
        ROCKET_SQL_CHAIN_CUSTOM_ID_ENABLED: true
        ROCKET_GENERIC_SQL_CHAIN_CUSTOM_ID_ENABLED: true
        ROCKET_PYSPARK_TRANSFORM_CHAIN_CUSTOM_ID_ENABLED: true
    - name: eureka-agent
      env:
        APP_NAMESPACE_SUFFIX: datastores
        EUREKA_DECOUPLED_CONNECTOR_POSTGRES: true
    - name: connector-s3
      env:
        APP_NAMESPACE_SUFFIX: datastores
        # variable del kit S3_INIT_PATH (def. /${S3_BUCKET_NAME}). vars.env de connector-s3 (apps-layer-automation branch-15.1-0.1) tiene la errata
        # `export INTI_PATH=...` (en vez de INIT_PATH): sin fijarlo aqui, connector-s3.json.tmpl renderiza "customInitPath": "" y el agente
        # (dg-s3-agent) crashea con "Missing environment variable: COMM_SERVICE_INIT_PATH" (parametro required, sin default en el descriptor).
        # OJO: el driver S3 NO admite "/" (UnsupportedRootInitPath: "Custom driver does not support '/' as init-path"); valido: /<bucket> o /<bucket>/<prefijo>.
        INIT_PATH: ${S3_INIT_PATH}
    - name: connector-rdbms-postgres-internal
      env:
        APP_NAMESPACE_SUFFIX: datastores
        INIT_PATH: /psql,/testatdlc
    - name: connector-rdbms-postgres-internal
      env:
        APP_NAME: dg-postgresql-internal-agent-op
        APP_NAMESPACE_SUFFIX: datastores
        SERVICE_NAME: psql.${TENANT_NAME}-datastores
  - parallel:
    - name: dlc-entity
#%if TENANT_HOSTS_ON
      env:
        DLC_HAPROXY_HOST: dlc-entity.${tenantId}.${external_domain}
#%end
    - name: discovery
      env:
        APP_NAMESPACE_SUFFIX: apps
#%if TENANT_HOSTS_ON
        DISCOVERY_HAPROXY_HOST: discovery.${tenantId}.${external_domain}
        DISCOVERY_HAPROXY_PATH: "/discovery"
#%end
        # Debe ser un grupo que exista en GoSec: con uno inexistente el post-install de discovery da 403 al crear la BD de
        # Virtualizer y apps-installer se detiene (PR keos-fleet#220, a73962b6). <tenant>-stratio-owners lo crea el tenant.
        DISCOVERY_ADMIN_GROUP: ${TENANT_NAME}-stratio-owners
        DISCOVERY_USE_GROUP_WHITELIST: false
    - name: intelligence
      env:
#%if TENANT_HOSTS_ON
        ROCKET_HAPROXY_HOST: rocket.${tenantId}.${external_domain}
#%end
#%if GENAI_ON
        INTELLIGENCE_GENAI_ENABLED: true
#%end
        INTELLIGENCE_OPENSEARCH_ENABLED: true
        INTELLIGENCE_DECOUPLED_CONNECTOR_POSTGRES: true
        INTELLIGENCE_SPARK_USER: root
        INTELLIGENCE_ADMIN_GROUPS: ${TENANT_NAME}-stratio-owners
        INTELLIGENCE_ADMIN_USERS: admin,${TENANT_NAME}-user
    - name: virtualizer-monitor
      env:
        APP_NAMESPACE_SUFFIX: apps
#%if TENANT_HOSTS_ON
        VIRTUALIZER_SERVER_HOST: virtualizer.${tenantId}.${external_domain}
#%end
  - parallel:
    - name: virtualizer-ui
      env:
        APP_NAMESPACE_SUFFIX: apps
#%if TENANT_HOSTS_ON
        VIRTUALIZER_UI_HAPROXY_HOST: virtualizer.${tenantId}.${external_domain}
#%end
#%if GENAI_ON
    - name: datamarket-agent
      env:
        APP_NAMESPACE_SUFFIX: datastores
    - name: genai-ui
      env:
        GENAI_OPENSEARCH_ENABLED: true
        DEPENDENCIES_OPENSEARCH_GOVERNANCE_APP_NAME: "opensearch1"
        DISCOVERY_DATABASE: 3
#%if TENANT_HOSTS_ON
        GENAI_HAPROXY_HOST: genai.${tenantId}.${external_domain}
        GENAI_HAPROXY_PATH: "/genai-ui"
        DISCOVERY_HAPROXY_HOST: discovery.${tenantId}.${external_domain}
        DISCOVERY_HAPROXY_PATH: discovery
#%end
  - parallel:
    - name: pit
      env:
        # no hay hdfs: evita aplicar pit/gosec-policies/hdfs-usage-policy.json (con version de gosec vacia)
        HDFS_USAGE_POLICY_POLICY_ENABLED: false
#%else
  # ENABLE_GENAI=false: se omiten genai-litellm/api/ui y tambien datamarket-agent y pit, porque sus hooks
  # (post-install/post-deploy) asignan roles y grupos de GoSec que crea genai-api. Ver README.
#%end
  - parallel:
    - name: dg-datarest-pgi
      env:
        APP_NAMESPACE_SUFFIX: datastores
#%if TENANT_HOSTS_ON
  - parallel:
    - name: dlc-entity
      env:
        APP_NAMESPACE_SUFFIX: dlc
        DLC_HAPROXY_HOST: dlc.${tenantId}.${external_domain}
#%end
