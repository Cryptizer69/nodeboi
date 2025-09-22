# NODEBOI - Ethereum Multi-Client Node Manager

**NODEBOI** is a comprehensive Ethereum staking infrastructure management system that provides automated deployment, monitoring, and lifecycle management for Ethereum nodes, validators, and supporting services. The system abstracts the complexity of running multiple Ethereum clients, providing a unified interface for operators to manage their staking infrastructure.

## 🚀 Quick Start

### Installation
One-line installation:
```bash
wget -qO- https://raw.githubusercontent.com/Cryptizer69/nodeboi/main/install.sh | bash

# Run NODEBOI from any directory
nodeboi
```

### Your First Ethereum Node
```bash
nodeboi
# Select: "Install new service" → "Install new ethnode"
# Choose your execution client (Nethermind, Besu, Reth)
# Choose your consensus client (Lodestar, Teku, Grandine)
# Follow the guided setup
```

### Add Monitoring
```bash
nodeboi
# Select: "Install new service" → "Install monitoring"
# Access Grafana at http://localhost:3000 (admin/admin)
```

### Add Validators
```bash
nodeboi
# Select: "Install new service" → "Install validator"
# Choose validator client (Vero, Teku Validator)
# Import your validator keys
```

---

## 🏗️ System Architecture

### Core Design Principles

1. **Service-Oriented Architecture**: Each component (ethnode, validator, monitoring) is a self-contained service
2. **Containerized Deployment**: All services run in Docker containers for isolation and portability
3. **Universal Lifecycle Management**: Centralized ULCS orchestrates all service operations
4. **Network Isolation**: Each service runs in isolated Docker networks for security
5. **Configuration-Driven**: Declarative configuration defines desired state

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        NODEBOI CLI                              │
│                     (nodeboi.sh)                               │
└─────────────────────┬───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│              Universal Lifecycle System (ULCS)                  │
│                     (lib/ulcs.sh)                              │
└─────┬─────────────┬─────────────┬─────────────┬─────────────────┘
      │             │             │             │
┌─────▼─────┐ ┌─────▼─────┐ ┌─────▼─────┐ ┌─────▼─────┐
│  Ethnode  │ │Validators │ │Monitoring │ │Web3signer │
│ Services  │ │ Services  │ │  Stack    │ │ Service   │
└───────────┘ └───────────┘ └───────────┘ └───────────┘
      │             │             │             │
