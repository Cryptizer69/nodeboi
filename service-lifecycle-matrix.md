# NODEBOI Universal Service Lifecycle Action Matrix

This document provides a comprehensive overview of all lifecycle actions for each service type in the Universal Service Lifecycle Management System.

## Service Types and Their Lifecycle Actions

### 1. ETHNODE Services (`ethnode1`, `ethnode2`, `ethnode3`, etc.)

**Service Flow Definition:**
```json
{
    "type": "ethnode",
    "resources": {
        "containers": ["${service_name}-*"],
        "volumes": ["${service_name}_*", "${service_name}-*"], 
        "networks": ["${service_name}-net"],
        "directories": ["$HOME/${service_name}"],
        "integrations": ["monitoring", "validators"]
    },
    "dependencies": [],
    "dependents": ["validators"]
}
```

**REMOVE Lifecycle Actions:**
1. **stop_services** - Stop all ethnode containers via `docker compose down`
2. **update_dependents** - Remove beacon endpoints from validator configurations (vero, teku-validator)
3. **cleanup_integrations** - Complete monitoring cleanup:
   - Remove Prometheus scrape targets from prometheus.yml
   - Rebuild prometheus.yml configuration 
   - Remove Grafana dashboards via API
   - Restart monitoring stack (compose down/up)
4. **remove_containers** - Remove all containers matching `${ethnode_name}-*` pattern
5. **remove_volumes** - Remove all volumes matching `${ethnode_name}_*` and `${ethnode_name}-*` patterns
6. **remove_networks** - Remove isolated `${ethnode_name}-net` network
7. **remove_directories** - Remove `$HOME/${ethnode_name}` directory
8. **unregister** - Remove from service registry

**INSTALL Lifecycle Actions:**
1. **create_directories** - Create `$HOME/${service_name}` directory structure
2. **copy_configs** - Copy ethnode-specific configuration files
3. **setup_networking** - Create isolated `${service_name}-net` network
4. **start_services** - Start ethnode containers via `docker compose up -d`
5. **integrate** - Add to monitoring (update prometheus.yml, add dashboards)

**START Lifecycle Actions:**
1. **ensure_networks** - Verify `${service_name}-net` exists
2. **start_services** - Start containers via `docker compose up -d`
3. **health_check** - Verify containers are running and healthy

**STOP Lifecycle Actions:**
1. **stop_services** - Stop containers via `docker compose down`
2. **disconnect_networks** - Clean disconnection from networks

**UPDATE Lifecycle Actions:**
1. **pull_images** - Pull latest container images
2. **recreate_services** - Recreate containers with new images
3. **health_check** - Verify updated services are healthy

---

### 2. VALIDATOR Services (`vero`, `teku-validator`)

**Service Flow Definition:**
```json
{
    "type": "validator",
    "resources": {
        "containers": ["${service_name}*"],
        "volumes": ["${service_name}_*", "${service_name}-*"],
        "networks": ["validator-net"],
        "directories": ["$HOME/${service_name}"],
        "integrations": ["monitoring", "ethnodes", "web3signer"]
    },
    "dependencies": ["ethnodes"],
    "dependents": []
}
```

**REMOVE Lifecycle Actions:**
1. **stop_services** - Stop validator containers via `docker compose down`
2. **update_dependents** - No dependents to update (validators are leaf services)
3. **cleanup_integrations** - Complete integration cleanup:
   - Remove validator-specific Grafana dashboards
   - Remove validator metrics from monitoring
   - Clean up web3signer references
4. **remove_containers** - Remove all containers matching `${validator_name}*` pattern
5. **remove_volumes** - Remove all volumes matching `${validator_name}_*` and `${validator_name}-*` patterns
6. **cleanup_shared_networks** - Intelligently clean up `validator-net` (only if no other validators remain)
7. **remove_directories** - Remove `$HOME/${validator_name}` directory
8. **unregister** - Remove from service registry

**INSTALL Lifecycle Actions:**
1. **create_directories** - Create validator directory structure
2. **copy_configs** - Copy validator-specific configurations
3. **setup_networking** - Ensure `validator-net` exists (shared network)
4. **connect_to_ethnodes** - Discover and connect to available ethnode beacon endpoints
5. **start_services** - Start validator containers
6. **integrate** - Add to monitoring and web3signer integration

---

### 3. WEB3SIGNER Service (`web3signer`)

**Service Flow Definition:**
```json
{
    "type": "web3signer",
    "resources": {
        "containers": ["web3signer*"],
        "volumes": ["web3signer_*", "web3signer-*"],
        "networks": ["web3signer-net"],
        "directories": ["$HOME/web3signer"],
        "integrations": ["monitoring", "validators"]
    },
    "dependencies": [],
    "dependents": ["validators"]
}
```

**REMOVE Lifecycle Actions:**
1. **stop_services** - Stop web3signer and PostgreSQL containers
2. **update_dependents** - Update validator configurations to remove web3signer references
3. **cleanup_integrations** - Complete integration cleanup:
   - Clean up validator signing configurations (no monitoring dashboards to remove)
4. **remove_containers** - Remove web3signer, postgres, flyway containers
5. **remove_volumes** - Remove database and keystore volumes
6. **remove_networks** - Remove `web3signer-net` network
7. **remove_directories** - Remove `$HOME/web3signer` directory
8. **unregister** - Remove from service registry

