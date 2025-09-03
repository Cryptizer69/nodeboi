# NODEBOI - Ethereum Multi-Client Node Manager

NODEBOI is a bash script that simplifies deploying and managing multiple Ethereum nodes with different client combinations through Docker Compose.

## What NODEBOI Does

- **Multi-node Management**: Run multiple Ethereum nodes simultaneously with different client combinations
- **Client Diversity**: Supports Reth, Besu, Nethermind (execution) and Lodestar, Teku, Grandine (consensus)
- **Automated Setup**: Handles JWT secrets, port allocation, and configuration automatically
- **Built-in Monitoring**: Includes MEV-boost support and monitoring capabilities

## Architecture & Security

NODEBOI implements security best practices:

- **Isolated Users**: Each node runs under its own system user (ethnode1, ethnode2, etc.)
- **Isolated Networks**: Each node operates in its own Docker network namespace
- **Separated Data**: Individual data directories per node (~/ethnode1, ~/ethnode2, etc.)
- **JWT Authentication**: Secure communication between execution and consensus layers
- **Port Management**: Automatic port allocation to prevent conflicts
- **Container Isolation**: All clients run in Docker containers with restricted privileges

## Installation

One-line installation:
wget -qO- https://raw.githubusercontent.com/Cryptizer69/nodeboi/main/install.sh | bash

# Run NODEBOI from any directory
nodeboi

**Modular architecture with minimal code duplication**

## What's New in v0.2.0
- 📁 **4-file structure** - Clean separation of concerns
- 🎯 **Centralized client config** - Most client settings in one place
- 🚫 **~600-800 lines less code** - Removed duplicate functions
- ⚡ **Easier maintenance** - Logical file organization