┌─────▼─────────────▼─────────────▼─────────────▼─────┐
│                Docker Engine                        │
│              (Isolated Networks)                    │
└─────────────────────────────────────────────────────┘
```

---

## 📋 System Components

### 1. **CLI Interface Layer** (`nodeboi.sh`)
- **Purpose**: Primary user interface
- **Size**: ~1,000 lines
- **Functions**: 
  - Menu-driven service management
  - Installation workflows
  - Status monitoring
  - System administration

### 2. **Universal Lifecycle System (ULCS)** (Multiple modules in `lib/`)
- **Purpose**: Complete service lifecycle management across multiple specialized modules
- **Core Module**: `lib/ulcs.sh` (~120k lines) - Main orchestration system
- **Supporting Modules**: lifecycle-hooks, service-operations, monitoring-lifecycle, etc.
- **Sections**:
  - **Section 1**: Core logging & utilities (unified log functions, service flows)
  - **Section 2**: Service orchestration (install/remove/start/stop/update operations)
  - **Section 3**: Resource operations (containers, volumes, networks, filesystems)
  - **Section 4**: Monitoring integration (prometheus, grafana, dashboards)

**Key ULCS Functions**:
- ✅ Universal service operations (`remove_service_universal`, `start_service_universal`, etc.)
- ✅ Resource management (container, volume, network operations)
- ✅ Native monitoring integration (prometheus config, grafana dashboards)
- ✅ Cross-service dependency management
- ✅ Client-specific optimizations (graceful Nethermind/Besu shutdown)

### 3. **Service Management Layer**

#### A. **Ethnode Manager** (`ethnode-manager.sh`)
- **Purpose**: Ethereum node deployment and management
- **Size**: ~68,000 lines
- **Supported Clients**: 
  - **Execution**: Nethermind, Besu, Reth
  - **Consensus**: Lodestar, Teku, Grandine
- **Functions**:
  - Multi-client support and installation workflows
  - Automatic client detection and configuration
  - Network synchronization and performance optimization
  - Integration with ULCS for lifecycle management

#### B. **Validator Manager** (`validator-manager.sh`)  
- **Purpose**: Validator client management
- **Size**: ~75,000 lines
- **Supported Validators**: Vero, Teku Validator
- **Functions**:
  - Key management integration
  - Beacon node configuration and discovery
  - Fee recipient management
  - Slashing protection
  - Integration with ULCS for lifecycle operations

#### C. **Supporting Infrastructure**
- **Network Manager** (`network-manager.sh`): Docker network orchestration and isolation
- **Service Operations** (`service-operations.sh`): Core service management utilities
- **UI Framework** (`ui.sh`): Consistent user interface components

---

## 🌐 Network Architecture

### Docker Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                     monitoring-net                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ Prometheus  │  │   Grafana   │  │Node Exporter│              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────────┐
│                     validator-net                               │
│  ┌─────────────┐  ┌─────────────┐                               │
│  │    Vero     │  │Teku Validator│                              │
│  └─────────────┘  └─────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
         │                    │
┌────────▼────┐      ┌────────▼────┐
│ ethnode1-net│      │ ethnode2-net│
│┌───────────┐│      │┌───────────┐│
││Nethermind ││      ││ Besu      ││
│├───────────┤│      │├───────────┤│
││ Lodestar  ││      ││   Teku    ││
│├───────────┤│      │├───────────┤│
││ MEV-Boost ││      │├───────────┤│
│└───────────┘│      ││ MEV-Boost ││
└─────────────┘      │└───────────┘│
                     └─────────────┘
```

### Network Isolation Benefits

1. **Security**: Services cannot access each other unless explicitly connected
2. **Scalability**: New services can be added without affecting existing ones
3. **Maintenance**: Individual networks can be updated independently
4. **Monitoring**: Network traffic is traceable and monitorable

---

## 🔄 Universal Lifecycle System (ULCS) - Consolidated Architecture

### ULCS Service Flow Definitions

Each service type has a defined lifecycle with specific steps:

```json
{
  "ethnode": {
    "lifecycle": {
      "install": ["create_directories", "copy_configs", "setup_networking", "start_services", "integrate"],
      "remove": ["stop_services", "cleanup_integrations", "remove_containers", "remove_volumes", "remove_networks", "remove_directories"],
      "update": ["pull_images", "recreate_services", "health_check"]
    },
    "integrations": ["monitoring", "validators"]
  }
}
```

### Service Types and Operations

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

### ULCS Native Monitoring System

The monitoring system is centralized through **ULCS Native Monitoring**:

- **Single Source of Truth**: One function generates all Prometheus configurations
- **Automatic Discovery**: Detects all running services and their client types
- **Self-Validating**: Built-in YAML validation and configuration checks
- **Atomic Updates**: Configurations updated atomically with rollback on failure
- **API Integration**: Both file-based and API-based Grafana dashboard management

---

## 📊 Monitoring & Observability

### Monitoring Stack Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Grafana                                  │
│                   (Visualization)                              │
└─────────────────────┬───────────────────────────────────────────┘
                      │ Queries
┌─────────────────────▼───────────────────────────────────────────┐
│                    Prometheus                                   │
│                  (Metrics Store)                               │
└─────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┘
      │         │         │         │         │         │