**INSTALL Lifecycle Actions:**
1. **create_directories** - Create web3signer directory structure
2. **copy_configs** - Copy web3signer and database configurations
3. **setup_networking** - Create `web3signer-net` network
4. **setup_database** - Initialize PostgreSQL database and run migrations
5. **start_services** - Start web3signer stack

---

### 4. MONITORING Service (`monitoring`)

**Service Flow Definition:**
```json
{
    "type": "monitoring",
    "resources": {
        "containers": ["monitoring-*"],
        "volumes": ["monitoring_*", "monitoring-*"],
        "networks": ["monitoring-net"],
        "directories": ["$HOME/monitoring"],
        "files": ["$HOME/monitoring/prometheus.yml", "$HOME/monitoring/grafana/dashboards/*"],
        "integrations": []
    },
    "dependencies": [],
    "dependents": ["ethnodes", "validators", "web3signer"]
}
```

**REMOVE Lifecycle Actions:**
1. **stop_services** - Stop Prometheus, Grafana, Node Exporter containers
2. **update_dependents** - No specific dependent updates (other services lose monitoring)
3. **cleanup_integrations** - No specific integration cleanup for monitoring removal
4. **remove_containers** - Remove all monitoring-related containers
5. **remove_volumes** - Remove Prometheus data and Grafana volumes
6. **remove_networks** - Remove `monitoring-net` network
7. **remove_directories** - Remove `$HOME/monitoring` directory
8. **unregister** - Remove from service registry

**INSTALL Lifecycle Actions:**
1. **create_directories** - Create monitoring directory structure
2. **copy_configs** - Copy Prometheus, Grafana configurations
3. **setup_networking** - Create `monitoring-net` network
4. **setup_grafana_dashboards** - Install default dashboards for existing services
5. **start_services** - Start monitoring stack
6. **integrate** - Auto-discover and integrate with existing services

---

## Cross-Service Integration Actions

### Monitoring Integration Actions

**For Ethnode Services:**
- **Add Integration**: Update prometheus.yml with scrape targets, add execution/consensus dashboards
- **Remove Integration**: Remove scrape targets, rebuild prometheus.yml, remove dashboards, restart monitoring

**For Validator Services:**
- **Add Integration**: Add validator performance dashboards, validator metrics scraping
- **Remove Integration**: Remove validator dashboards, clean up validator metrics

**For Web3signer Service:**
- **Add Integration**: Configure validator integration for remote signing (no monitoring integration)
- **Remove Integration**: Update dependent validator configurations (no monitoring to remove)

### Network Management Actions

**Isolated Networks** (per-ethnode):
- **Create**: `docker network create ${ethnode_name}-net`
- **Remove**: `docker network rm ${ethnode_name}-net` (always safe to remove)

**Shared Networks**:
- **validator-net**: Only removed when NO validator services remain
- **web3signer-net**: Removed with web3signer service
- **monitoring-net**: Removed with monitoring service

### Configuration Management Actions

**Prometheus Configuration:**
- **Rebuild**: Scan running services, generate new prometheus.yml, restart Prometheus
- **Add Targets**: Add scrape jobs for new services
- **Remove Targets**: Remove scrape jobs, rebuild config

**Validator Beacon Endpoint Management:**
- **Add Endpoints**: Update validator configs with new ethnode beacon URLs
- **Remove Endpoints**: Remove defunct beacon URLs from validator configs, restart validators

**Web3signer Integration:**
- **Add Validator**: Configure validator to use web3signer for remote signing
- **Remove Validator**: Update web3signer to stop serving removed validator

---

## Service Dependencies and Impact Matrix

| Service Removed | Impacts | Actions Taken |
|----------------|---------|---------------|
| **Ethnode** | Validators lose beacon node | Update validator beacon endpoints, remove from monitoring |
| **Validator** | None (leaf service) | Clean up monitoring, remove from web3signer config |
| **Web3signer** | Validators lose remote signing | Update validators to use local keys or stop |
| **Monitoring** | All services lose observability | No dependent service updates needed |

---

## Error Handling and Recovery

### Critical vs Non-Critical Failures

**Critical Failures** (abort lifecycle):
- Container removal failures
- Directory removal failures  
- Network removal failures (when in use)

**Non-Critical Failures** (continue lifecycle):
- Integration cleanup failures
- Monitoring restart failures
- Service registry update failures
- Dashboard removal failures

### Rollback Capabilities

**Configuration Rollback**:
- Prometheus config backups created before changes
- Service registry maintains history
- Docker compose configs preserved until confirmed removal

**Partial Failure Recovery**:
- Individual lifecycle steps can be retried
- Service state is tracked throughout process
- Cleanup can be resumed from last successful step

---

## Testing and Validation

### Validation Points

**Pre-Removal Validation**:
- Service exists and is registered
- User confirmation with service-specific warnings
- Dependency impact assessment

**During Removal Validation**:
- Each step reports success/failure
- Progress tracking with clear feedback
- Graceful handling of missing resources

**Post-Removal Validation**:
- Verify all resources removed
- Confirm dependent services updated
- Validate monitoring configuration rebuilt

### Health Checks

**Service Health Verification**:
- Container status checks
- Network connectivity validation
- Configuration consistency checks
- Integration status verification

This comprehensive matrix ensures complete lifecycle management for all NODEBOI services with proper integration cleanup, dependency management, and error handling.