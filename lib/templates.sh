#!/bin/bash

# =============================================================================
# NODEBOI CENTRALIZED TEMPLATES
# =============================================================================
# All .env and compose.yml generation functions for nodeboi services
# This file centralizes template generation to ensure consistency and 
# eliminate duplication across the codebase.
#
# Template functions follow the pattern:
# - generate_<service>_env()
# - generate_<service>_compose()
#
# All templates are 100% compliant with the nodeboi guide architecture.
# =============================================================================

# =============================================================================
# VERO VALIDATOR TEMPLATES
# =============================================================================

# Generate Vero .env file
generate_vero_env() {
    local service_dir="$1"
    local node_uid="$2"
    local node_gid="$3"
    local network="$4"
    local beacon_urls="$5"
    local web3signer_port="$6"
    local fee_recipient="$7"
    local graffiti="$8"
    
    cat > "${service_dir}/.env" <<EOF
# =============================================================================
# VERO VALIDATOR CONFIGURATION
# =============================================================================
# Stack identification
VERO_NETWORK=vero

# User mapping (auto-detected)
VERO_UID=${node_uid}
VERO_GID=${node_gid}

# Network binding for metrics port
HOST_BIND_IP=127.0.0.1

# Ethereum network
ETH2_NETWORK=${network}

# =============================================================================
# CONNECTION CONFIGURATION
# =============================================================================
# Beacon node connections
BEACON_NODE_URLS=${beacon_urls}

# Consensus settings - how many beacon nodes must agree on attestation data. 
# If not set, will default to majority, for example: 1/2, 2/3.
# ATTESTATION_CONSENSUS_THRESHOLD=1

# =============================================================================
# VALIDATOR CONFIGURATION
# =============================================================================
# Validator settings
FEE_RECIPIENT=${fee_recipient}
GRAFFITI=${graffiti}

# =============================================================================
# SERVICE CONFIGURATION
# =============================================================================
# Vero
VERO_VERSION=v1.2.0
VERO_METRICS_PORT=9010
LOG_LEVEL=INFO
EOF

    chmod 600 "${service_dir}/.env"
}

# Generate Vero compose.yml file
generate_vero_compose() {
    local service_dir="$1"
    shift 1
    local ethnodes=("$@")
    
    # Handle both service directory and temp file paths
    local output_file="${service_dir}"
    if [[ "$service_dir" == *".tmp" ]]; then
        # This is a temp file path, use it directly
        output_file="${service_dir}"
    elif [[ "$service_dir" != *"/compose.yml" ]]; then
        # This is a service directory, append compose.yml
        output_file="${service_dir}/compose.yml"
    fi
    
    # Build ethnode networks dynamically
    local ethnode_networks=""
    local ethnode_network_defs=""
    for ethnode in "${ethnodes[@]}"; do
        ethnode_networks="${ethnode_networks}
      - ${ethnode}-net"
        ethnode_network_defs="${ethnode_network_defs}
  ${ethnode}-net:
    external: true
    name: ${ethnode}-net"
    done
    
    cat > "${output_file}" <<EOF
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  vero:
    image: ghcr.io/serenita-org/vero:\${VERO_VERSION}
    container_name: vero
    restart: unless-stopped
    user: "\${VERO_UID}:\${VERO_GID}"
    environment:
      - LOG_LEVEL=\${LOG_LEVEL}
    ports:
      - "\${HOST_BIND_IP}:\${VERO_METRICS_PORT}:\${VERO_METRICS_PORT}"
    command: [
      "--network=\${ETH2_NETWORK}",
      "--beacon-node-urls=\${BEACON_NODE_URLS}",
      "--remote-signer-url=http://web3signer:7500",
      "--attestation-consensus-threshold=\${ATTESTATION_CONSENSUS_THRESHOLD:-1}",
      "--fee-recipient=\${FEE_RECIPIENT}",
      "--enable-doppelganger-detection",
      "--graffiti=\${GRAFFITI}",
      "--metrics-address=0.0.0.0",
      "--metrics-port=\${VERO_METRICS_PORT}",
      "--log-level=\${LOG_LEVEL}"
    ]
    networks:
      - validator-net
      - web3signer-net${ethnode_networks}
    <<: *logging

networks:
  validator-net:
    external: true
    name: validator-net
  web3signer-net:
    external: true
    name: web3signer-net${ethnode_network_defs}
EOF
}

# =============================================================================
# WEB3SIGNER TEMPLATES
# =============================================================================

# Generate Web3signer .env file
generate_web3signer_env() {
    local service_dir="$1"
    local postgres_password="$2"
    local keystore_password="$3"
    local network="$4"
    local keystore_location="$5"
    local web3signer_port="$6"
    local web3signer_version="$7"
    local node_uid="$8"
    local node_gid="$9"
    
    cat > "${service_dir}/.env" <<EOF
#=============================================================================
# WEB3SIGNER STACK CONFIGURATION  
#=============================================================================
# Docker network name for container communication
WEB3SIGNER_NETWORK=web3signer

# User mapping (auto-detected)
W3S_UID=${node_uid}
W3S_GID=${node_gid}

#=============================================================================
# API PORT BINDING
#=============================================================================
HOST_BIND_IP=127.0.0.1

#============================================================================
# NODE CONFIGURATION
#============================================================================
# Ethereum network (mainnet, sepolia, Hoodi, or custom URL)
ETH2_NETWORK=${network}

#=============================================================================
# SERVICE CONFIGURATION
#=============================================================================
# Web3signer
WEB3SIGNER_VERSION=${web3signer_version}
WEB3SIGNER_PORT=7500
PG_DOCKER_TAG=16-bookworm
LOG_LEVEL=info
JAVA_OPTS=-Xmx4g

# Keystore configuration
KEYSTORE_PASSWORD=${keystore_password}
KEYSTORE_LOCATION=${keystore_location}

# Postgres password
POSTGRES_PASSWORD=${postgres_password}
EOF

    chmod 600 "${service_dir}/.env"
}