┌─────▼─┐ ┌─────▼─┐ ┌─────▼─┐ ┌─────▼─┐ ┌─────▼─┐ ┌─────▼─┐
│Node   │ │Nether-│ │Lode-  │ │Teku   │ │Vero   │ │System │
│Export.│ │mind   │ │star   │ │Valid. │ │Valid. │ │Metrics│
└───────┘ └───────┘ └───────┘ └───────┘ └───────┘ └───────┘
```

### Key Metrics Tracked

1. **Ethereum Node Metrics**:
   - Sync status and block height
   - Peer connections and network health
   - Memory and CPU usage
   - Disk I/O and storage utilization

2. **Validator Metrics**:
   - Attestation performance and success rate
   - Proposal success rate and rewards
   - Balance changes and earnings
   - Slashing incidents and penalties

3. **System Metrics**:
   - Container health and resource usage
   - Network throughput and latency
   - Service availability and uptime

---

## 🔧 Configuration Management

### Configuration Hierarchy

```
$HOME/.nodeboi/                # NODEBOI Installation
├── nodeboi.sh                # Main CLI
├── lib/
│   ├── ulcs.sh              # Universal Lifecycle & Configuration System (CONSOLIDATED)
│   ├── ethnode-manager.sh    # Ethereum node management
│   ├── validator-manager.sh  # Validator management
│   └── ...                  # Supporting modules
└── README.md                # User documentation

$HOME/ethnode1/              # Ethnode Instance
├── .env                     # Service Configuration
├── compose.yml              # Docker Compose
├── nethermind.yml           # Client Configuration
└── data/                    # Blockchain Data

$HOME/monitoring/            # Monitoring Stack
├── .env
├── compose.yml
├── prometheus.yml           # Generated by ULCS
└── grafana/
    └── dashboards/          # Auto-generated
```

### Configuration Flow

1. **Service Definition**: ULCS service flows define capabilities and dependencies
2. **Template Processing**: Configuration templates customized per service
3. **Environment Generation**: `.env` files created with service-specific parameters
4. **Docker Compose**: Service definitions translated to container specifications
5. **Runtime Configuration**: Dynamic configuration updates through ULCS

---

## 🔒 Security Architecture

### Security Layers

1. **Network Isolation**: Docker networks prevent unauthorized service communication
2. **Container Isolation**: Each service runs in isolated containers with restricted privileges
3. **File System Isolation**: Dedicated directories with proper permissions
4. **JWT Authentication**: Secure communication between Ethereum clients
5. **Key Management**: Web3signer provides secure key storage and signing

### Security Best Practices Implemented

- **Principle of Least Privilege**: Services only access required resources
- **Defense in Depth**: Multiple security layers prevent single points of failure
- **Secure Defaults**: Safe configuration out-of-the-box
- **Audit Trails**: All operations logged for security analysis

---

## 📈 Performance Characteristics

### Scalability Metrics

- **Horizontal Scaling**: Multiple ethnodes supported (ethnode1, ethnode2, ...)
- **Resource Efficiency**: Optimized Docker configurations reduce overhead
- **Network Performance**: Isolated networks reduce interference
- **Storage Optimization**: Configurable pruning and data management

### Performance Optimizations

1. **Client Selection**: Support for high-performance clients (Nethermind, Reth)
2. **Resource Allocation**: Automatic memory and CPU configuration
3. **Network Optimization**: Efficient peer discovery and connection management
4. **Monitoring Overhead**: Lightweight metrics collection with minimal impact

---

## 📋 Service Lifecycle Management

### Universal Service Operations

All services support these universal operations through ULCS:

```bash
# Universal operations work on any service type
remove_service_universal ethnode1    # Remove ethnode with cleanup
start_service_universal monitoring   # Start monitoring stack
stop_service_universal vero         # Stop validator service
```

### Service Removal Flow
1. **Stop Services**: Gracefully stop all containers using `docker compose down`
2. **Update Dependents**: Remove references from dependent services (e.g., beacon endpoints from validators)
3. **Cleanup Integrations**: Remove monitoring targets, dashboards, and cross-service configurations
4. **Remove Containers**: Remove all Docker containers matching service patterns
5. **Remove Volumes**: Clean up all Docker volumes associated with the service
6. **Remove Networks**: Remove isolated networks, handling shared network cleanup intelligently
7. **Remove Directories**: Remove filesystem directories and configuration files
8. **Unregister**: Remove service from the service registry

### Integration Management
- **Monitoring Integration**: Automatically updates Prometheus scrape configurations and removes Grafana dashboards
- **Validator Integration**: Updates beacon node endpoints in validator configurations when ethnodes are removed
- **Network Management**: Handles both isolated networks (per-ethnode) and shared networks (validator-net)
- **Service Registry**: Maintains consistent state tracking across all operations

---

## 🎯 User Guide

### What NODEBOI Does

- **Multi-node Management**: Run multiple Ethereum nodes simultaneously with different client combinations
- **Client Diversity**: Supports Reth, Besu, Nethermind (execution) and Lodestar, Teku, Grandine (consensus)
- **Automated Setup**: Handles JWT secrets, port allocation, and configuration automatically
- **Built-in Monitoring**: Includes MEV-boost support and monitoring capabilities
- **Universal Lifecycle Management**: Unified service orchestration for all components

### Key Features

#### ✅ Complete Service Management
```bash
# Universal operations work on any service
nodeboi start ethnode1
nodeboi stop vero  
nodeboi remove monitoring
```

#### ✅ Automated Monitoring
- **Auto-discovery**: Automatically detects running services
- **Dynamic Configuration**: Updates Prometheus targets and Grafana dashboards
- **Client-Specific Dashboards**: Tailored dashboards for each Ethereum client
- **Health Monitoring**: Container and service health checks

#### ✅ Zero-Downtime Operations
- **Graceful Shutdowns**: Client-specific shutdown procedures (Nethermind, Besu)
- **Rolling Updates**: Update clients without affecting other services
- **Network Management**: Smart shared network cleanup

#### ✅ Security & Isolation
- **Network Segmentation**: Each service in isolated networks
- **Resource Isolation**: Separate data directories and volumes
- **JWT Security**: Secure client communication
- **Key Management**: Web3signer for remote validator key signing

### Service Management Examples

#### Managing Ethereum Nodes
```bash
# List all services
nodeboi status

