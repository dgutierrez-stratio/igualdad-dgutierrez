# RAIZ del cluster ${CLUSTER_NAME}: tenant keos (gobierno). Generado por 2-apps-layer-kit (templates/root.yaml.tpl).
# NO EDITAR A MANO: regenerar con scripts/render-apps-layer.sh. Perfil de gobierno: ${KEOS_PROFILE}.
# CLUSTER_NAME y EXT_DOMAIN no se definen: apps-installer los recalcula desde el objeto keos
# (CLUSTER_NAME=admin, EXT_DOMAIN=${EXTERNAL_DOMAIN}). Esta parte no depende de HDFS ni de S3.
# Ejecutar dentro del contenedor:  cd /apps-layer && apps-installer ${CLUSTER_NAME}.yaml
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
- name: keos
  apps:
#%if KEOS_MINIMAL
  # Gobierno minimo (PR 220): sin opensearch/se-*; el buscador de governance-ui se desactiva.
  - parallel:
    - name: dg-businessglossary-api
  - parallel:
    - name: dg-ontology-graph-api
    - name: dg-discovery-manager
  - parallel:
    - name: governance-map
    - name: governance-ui
      env:
        GOVERNANCE_UI_ENABLE_SEARCHER: "false"
#%else
  # Gobierno completo (caso de uso del lab, eosdev.yaml): opensearch1 + stack se-* + datamarket.
  - parallel:
    - name: dg-businessglossary-api
  - parallel:
    - name: opensearch
      env:
        APP_NAME: opensearch1
        APP_NAMESPACE_SUFFIX: core
        PHONETIC_PLUGIN_ENABLED: true
        PHONETIC_PLUGIN_OFFLINE: false
    - name: dg-ontology-graph-api
  - parallel:
    - name: opensearch-agent
      env:
        APP_NAME: opensearch1-agent
        APP_NAMESPACE_SUFFIX: core
        DEPENDENCIES_OPENSEARCH_APP_NAME: opensearch1
        DEPENDENCIES_OPENSEARCH_APP_NAMESPACE_SUFFIX: core
    - name: dg-discovery-manager
    - name: governance-map
  - parallel:
    - name: se-searcher
      env:
        APP_NAME: se-searcher
        APP_NAMESPACE_SUFFIX: core
        DEPENDENCIES_OPENSEARCH_APP_NAME: opensearch1
        DEPENDENCIES_OPENSEARCH_APP_NAMESPACE_SUFFIX: core
        SEARCH_ENGINE_MUTUAL_TLS_ENABLED: true
        SEARCH_ENGINE_MUTUAL_TLS_CN_WHITELIST: dg-scheduler-agent
        SEARCH_ENGINE_PHONETIC_PLUGIN_ENABLED: true
    - name: se-manager
      env:
        APP_NAME: se-manager
        APP_NAMESPACE_SUFFIX: core
        DEPENDENCIES_OPENSEARCH_APP_NAME: opensearch1
        DEPENDENCIES_OPENSEARCH_APP_NAMESPACE_SUFFIX: core
        SEARCH_ENGINE_MUTUAL_TLS_ENABLED: true
        SEARCH_ENGINE_MUTUAL_TLS_CN_WHITELIST: dg-scheduler-agent
        SEARCH_ENGINE_PHONETIC_PLUGIN_ENABLED: true
    - name: se-indexer
      env:
        APP_NAME: se-indexer
        APP_NAMESPACE_SUFFIX: core
        DEPENDENCIES_OPENSEARCH_APP_NAME: opensearch1
        DEPENDENCIES_OPENSEARCH_APP_NAMESPACE_SUFFIX: core
        SEARCH_ENGINE_MUTUAL_TLS_ENABLED: true
        SEARCH_ENGINE_MUTUAL_TLS_CN_WHITELIST: dg-scheduler-agent
        SEARCH_ENGINE_PHONETIC_PLUGIN_ENABLED: true
  - parallel:
    - name: governance-ui
      env:
        DEPENDENCIES_SE_MANAGER_APP_NAME: se-manager
        DEPENDENCIES_SE_MANAGER_APP_NAMESPACE_SUFFIX: core
        DEPENDENCIES_SE_SEARCHER_APP_NAME: se-searcher
        DEPENDENCIES_SE_SEARCHER_APP_NAMESPACE_SUFFIX: core
    - name: dg-scheduler-agent
      env:
        DEPENDENCIES_SE_MANAGER_APP_NAME: se-manager
        DEPENDENCIES_SE_MANAGER_APP_NAMESPACE_SUFFIX: core
        DEPENDENCIES_SE_INDEXER_APP_NAME: se-indexer
        DEPENDENCIES_SE_INDEXER_APP_NAMESPACE_SUFFIX: core
        DG_SCHEDULER_AGENT_PARTIAL_INDEXATION_INTERVAL: 30
        SEARCH_ENGINE_PHONETIC_PLUGIN_ENABLED: true
  - parallel:
    - name: dg-datamarket-api
      env:
        DEPENDENCIES_SE_SEARCHER_APP_NAME: se-searcher
        DEPENDENCIES_SE_SEARCHER_APP_NAMESPACE_SUFFIX: core
  - parallel:
    - name: governance-datamarket-ui
      env:
        DISABLE_OWNER_INFO: true
#%end
