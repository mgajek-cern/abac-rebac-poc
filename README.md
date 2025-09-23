# abac-rebac-poc

Proof of concept implementation comparing modern authorization technologies: OpenFGA and Open Policy Agent (OPA)

## Overview

This POC demonstrates two authorization paradigms through containerized implementations:

- **REBAC (Relationship-Based Access Control)** using OpenFGA
- **ABAC (Attribute-Based Access Control)** using Open Policy Agent

The implementation includes sample applications and test scenarios to evaluate both approaches.

## Technologies

### OpenFGA (Fine-Grained Authorization)

**What it is**: A scalable authorization service inspired by Google Zanzibar, designed for relationship-based access control.

**Key Features**:
- Tuple-based relationship storage with high performance
- Recursive permission evaluation for complex hierarchies  
- Real-time authorization decisions with microsecond latency
- Built-in support for common patterns (hierarchies, groups, ownership)

**Use Cases**:
- Document sharing platforms (Google Drive-style permissions)
- Team-based access control in SaaS applications
- Multi-tenant authorization with organization hierarchies
- Resource ownership and delegation patterns

### Open Policy Agent (OPA)

**What it is**: A cloud-native policy engine that enables attribute-based authorization decisions across your stack.

**Key Features**:
- Rego declarative policy language for complex rules
- Data integration from multiple sources (APIs, databases, files)
- Decision logging and policy evaluation tracing
- High-performance in-memory policy evaluation

**Use Cases**:
- API gateway authorization
- Kubernetes admission control
- Compliance policy enforcement
- Dynamic access control based on user attributes, time, location

## Preconditions

- [Docker Engine](https://docs.docker.com/engine/install/)
- [Docker Compose](https://docs.docker.com/compose/install/)

### Recommended

- [VS Code](https://code.visualstudio.com/) with [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## Quick Start

### OpenFGA (REBAC) Setup

```bash
cd openfga
docker compose up -d --build
./test-api.sh
```

### OPA (ABAC) Setup

```bash
cd opa  
docker compose up -d --build
./test-api.sh
```

## Project Structure

```
├── openfga/
│   ├── docker-compose.yml
│   ├── init/                  # Initialization scripts
│   ├── python/                # Python sample application
│   └── test-api.sh
├── opa/
│   ├── docker-compose.yml
│   ├── init/                  # Initialization scripts  
│   ├── python/                # Python sample application
│   └── test-api.sh
└── README.md
```