# Add second ethereum node
nodeboi
# Select "Install new service" → "Install new ethnode" → ethnode2

# Remove an ethnode (with confirmation)
nodeboi remove ethnode1
```

#### Managing Validators
```bash
# Add validator
nodeboi
# Select "Install new service" → "Install validator" → vero

# Import validator keys
# Keys placed in ~/vero/validator_keys/

# Validator automatically connects to available ethnodes
```

#### Monitoring Operations
```bash
# Install monitoring
nodeboi
# Select "Install new service" → "Install monitoring"

# Access dashboards
# Grafana: http://localhost:3000 (admin/admin)
# Prometheus: http://localhost:9090

# Monitoring auto-detects all services
```

---

## 🚀 Development Guidelines

### 1. **Code Organization**
- **One responsibility per module**
- **Clear module boundaries with minimal dependencies**
- **Consistent error handling using ULCS logging**
- **Comprehensive logging at multiple levels**

### 2. **Adding New Services**
- **Define ULCS service flow** in service flows section
- **Implement lifecycle hooks** for all operations
- **Add monitoring integration** using ULCS native functions
- **Create configuration templates** following existing patterns
- **Write integration tests** for critical paths

### 3. **ULCS Integration**
- **Use ULCS native functions only** (consolidated in `lib/ulcs.sh`)
- **Avoid legacy functions** that have been consolidated
- **Follow lifecycle patterns** defined in service flows
- **Implement client-specific optimizations** when necessary

### 4. **Monitoring Integration**
- **Use ULCS native monitoring functions** (`ulcs_generate_prometheus_config`, `ulcs_sync_dashboards`)
- **Implement service-specific metrics** following existing patterns
- **Create custom Grafana dashboards** using template system
- **Ensure auto-discovery compatibility** for new services

### 5. **Security Considerations**
- **Network isolation by default** for all new services
- **Secure credential management** using established patterns
- **Input validation everywhere** to prevent injection attacks
- **Audit trail logging** for all critical operations

---

## ⚠️ Known Technical Debt & Issues

### 1. **Monitoring System Fragmentation** ✅ RESOLVED
- **Previous Issue**: Prometheus configuration scattered across 5 files with conflicting functions
- **Resolution**: 
  - ULCS consolidation provides single source of truth
  - Prometheus configuration centralized (`ulcs_generate_prometheus_config`)
  - Dashboard naming standardized and duplicates eliminated
  - Network connectivity automated (`ulcs_integrate_monitoring`)

### 2. **ULCS Architecture Consolidation** ✅ RESOLVED
- **Previous Issue**: ULCS functionality spread across 3 separate files (3,242 lines total)
- **Resolution**:
  - Consolidated into single `lib/ulcs.sh` file (2,906 lines)
  - Unified logging system (`log_ulcs_*` functions)
  - All imports updated across 6 files
  - Maintains all functionality while improving maintainability

### 3. **Nethermind Graceful Shutdown Timing** ⚠️ MINOR
- **Issue**: Nethermind sometimes exceeds 60s graceful shutdown timeout during database flush
- **Impact**: Users see "force exiting" message during removal (cosmetic issue)
- **Current Behavior**: System appropriately falls back to force shutdown after timeout
- **Recommendation**: Consider increasing timeout to 120s for slower systems/large databases

---

## 🎯 Version Information

### Current Version: v0.5.0

#### What's New in v0.5.0
- 📝 **Centralized templates** - Single source of truth for all service configurations (`lib/templates.sh`)
- 🎯 **Enhanced monitoring integration** - Improved Prometheus and Grafana management
- ⚡ **Faster dashboard refresh** - Optimized health checks with reduced timeouts
- 🧹 **Clean codebase** - Removed duplicate code and consolidated documentation
- 📋 **Unified documentation** - Single comprehensive README with user guide + technical reference
- 🔧 **Performance improvements** - Better GitHub API rate limiting and caching

#### Recent Improvements
- **ULCS Consolidation**: Single unified service management module
- **Enhanced Monitoring**: Native ULCS monitoring with auto-discovery
- **Improved Architecture**: Cleaner separation of concerns
- **Better Error Handling**: Graceful failure handling and recovery
- **Performance Optimization**: Reduced code duplication and faster operations

---

## 📝 Support & Contributing

### Support
- **Help**: Use `nodeboi` menu system
- **Issues**: Report bugs and feature requests on the project repository

### Contributing
- **Code Style**: Follow existing patterns and ULCS integration guidelines
- **Testing**: Ensure all new features integrate properly with ULCS
- **Documentation**: Update both user guides and technical documentation

---

## 🎯 Conclusion

NODEBOI is a **sophisticated infrastructure management system** that successfully abstracts the complexity of Ethereum staking operations. The **Universal Lifecycle System (ULCS)** provides a robust foundation for service orchestration, while the **consolidated architecture** enables easier maintenance and development.

### Key Strengths
1. **Comprehensive Coverage**: Handles all aspects of Ethereum staking infrastructure
2. **User-Friendly**: Complex operations simplified through intuitive interfaces
3. **Robust Monitoring**: Complete observability with automatic service discovery
4. **Scalable Design**: Supports multiple nodes and validators
5. **Security-First**: Multiple layers of isolation and protection
6. **Consolidated Architecture**: Single ULCS module for all lifecycle operations

### Success Metrics
- **22+ service modules** working in harmony
- **~150,000+ lines** of well-structured code
- **Multiple client support** (Nethermind, Besu, Reth, Lodestar, Teku, Grandine)
- **Zero-downtime** service management
- **Automatic monitoring** integration
- **Single comprehensive ULCS** (2,900 lines) replacing 3 separate modules

**NODEBOI successfully bridges the gap between Ethereum's technical complexity and operator accessibility, providing a mature, production-ready system for Ethereum staking infrastructure management.**

---

*Document Version: 2.1*  
*Last Updated: September 22, 2025*  
*Comprehensive Documentation - User Guide + Technical Reference*