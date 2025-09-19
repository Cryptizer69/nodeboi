# NODEBOI Technical Documentation

## Architecture

### Universal Service Lifecycle Management System

NODEBOI implements a comprehensive Universal Service Lifecycle Management System that provides unified flows for all service operations. This system ensures consistent, complete cleanup and management across all service types.

#### Core Components

**1. Universal Service Lifecycle Framework** (`lib/universal-service-lifecycle.sh`)
- **Service Flow Definitions**: JSON-based definitions for each service type (ethnode, validator, monitoring, web3signer)
- **Unified Orchestration**: Single interface for install/remove/start/stop/update operations
- **Cross-Service Integration**: Automatic management of dependencies and integrations between services

**2. Service Operations Engine** (`lib/service-operations.sh`)
- **Resource Management**: Handles containers, volumes, networks, and filesystem operations
- **Integration Cleanup**: Manages monitoring integration, validator configurations, and cross-service dependencies  
- **Progress Tracking**: Provides detailed feedback and error handling for all operations

**3. Service Management CLI** (`lib/service-manager.sh`)
- **Command-Line Interface**: Easy-to-use CLI for all service operations
- **Dry-Run Capabilities**: Preview changes before execution with `plan` command
- **Interactive and Non-Interactive Modes**: Flexible operation modes for different use cases

**4. Service Registry** (`lib/service-registry.sh`)
- **Service Tracking**: Maintains registry of all installed services with metadata
- **Status Management**: Tracks service states and provides comprehensive status information
- **Integration Point**: Central source of truth for all service lifecycle operations

#### Service Flow Definitions

Each service type has a defined flow that specifies:

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
    "dependents": ["validators"],
    "lifecycle": {
        "remove": [
            "stop_services",
            "update_dependents", 
            "cleanup_integrations",
            "remove_containers",
            "remove_volumes",
            "remove_networks",
            "remove_directories",
            "unregister"
        ]
    }
}
```

#### Supported Service Types

**Ethnode Services** (`ethnode1`, `ethnode2`, etc.)
- **Resources**: Isolated Docker containers, networks (`ethnode-net`), data directories
- **Integrations**: Monitoring (Prometheus scraping, Grafana dashboards), validator beacon endpoints
- **Dependencies**: None
- **Dependents**: Validators that use this ethnode as a beacon node

**Validator Services** (`vero`, `teku-validator`)
- **Resources**: Validator containers, shared validator network, validator data directories
- **Integrations**: Monitoring dashboards, ethnode beacon endpoints, web3signer configuration
- **Dependencies**: Ethnode services (for beacon nodes)
- **Dependents**: None

**Web3signer Service** (`web3signer`)
- **Resources**: Web3signer containers, PostgreSQL database, dedicated network
- **Integrations**: Validator configurations, monitoring
- **Dependencies**: None  
- **Dependents**: Validators that use remote signing

**Monitoring Service** (`monitoring`)
- **Resources**: Prometheus, Grafana, Node Exporter containers, monitoring network
- **Integrations**: All other services (collects metrics from all)
- **Dependencies**: None
- **Dependents**: All services (provides observability)

#### Lifecycle Operations

**Service Removal Flow**
1. **Stop Services**: Gracefully stop all containers using `docker compose down`
2. **Update Dependents**: Remove references from dependent services (e.g., beacon endpoints from validators)
3. **Cleanup Integrations**: Remove monitoring targets, dashboards, and cross-service configurations
4. **Remove Containers**: Remove all Docker containers matching service patterns
5. **Remove Volumes**: Clean up all Docker volumes associated with the service
6. **Remove Networks**: Remove isolated networks, handling shared network cleanup intelligently
7. **Remove Directories**: Remove filesystem directories and configuration files
8. **Unregister**: Remove service from the service registry

**Integration Management**
- **Monitoring Integration**: Automatically updates Prometheus scrape configurations and removes Grafana dashboards
- **Validator Integration**: Updates beacon node endpoints in validator configurations when ethnodes are removed
- **Network Management**: Handles both isolated networks (per-ethnode) and shared networks (validator-net)
- **Service Registry**: Maintains consistent state tracking across all operations

#### Key Features

**Complete Resource Cleanup**
- All Docker containers (running and stopped) matching service patterns
- All Docker volumes with service-specific naming patterns  
- Docker networks (both isolated and shared, with intelligent cleanup)
- Filesystem directories and configuration files
- Service registry entries and metadata

**Cross-Service Awareness** 
- Automatically updates validator beacon configurations when ethnodes are removed
- Cleans up monitoring integration (Prometheus targets, Grafana dashboards)
- Manages shared resources intelligently (e.g., validator-net only removed when no validators remain)
- Handles service dependencies and dependent relationships

**Progress Tracking and Error Handling**
- Step-by-step progress reporting with clear status indicators
- Graceful error handling with continuation for non-critical failures
- Detailed logging at multiple levels (lifecycle, operations, hooks)
- Rollback capabilities for failed operations

**User Experience**
- Single confirmation prompt with complete context about what will be removed
- Dry-run capabilities to preview changes before execution  
- Interactive and non-interactive operation modes
- Consistent lowercase `[y/n]` confirmation prompts

#### Usage Examples

```bash
# List all managed services
bash lib/service-manager.sh list

# Preview removal plan (dry-run)
bash lib/service-manager.sh plan ethnode2

# Interactive removal with confirmation
bash lib/service-manager.sh remove ethnode2

# Non-interactive removal
bash lib/service-manager.sh remove ethnode2 --non-interactive

# Service status information
bash lib/service-manager.sh status monitoring

# Start/stop services
bash lib/service-manager.sh start ethnode1
bash lib/service-manager.sh stop ethnode1

# Update services  
bash lib/service-manager.sh update ethnode2
```

#### Integration with Main Script

The lifecycle system is integrated into the main `nodeboi.sh` script:

- **Automatic Detection**: The main script automatically detects if the universal system is available
- **Graceful Fallback**: Falls back to legacy removal methods if the universal system is not present
- **Consistent UI**: Provides the same user experience whether using universal or legacy systems
- **Progressive Enhancement**: Existing installations continue to work while gaining new capabilities

This architecture ensures that every service operation follows a consistent, predictable flow with complete cleanup of all resources, proper handling of integrations, and clear feedback to the user.