# Generate Web3signer compose.yml file
generate_web3signer_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/compose.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  postgres:
    image: postgres:${PG_DOCKER_TAG}
    container_name: web3signer-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: web3signer
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - web3signer
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d web3signer"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    <<: *logging

  web3signer-init:
    image: consensys/web3signer:${WEB3SIGNER_VERSION}
    container_name: web3signer-init
    user: "0:0"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./web3signer_config:/config
      - web3signer_data:/var/lib/web3signer
      - ./docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro
    entrypoint: ["/bin/bash", "-c"]
    command: |
      "set -e
      echo 'Initializing Web3signer directories...'
      
      # Create migrations directory first
      mkdir -p /config/migrations
      
      # Extract migrations for Flyway
      cp -r /opt/web3signer/migrations/postgresql/* /config/migrations/ 2>/dev/null || true
      
      # Set up entrypoint
      if [ -f /usr/local/bin/docker-entrypoint.sh ]; then
        cp /usr/local/bin/docker-entrypoint.sh /var/lib/web3signer/docker-entrypoint.sh
        chmod +x /var/lib/web3signer/docker-entrypoint.sh
      fi
      
      # Set proper ownership
      chown -R ${W3S_UID}:${W3S_GID} /var/lib/web3signer
      chown -R ${W3S_UID}:${W3S_GID} /config
      
      echo 'Initialization complete'"
    networks:
      - web3signer

  flyway:
    image: flyway/flyway:10-alpine
    container_name: web3signer-flyway
    depends_on:
      web3signer-init:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy
    volumes:
      - ./web3signer_config/migrations:/flyway/sql:ro
      - web3signer_data:/var/lib/web3signer
    command: >
      -url=jdbc:postgresql://postgres:5432/web3signer
      -user=postgres
      -password=${POSTGRES_PASSWORD}
      -connectRetries=60
      -mixed=true
      migrate
    environment:
      - FLYWAY_PLACEHOLDERS_NETWORK=${ETH2_NETWORK}
    networks:
      - web3signer

  web3signer:
    image: consensys/web3signer:${WEB3SIGNER_VERSION}
    container_name: web3signer
    restart: unless-stopped
    user: "${W3S_UID}:${W3S_GID}"
    depends_on:
      flyway:
        condition: service_completed_successfully
    ports:
      - "${HOST_BIND_IP}:${WEB3SIGNER_PORT}:7500"
    volumes:
      - ./web3signer_config/keystores:/var/lib/web3signer/keystores:ro
      - web3signer_data:/var/lib/web3signer
      - /etc/localtime:/etc/localtime:ro
    environment:
      - JAVA_OPTS=${JAVA_OPTS}
      - ETH2_NETWORK=${ETH2_NETWORK}
    entrypoint: ["/var/lib/web3signer/docker-entrypoint.sh"]
    command: [
      "/opt/web3signer/bin/web3signer",
      "--http-listen-host=0.0.0.0",
      "--http-listen-port=7500",
      "--metrics-enabled",
      "--metrics-host-allowlist=*",
      "--http-host-allowlist=*",
      "--logging=${LOG_LEVEL}",
      "eth2",
      "--keystores-path=/var/lib/web3signer/keystores",
      "--keystores-passwords-path=/var/lib/web3signer/keystores",
      "--key-manager-api-enabled=true",
      "--slashing-protection-db-url=jdbc:postgresql://postgres:5432/web3signer",
      "--slashing-protection-db-username=postgres",
      "--slashing-protection-db-password=${POSTGRES_PASSWORD}",
      "--slashing-protection-pruning-enabled=true"
    ]
    networks:
      - web3signer
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9000/upcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - metrics.scrape=true
      - metrics.path=/metrics
      - metrics.port=9000
      - metrics.instance=web3signer
      - metrics.network=${ETH2_NETWORK}
    <<: *logging

volumes:
  postgres_data:
    name: web3signer_postgres_data
  web3signer_data:
    name: web3signer_data

networks:
  web3signer:
    name: web3signer-net
    driver: bridge
    external: true
EOF
}

# =============================================================================
# ETHNODE TEMPLATES
# =============================================================================

# Generate Ethnode .env file
generate_ethnode_env() {
    local service_dir="$1"
    local node_name="$2"
    local node_uid="$3"
    local node_gid="$4"
    local network="$5"
    local exec_client="$6"
    local cons_client="$7"
    local mevboost_enabled="$8"
    local el_rpc_port="$9"
    local el_ws_port="${10}"
    local ee_port="${11}"
    local el_p2p_port="${12}"
    local el_p2p_port_2="${13}"
    local cl_rest_port="${14}"
    local cl_p2p_port="${15}"
    local cl_quic_port="${16}"
    local mevboost_port="${17}"
    
    # Build COMPOSE_FILE string
    local compose_files="compose.yml:${exec_client}.yml:${cons_client}-cl-only.yml"
    if [[ "$mevboost_enabled" == "true" ]]; then
        compose_files="${compose_files}:mevboost.yml"
    fi
    
    # Set checkpoint sync URL based on network
    local checkpoint_url
    if [[ "$network" == "hoodi" ]]; then
        checkpoint_url="https://hoodi.beaconstate.ethstaker.cc/"
    else
        checkpoint_url="https://beaconstate.ethstaker.cc/"
    fi

    cat > "${service_dir}/.env" <<EOF
#============================================================================
# CLIENT SELECTION - Choose your stack by editing COMPOSE_FILE
#============================================================================
# Choose any combination of clients:
COMPOSE_FILE=${compose_files}

NODE_NAME=${node_name}
NODE_UID=${node_uid}
NODE_GID=${node_gid}

#============================================================================
# CLIENT VERSIONS 
#============================================================================
GETH_VERSION=v1.16.2
RETH_VERSION=v1.6.0
NETHERMIND_VERSION=1.32.4
BESU_VERSION=25.7.0
ERIGON_VERSION=v3.0.15

LIGHTHOUSE_VERSION=v7.1.0
LODESTAR_VERSION=v1.33.0
PRYSM_VERSION=v6.0.4
TEKU_VERSION=25.7.1
NIMBUS_VERSION=v25.7.1
GRANDINE_VERSION=1.1.4

MEVBOOST_VERSION=1.9

#============================================================================
# MEVBOOST CONFIGURATION
#============================================================================
MEV_BOOST=http://mevboost:18550
MEV_NODE=http://mevboost:18550

# Hoodi relays
MEVBOOST_RELAY=https://0xafa4c6985aa049fb79dd37010438cfebeb0f2bd42b115b89dd678dab0670c1de38da0c4e9138c9290a398ecd9a0b3110@boost-relay-hoodi.flashbots.net,https://0x98f0ef62f00780cf8eb06701a7d22725b9437d4768bb19b363e882ae87129945ec206ec2dc16933f31d983f8225772b6@hoodi.aestus.live,https://0xaa58208899c6105603b74396734a6263cc7d947f444f396a90f7b7d3e65d102aec7e5e5291b27e08d02c50a050825c2f@hoodi.titanrelay.xyz

# Mainnet relays (Lido approved relays)
#MEVBOOST_RELAY=https://0xb0b07cd0abef743db4260b0ed50619cf6ad4d82064cb4fbec9d3ec530f7c5e6793d9f286c4e082c0244ffb9f2658fe88@bloxroute.regulated.blxrbdn.com,https://0x8b5d2e73e2a3a55c6c87b8b6eb92e0149a125c852751db1422fa951e42a09b82c142c3ea98d0d9930b056a3bc9896b8f@bloxroute.max-profit.blxrbdn.com,https://0xac6e77dfe25ecd6110b8e780608cce0dab71fdd5ebea22a16c0205200f2f8e2e3ad3b71d3499c54ad14d6c21b41a37ae@boost-relay.flashbots.net,https://0x98650451ba02064f7b000f5768cf0cf4d4e492317d82871bdc87ef841a0743f69f0f1eea11168503240ac35d101c9135@mainnet-relay.securerpc.com,https://0xa15b52576bcbf1072f4a011c0f99f9fb6c66f3e1ff321f11f461d15e31b1cb359caa092c71bbded0bae5b5ea401aab7e@aestus.live,https://0xa1559ace749633b997cb3fdacffb890aeebdb0f5a3b6aaa7eeeaf1a38af0a8fe88b9e4b1f61f236d2e64d95733327a62@relay.ultrasound.money,https://0xa7ab7a996c8584251c8f925da3170bdfd6ebc75d50f5ddc4050a6fdc77f2a3b5fce2cc750d0865e05d7228af97d69561@agnostic-relay.net,https://0x8c4ed5e24fe5c6ae21018437bde147693f68cda427cd1122cf20819c30eda7ed74f72dece09bb313f2a1855595ab677d@regional.titanrelay.xyz,https://0x8c4ed5e24fe5c6ae21018437bde147693f68cda427cd1122cf20819c30eda7ed74f72dece09bb313f2a1855595ab677d@global.titanrelay.xyz

#============================================================================
# PORT BINDING CONFIGURATION
#============================================================================
# HOST_IP - Where Docker binds ports on your machine:
# 127.0.0.1 = localhost only (recommended)
# 0.0.0.0 = all network interfaces
# Web3Signer handles your keys, keep it as isolated as possible.
HOST_IP=127.0.0.1

#============================================================================
# NODE CONFIGURATION
#============================================================================
NETWORK=${network}
EL_NODE=http://execution:8551

# Checkpoint Sync URLs (set based on network)
CHECKPOINT_SYNC_URL=${checkpoint_url}

#============================================================================
# PEER CONFIGURATION
#============================================================================
EL_MAX_PEER_COUNT=100
CL_MAX_PEER_COUNT=100
CL_MIN_PEER_COUNT=64

#============================================================================
# CLIENT PORTS (Dynamically allocated by port manager)
#============================================================================
# Execution Layer
EL_RPC_PORT=${el_rpc_port}
EL_WS_PORT=${el_ws_port}
EE_PORT=${ee_port}
EL_P2P_PORT=${el_p2p_port}
EL_P2P_PORT_2=${el_p2p_port_2}

# Consensus Layer
CL_REST_PORT=${cl_rest_port}
CL_P2P_PORT=${cl_p2p_port}
CL_QUIC_PORT=${cl_quic_port}

# MEV-Boost
MEVBOOST_PORT=${mevboost_port}

#============================================================================
# MISCELLANEOUS CONFIGURATIONS
#============================================================================
EXECUTION_ALIAS=${node_name}
CONSENSUS_ALIAS=${node_name}

LODESTAR_HEAP_MB=8192

# Optional for Reth, Geth & Erigon: set your external IP for NAT advertising 
# EXTERNAL_IP=

EOF

    chmod 600 "${service_dir}/.env"
}

# Generate Ethnode base compose.yml file
generate_ethnode_compose() {
    local service_dir="$1"
    local node_name="${2:-ethnode1}"  # Default fallback
    
    cat > "${service_dir}/compose.yml" <<EOF
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

networks:
  ${node_name}-net:
    name: ${node_name}-net
    external: true
EOF
}

# Generate Besu execution client template
generate_besu_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/besu.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  execution:
    container_name: ${NODE_NAME}-besu
    restart: "unless-stopped"
    image: hyperledger/besu:${BESU_VERSION}
    pull_policy: always
    user: "${NODE_UID}:${NODE_GID}"
    stop_grace_period: 5m
    environment:
      - JAVA_OPTS=${BESU_HEAP:--Xmx5g}
      - EL_EXTRAS=${EL_EXTRAS:-}
      - ARCHIVE_NODE=${EL_ARCHIVE_NODE:-}
      - MINIMAL_NODE=${EL_MINIMAL_NODE:-}
      - NETWORK=${NETWORK}
      - IPV6=${IPV6:-false}
    volumes:
      - ./data/execution:/var/lib/besu
      - /etc/localtime:/etc/localtime:ro
      - ./jwt:/var/lib/besu/ee-secret
    ports:
      - ${HOST_IP:-}:${EL_RPC_PORT}:8545/tcp
      - ${HOST_IP:-}:${EL_WS_PORT}:8546/tcp
      - ${HOST_IP:-}:${EE_PORT}:8551/tcp
      - ${HOST_IP:-}:6060:6060/tcp
      - ${HOST_IP:-}:${EL_P2P_PORT}:${EL_P2P_PORT}/tcp
      - ${HOST_IP:-}:${EL_P2P_PORT}:${EL_P2P_PORT}/udp
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    entrypoint:
      - /opt/besu/bin/besu
      - --network=${NETWORK}
      - --p2p-port=${EL_P2P_PORT}
      - --rpc-http-enabled
      - --rpc-http-host=0.0.0.0
      - --rpc-http-port=8545
      - --rpc-http-cors-origins=*
      - --rpc-http-max-active-connections=65536
      - --rpc-max-logs-range=65536
      - --rpc-ws-enabled
      - --rpc-ws-host=0.0.0.0
      - --rpc-ws-port=8546
      - --max-peers=${EL_MAX_PEER_COUNT}
      - --host-allowlist=*
      - --engine-host-allowlist=*
      - --engine-jwt-secret=/var/lib/besu/ee-secret/jwtsecret
      - --engine-rpc-port=8551
      - --engine-rpc-enabled
      - --logging=INFO
      - --metrics-enabled
      - --metrics-host=0.0.0.0
      - --metrics-port=6060
      - --nat-method=DOCKER
      - --data-path=/var/lib/besu
    labels:
      - prometheus.scrape=true
      - prometheus.job=besu
      - prometheus.port=6060
      - prometheus.path=/metrics
      - ethereum.client=besu
      - ethereum.layer=execution
      - ethereum.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

# Generate Reth execution client template
generate_reth_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/reth.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  execution:
    container_name: ${NODE_NAME}-reth
    image: ghcr.io/paradigmxyz/reth:${RETH_VERSION}
    restart: unless-stopped
    stop_grace_period: 1m
    stop_signal: SIGINT
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${HOST_IP:-}:${EL_RPC_PORT}:8545"
      - "${HOST_IP:-}:${EL_WS_PORT}:8546"
      - "${HOST_IP:-}:${EE_PORT}:8551"
      - "${HOST_IP:-}:9001:9001"
      - "${HOST_IP:-}:${EL_P2P_PORT}:${EL_P2P_PORT}/tcp"
      - "${HOST_IP:-}:${EL_P2P_PORT}:${EL_P2P_PORT}/udp"
      - "${HOST_IP:-}:${EL_P2P_PORT_2}:${EL_P2P_PORT_2}/udp"
    volumes:
      - ./data/execution:/opt/reth/data
      - ./jwt:/opt/reth/jwt:ro
      - /etc/localtime:/etc/localtime:ro
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    command:
      - "node"
      - "--chain"
      - "${NETWORK}"
      - "--datadir"
      - "/opt/reth/data"
      - "--port"
      - "${EL_P2P_PORT}"
      - "--discovery.port"
      - "${EL_P2P_PORT}"
      - "--enable-discv5-discovery"
      - "--discovery.v5.port"
      - "${EL_P2P_PORT_2}"
      - "--http"
      - "--http.addr"
      - "0.0.0.0"
      - "--http.port"
      - "8545"
      - "--http.api"
      - "eth,net,web3,debug,trace"
      - "--http.corsdomain"
      - "http://127.0.0.1,http://localhost"
      - "--ws"
      - "--ws.addr"
      - "0.0.0.0"
      - "--ws.port"
      - "8546"
      - "--ws.origins"
      - "http://127.0.0.1,http://localhost"
      - "--authrpc.addr"
      - "0.0.0.0"
      - "--authrpc.port"
      - "8551"
      - "--authrpc.jwtsecret"
      - "/opt/reth/jwt/jwtsecret"
      - "--metrics"
      - "0.0.0.0:9001"
      - "--max-outbound-peers"
      - "${EL_MAX_PEER_COUNT}"
      - "--log.file.directory"
      - "/opt/reth/data/logs"
    labels:
      - prometheus.scrape=true
      - prometheus.job=reth
      - prometheus.port=9001
      - prometheus.path=/metrics
      - ethereum.client=reth
      - ethereum.layer=execution
      - ethereum.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

# Generate Nethermind execution client template
generate_nethermind_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/nethermind.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  execution:
    container_name: ${NODE_NAME}-nethermind
    restart: "unless-stopped"
    image: nethermind/nethermind:${NETHERMIND_VERSION}
    pull_policy: always
    user: "${NODE_UID}:${NODE_GID}"
    stop_grace_period: 5m
    stop_signal: SIGINT
    environment:
      - JWT_SECRET=${JWT_SECRET}
      - EL_EXTRAS=${EL_EXTRAS:-}
      - ARCHIVE_NODE=${EL_ARCHIVE_NODE:-false}
      - MINIMAL_NODE=${EL_MINIMAL_NODE:-false}
      - AUTOPRUNE_NM=${AUTOPRUNE_NM:-true}
      - NETWORK=${NETWORK}
    volumes:
      - ./data/execution:/var/lib/nethermind
      - /etc/localtime:/etc/localtime:ro
      - ./jwt:/var/lib/nethermind/ee-secret
    ports:
      - ${HOST_IP:-}:${EL_RPC_PORT}:8545/tcp
      - ${HOST_IP:-}:${EL_WS_PORT}:8546/tcp
      - ${HOST_IP:-}:${EE_PORT}:8551/tcp
      - ${HOST_IP:-}:6060:6060/tcp
      - ${HOST_IP:-}:${EL_P2P_PORT}:${EL_P2P_PORT}/tcp
      - ${HOST_IP:-}:${EL_P2P_PORT}:${EL_P2P_PORT}/udp
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    entrypoint:
      - /nethermind/nethermind
      - --config=${NETWORK}
      - --Init.WebSocketsEnabled=true
      - --Network.DiscoveryPort=${EL_P2P_PORT}
      - --Network.P2PPort=${EL_P2P_PORT}
      - --Network.MaxActivePeers=${EL_MAX_PEER_COUNT}
      - --HealthChecks.Enabled=true
      - --HealthChecks.UIEnabled=true
      - --JsonRpc.Enabled=true
      - --JsonRpc.Host=0.0.0.0
      - --JsonRpc.Port=8545
      - --JsonRpc.WebSocketsPort=8546
      - --JsonRpc.EngineHost=0.0.0.0
      - --JsonRpc.EnginePort=8551
      - --JsonRpc.AdditionalRpcUrls=http://127.0.0.1:1337|http|admin
      - --JsonRpc.JwtSecretFile=/var/lib/nethermind/ee-secret/jwtsecret
      - --Metrics.Enabled=true
      - --Metrics.ExposeHost=0.0.0.0
      - --Metrics.ExposePort=6060
      - --Pruning.FullPruningCompletionBehavior=AlwaysShutdown
      - --log=INFO
      - --datadir=/var/lib/nethermind
    labels:
      - prometheus.scrape=true
      - prometheus.job=nethermind
      - prometheus.port=6060
      - prometheus.path=/metrics
      - ethereum.client=nethermind
      - ethereum.layer=execution
      - ethereum.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

# Generate MEV-boost template
generate_mevboost_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/mevboost.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  mevboost:
    container_name: ${NODE_NAME}-mevboost
    restart: "unless-stopped"
    image: flashbots/mev-boost:${MEVBOOST_VERSION}
    pull_policy: always
    user: "${NODE_UID}:${NODE_GID}"
    stop_grace_period: 1m
    environment:
      - NETWORK=${NETWORK}
    ports:
      - ${HOST_IP:-}:${MEVBOOST_PORT}:${MEVBOOST_PORT}/tcp
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    entrypoint:
      - /app/mev-boost
      - -${NETWORK}
      - -addr=0.0.0.0:${MEVBOOST_PORT}
      - -relay-check
      - -relays=${MEVBOOST_RELAY}
    labels:
      - prometheus.scrape=false
      - prometheus.instance=mevboost
      - prometheus.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

# Generate Lodestar consensus client template
generate_lodestar_cl_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/lodestar-cl-only.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  consensus:
    container_name: ${NODE_NAME}-lodestar
    image: chainsafe/lodestar:${LODESTAR_VERSION}
    restart: unless-stopped
    stop_grace_period: 1m
    stop_signal: SIGTERM
    user: "${NODE_UID}:${NODE_GID}"
    environment:
      - NODE_OPTIONS=--max-old-space-size=${LODESTAR_HEAP_MB}
    ports:
      - "${HOST_IP:-}:${CL_REST_PORT}:5052"
      - "${HOST_IP:-}:8008:8008"
      - "${HOST_IP:-}:${CL_P2P_PORT}:${CL_P2P_PORT}/tcp"
      - "${HOST_IP:-}:${CL_P2P_PORT}:${CL_P2P_PORT}/udp"
    volumes:
      - ./data/consensus:/opt/lodestar/data
      - ./jwt:/opt/lodestar/jwt:ro
      - /etc/localtime:/etc/localtime:ro
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    command:
      - "beacon"
      - "--network"
      - "${NETWORK}"
      - "--dataDir"
      - "/opt/lodestar/data"
      - "--rest.address"
      - "0.0.0.0"
      - "--rest.port"
      - "5052"
      - "--port"
      - "${CL_P2P_PORT}"
      - "--execution.urls"
      - "http://execution:8551"
      - "--jwt-secret"
      - "/opt/lodestar/jwt/jwtsecret"
      - "--metrics"
      - "true"
      - "--metrics.address"
      - "0.0.0.0"
      - "--metrics.port"
      - "8008"
      - "--checkpointSyncUrl"
      - "${CHECKPOINT_SYNC_URL}"
      - "--forceCheckpointSync"
    labels:
      - prometheus.scrape=true
      - prometheus.job=lodestar
      - prometheus.port=8008
      - prometheus.path=/metrics
      - ethereum.client=lodestar
      - ethereum.layer=consensus
      - ethereum.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

# Generate Teku consensus client template
generate_teku_cl_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/teku-cl-only.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  consensus:
    container_name: ${NODE_NAME}-teku
    restart: "unless-stopped"
    image: consensys/teku:${TEKU_VERSION}
    pull_policy: always
    user: "${NODE_UID}:${NODE_GID}"
    stop_grace_period: 1m
    volumes:
      - ./data/consensus:/var/lib/teku
      - /etc/localtime:/etc/localtime:ro
      - ./jwt:/var/lib/teku/ee-secret
    environment:
      - JAVA_OPTS=${TEKU_HEAP:--Xmx7g}
      - CHECKPOINT_SYNC_URL=${CHECKPOINT_SYNC_URL}
      - MEV_BOOST=${MEV_BOOST}
      - MEV_NODE=${MEV_NODE}
      - CL_EXTRAS=${CL_EXTRAS:-}
      - ARCHIVE_NODE=${CL_ARCHIVE_NODE:-false}
      - NETWORK=${NETWORK}
      - IPV6=${IPV6:-false}
    ports:
      - ${HOST_IP:-}:${CL_REST_PORT}:5052
      - ${HOST_IP:-}:8008:8008
      - ${HOST_IP:-}:${CL_P2P_PORT}:${CL_P2P_PORT}/tcp
      - ${HOST_IP:-}:${CL_P2P_PORT}:${CL_P2P_PORT}/udp
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    entrypoint:
      - /opt/teku/bin/teku
      - --data-path=/var/lib/teku
      - --log-destination=CONSOLE
      - --network=${NETWORK}
      - --ee-endpoint=${EL_NODE}
      - --ee-jwt-secret-file=/var/lib/teku/ee-secret/jwtsecret
      - --eth1-deposit-contract-max-request-size=1000
      - --p2p-port=${CL_P2P_PORT}
      - --p2p-peer-upper-bound=${CL_MAX_PEER_COUNT}
      - --p2p-peer-lower-bound=${CL_MIN_PEER_COUNT}
      - --logging=INFO
      - --rest-api-host-allowlist=*
      - --rest-api-enabled=true
      - --rest-api-interface=0.0.0.0
      - --rest-api-port=5052
      - --beacon-liveness-tracking-enabled=true
      - --metrics-enabled=true
      - --metrics-port=8008
      - --metrics-interface=0.0.0.0
      - --metrics-host-allowlist=*
      - --checkpoint-sync-url=${CHECKPOINT_SYNC_URL}
    labels:
      - prometheus.scrape=true
      - prometheus.job=teku
      - prometheus.port=8008
      - prometheus.path=/metrics
      - ethereum.client=teku
      - ethereum.layer=consensus
      - ethereum.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

# Generate Grandine consensus client template
generate_grandine_cl_compose() {
    local service_dir="$1"
    
    cat > "${service_dir}/grandine-cl-only.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  consensus:
    container_name: ${NODE_NAME}-grandine
    restart: "unless-stopped"
    image: sifrai/grandine:${GRANDINE_VERSION}
    pull_policy: always
    user: "${NODE_UID}:${NODE_GID}"
    stop_grace_period: 1m
    volumes:
      - ./data/consensus:/var/lib/grandine
      - /etc/localtime:/etc/localtime:ro
      - ./jwt:/var/lib/grandine/ee-secret
    environment:
      - CHECKPOINT_SYNC_URL=${CHECKPOINT_SYNC_URL}
      - MEV_BOOST=${MEV_BOOST}
      - MEV_NODE=${MEV_NODE}
      - CL_EXTRAS=${CL_EXTRAS:-}
      - ARCHIVE_NODE=${CL_ARCHIVE_NODE:-false}
      - CL_MINIMAL_NODE=${CL_MINIMAL_NODE:-true}
      - IPV6=${IPV6:-false}
      - NETWORK=${NETWORK}
    ports:
      - ${HOST_IP:-}:${CL_REST_PORT}:5052
      - ${HOST_IP:-}:8008:8008
      - ${HOST_IP:-}:${CL_P2P_PORT}:${CL_P2P_PORT}/tcp
      - ${HOST_IP:-}:${CL_P2P_PORT}:${CL_P2P_PORT}/udp
      - ${HOST_IP:-}:${CL_QUIC_PORT}:${CL_QUIC_PORT}/udp
    networks:
      - ${NODE_NAME}-net
    <<: *logging
    entrypoint:
      - grandine
      - --disable-upnp
      - --network=${NETWORK}
      - --data-dir=/var/lib/grandine
      - --http-address=0.0.0.0
      - --http-port=5052
      - --http-allowed-origins=*
      - --listen-address=0.0.0.0
      - --libp2p-port=${CL_P2P_PORT}
      - --discovery-port=${CL_P2P_PORT}
      - --quic-port=${CL_QUIC_PORT}
      - --target-peers=${CL_MAX_PEER_COUNT}
      - --eth1-rpc-urls=http://execution:8551
      - --jwt-secret=/var/lib/grandine/ee-secret/jwtsecret
      - --metrics
      - --metrics-address=0.0.0.0
      - --metrics-port=8008
      - --track-liveness
      - --checkpoint-sync-url=${CHECKPOINT_SYNC_URL}
    labels:
      - prometheus.scrape=true
      - prometheus.job=grandine
      - prometheus.port=8008
      - prometheus.path=/metrics
      - ethereum.client=grandine
      - ethereum.layer=consensus
      - ethereum.network=${NETWORK}

networks:
  ${NODE_NAME}-net:
    name: ${NODE_NAME}-net
    external: true
EOF
}

#=============================================================================
# TEKU VALIDATOR TEMPLATES
#=============================================================================

# Generate Teku Validator .env file
generate_teku_validator_env() {
    local service_dir="$1"
    local node_uid="$2"
    local node_gid="$3"
    local network="$4"
    local beacon_url="$5"
    local web3signer_port="$6"
    local fee_recipient="$7"
    local graffiti="$8"
    local selected_ethnode="$9"
    
    cat > "${service_dir}/.env" <<EOF
#=============================================================================
# TEKU VALIDATOR STACK CONFIGURATION
#=============================================================================
# Docker network name for container communication
TEKU_VALIDATOR_NETWORK=validator-net

# User mapping (auto-detected)
TEKU_UID=${node_uid}
TEKU_GID=${node_gid}

#=============================================================================
# API PORT BINDING
#=============================================================================
HOST_BIND_IP=127.0.0.1

#=============================================================================
# NODE CONFIGURATION
#=============================================================================
# Ethereum network (mainnet, sepolia, hoodi, or custom URL)
ETH2_NETWORK=${network}

# Beacon node configuration
BEACON_NODE_URL=${beacon_url}

# Web3signer connection (dynamically determined from web3signer installation)
WEB3SIGNER_PORT=${web3signer_port}
WEB3SIGNER_URL=http://web3signer:\${WEB3SIGNER_PORT}

#=============================================================================
# VALIDATOR CONFIGURATION
#=============================================================================
# Validator performance and behavior settings
FEE_RECIPIENT=${fee_recipient}
GRAFFITI=${graffiti}

#=============================================================================
# SERVICE CONFIGURATION
#=============================================================================
# Teku validator client
TEKU_VERSION=25.9.2
LOG_LEVEL=info
JAVA_OPTS=-Xmx2g

# Selected ethnode for network connection
SELECTED_ETHNODE=${selected_ethnode}
EOF
}

# Generate Teku Validator compose.yml file
generate_teku_validator_compose() {
    local service_dir="$1"
    local selected_ethnode="${2:-ethnode1}"  # Default to ethnode1 if not provided
    
    cat > "${service_dir}/compose.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  teku-validator:
    image: consensys/teku:${TEKU_VERSION}
    container_name: teku-validator
    restart: unless-stopped
    user: "${TEKU_UID}:${TEKU_GID}"
    environment:
      - JAVA_OPTS=${JAVA_OPTS}
      - LOG_LEVEL=${LOG_LEVEL}
    volumes:
      - ./data:/data
    command: [
      "validator-client",
      "--network=${ETH2_NETWORK}",
      "--beacon-node-api-endpoint=${BEACON_NODE_URL}",
      "--validators-external-signer-url=${WEB3SIGNER_URL}",
      "--validators-external-signer-public-keys=external-signer",
      "--validators-proposer-default-fee-recipient=${FEE_RECIPIENT}",
      "--validators-graffiti=${GRAFFITI}",
      "--logging=${LOG_LEVEL}",
      "--log-destination=CONSOLE",
      "--metrics-enabled=true",
      "--metrics-port=8008",
      "--metrics-interface=0.0.0.0",
      "--metrics-host-allowlist=*",
      "--doppelganger-detection-enabled=true",
      "--shut-down-when-validator-slashed-enabled=true"
    ]
    networks:
      - validator-net
      - web3signer-net
      - ETHNODE_PLACEHOLDER-net
    <<: *logging

networks:
  validator-net:
    external: true
    name: validator-net
  web3signer-net:
    external: true
    name: web3signer-net
  ETHNODE_PLACEHOLDER-net:
    external: true
    name: ETHNODE_PLACEHOLDER-net
EOF

    # Replace the placeholder with the actual ethnode name
    sed -i "s/ETHNODE_PLACEHOLDER/${selected_ethnode}/g" "${service_dir}/compose.yml"
}

#=============================================================================
# MONITORING STACK TEMPLATES
#=============================================================================

# Generate Monitoring .env file
generate_monitoring_env() {
    local service_dir="$1"
    local node_uid="$2"
    local node_gid="$3"
    local prometheus_port="$4"
    local grafana_port="$5"
    local node_exporter_port="$6"
    local grafana_password="$7"
    local bind_ip="$8"
    shift 8
    local selected_networks=("$@")
    
    cat > "${service_dir}/.env" <<EOF
#============================================================================
# MONITORING CONFIGURATION
# Generated: $(date)
#============================================================================
COMPOSE_FILE=compose.yml
MONITORING_NAME=monitoring
NODE_UID=${node_uid}
NODE_GID=${node_gid}

# Monitoring Ports
PROMETHEUS_PORT=${prometheus_port}
GRAFANA_PORT=${grafana_port}
NODE_EXPORTER_PORT=${node_exporter_port}

# Grafana Configuration
GRAFANA_PASSWORD=${grafana_password}

# Monitoring Versions
PROMETHEUS_VERSION=v3.5.0
GRAFANA_VERSION=12.1.0
NODE_EXPORTER_VERSION=v1.9.1

# Network Access
BIND_IP=${bind_ip}

# Connected Networks
MONITORED_NETWORKS="${selected_networks[*]}"
EOF
}

# Generate Monitoring compose.yml file (part 1 - base structure)
generate_monitoring_compose_base() {
    local service_dir="$1"
    
    cat > "${service_dir}/compose.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: ${MONITORING_NAME}-prometheus
    restart: unless-stopped
    user: "65534:65534"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    ports:
      - "${BIND_IP}:${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
EOF
}

# Append networks to compose file
append_monitoring_networks() {
    local service_dir="$1"
    shift
    local networks=("$@")
    
    for network in "${networks[@]}"; do
        echo "      - $network" >> "${service_dir}/compose.yml"
    done
}

# Generate Monitoring compose.yml file (part 2 - grafana section)
generate_monitoring_compose_grafana() {
    local service_dir="$1"
    
    cat >> "${service_dir}/compose.yml" <<'EOF'
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: ${MONITORING_NAME}-grafana
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${BIND_IP}:${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
    networks:
EOF
}

# Generate Monitoring compose.yml file (part 3 - node-exporter section)
generate_monitoring_compose_node_exporter() {
    local service_dir="$1"
    
    cat >> "${service_dir}/compose.yml" <<'EOF'
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: ${MONITORING_NAME}-node-exporter
    restart: unless-stopped
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
    ports:
      - "127.0.0.1:${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
EOF
}

# Generate Monitoring compose.yml file (part 4 - volumes and networks)
generate_monitoring_compose_footer() {
    local service_dir="$1"
    shift
    local networks=("$@")
    
    cat >> "${service_dir}/compose.yml" <<'EOF'
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: ${MONITORING_NAME}_prometheus_data
  grafana_data:
    name: ${MONITORING_NAME}_grafana_data

networks:
EOF

    # Add network definitions
    for network in "${networks[@]}"; do
        cat >> "${service_dir}/compose.yml" <<EOF
  ${network}:
    external: true
    name: ${network}
EOF
    done
}

# Generate Prometheus config file
generate_prometheus_config() {
    local service_dir="$1"
    
    cat > "${service_dir}/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
}

# Generate Grafana datasource provisioning
generate_grafana_datasource_config() {
    local service_dir="$1"
    
    cat > "${service_dir}/grafana/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1

datasources:
  - name: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
}

# Generate Grafana dashboard provisioning
generate_grafana_dashboard_config() {
    local service_dir="$1"
    
    cat > "${service_dir}/grafana/provisioning/dashboards/dashboards.yml" <<EOF
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
EOF
}

#=============================================================================
# ETHNODE BASE COMPOSE TEMPLATE
#=============================================================================

# Generate base ethnode compose.yml with logging and network configuration
generate_ethnode_base_compose() {
    local node_dir="$1"
    local node_name="$2"
    
    cat > "${node_dir}/compose.yml" <<EOF
x-logging: &logging
 logging:
   driver: json-file
   options:
     max-size: 100m
     max-file: "3"
     tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

networks:
  default:
    external: true
    name: ${node_name}-net
    enable_ipv6: \${IPV6:-false}
EOF
}

#=============================================================================
# COMPLETE MONITORING STACK GENERATION
#=============================================================================

# Generate complete monitoring stack (env + compose + configs)
# This replicates the complex logic from monitoring-lifecycle.sh using centralized templates
generate_complete_monitoring_stack() {
    local staging_dir="$1"
    local node_uid="$2"
    local node_gid="$3"
    local prometheus_port="$4"
    local grafana_port="$5"
    local node_exporter_port="$6"
    local grafana_password="$7"
    local bind_ip="$8"
    shift 8
    local selected_networks=("$@")
    
    # Create directory structure
    mkdir -p "$staging_dir/grafana/provisioning/datasources"
    mkdir -p "$staging_dir/grafana/provisioning/dashboards"
    mkdir -p "$staging_dir/grafana/dashboards"
    
    # Generate .env file
    generate_monitoring_env "$staging_dir" "$node_uid" "$node_gid" "$prometheus_port" "$grafana_port" "$node_exporter_port" "$grafana_password" "$bind_ip" "${selected_networks[@]}"
    
    # Generate monitoring networks (only include monitoring-net, validator-net, and ethnode networks)
    local monitoring_networks=("monitoring-net" "validator-net")
    for network in "${selected_networks[@]}"; do
        if [[ "$network" =~ ^ethnode.*-net$ ]]; then
            monitoring_networks+=("$network")
        fi
    done
    
    # Remove duplicates
    local unique_networks=($(printf '%s\n' "${monitoring_networks[@]}" | sort -u))
    
    # Generate compose file in parts
    generate_monitoring_compose_base "$staging_dir"
    append_monitoring_networks "$staging_dir" "${unique_networks[@]}"
    generate_monitoring_compose_grafana "$staging_dir"
    append_monitoring_networks "$staging_dir" "${unique_networks[@]}"
    generate_monitoring_compose_node_exporter "$staging_dir"
    append_monitoring_networks "$staging_dir" "${unique_networks[@]}"
    generate_monitoring_compose_footer "$staging_dir" "${unique_networks[@]}"
    
    # Generate config files
    generate_prometheus_config "$staging_dir"
    generate_grafana_datasource_config "$staging_dir"
    generate_grafana_dashboard_config "$staging_dir"
}