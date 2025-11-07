# K3s-in-Kubernetes Installer Package Contents

This document describes all files in the installer package and their purposes.

## Directory Structure

```
k3s-nested-installer/
├── README.md                    # Main entry point and overview
├── QUICKSTART.md               # 3-minute quick start guide
├── IMPLEMENTATION.md           # Comprehensive implementation guide
├── TROUBLESHOOTING.md          # Common issues and solutions
├── PACKAGE_CONTENTS.md         # This file
├── install.sh                  # Main installer script
├── manage.sh                   # Management utility script
├── examples/                   # Example configurations
│   ├── single-instance.yaml    # Basic single instance config
│   ├── loadbalancer.yaml       # LoadBalancer access example
│   └── ingress.yaml            # Ingress access example
├── kubeconfigs/                # Generated kubeconfigs (created at runtime)
│   └── k3s-{instance}.yaml     # One per deployed instance
└── templates/                  # (Reserved for future template files)
```

## Core Files

### Documentation

#### README.md
- **Purpose**: Main entry point for the entire package
- **Audience**: All users
- **Contents**:
  - Overview and key features
  - Architecture diagram
  - Quick start guide
  - Usage examples
  - Command reference
  - Configuration options
  - Platform compatibility
  - Troubleshooting quick tips

#### QUICKSTART.md
- **Purpose**: Get users running in 3 minutes
- **Audience**: New users who want to try it quickly
- **Contents**:
  - Prerequisites check
  - Three different quick-start methods
  - Common next steps
  - Basic troubleshooting

#### IMPLEMENTATION.md
- **Purpose**: Complete step-by-step implementation guide
- **Audience**: Users deploying to new clusters
- **Contents**:
  - Detailed prerequisites
  - Step-by-step installation procedure
  - Multi-instance deployment guide
  - Access methods comparison
  - Complete configuration reference
  - Post-installation tasks
  - Advanced topics (backups, monitoring, etc.)

#### TROUBLESHOOTING.md
- **Purpose**: Comprehensive troubleshooting guide
- **Audience**: Users encountering issues
- **Contents**:
  - Installation issues
  - Pod startup problems
  - Connectivity issues
  - Performance problems
  - Storage issues
  - Platform-specific issues (GKE, EKS, AKS, OpenShift, etc.)
  - Diagnostic commands
  - FAQ

### Scripts

#### install.sh
- **Purpose**: Main installer script
- **Language**: Bash
- **Features**:
  - Parameterized installation
  - Config file support
  - Multiple access methods (NodePort, LoadBalancer, Ingress)
  - Dry-run mode
  - Verbose logging
  - Prerequisites checking
  - Manifest generation
  - Automatic kubeconfig extraction
  - Wait for pod readiness
- **Usage**:
  ```bash
  ./install.sh --name dev [options]
  ./install.sh --config config.yaml
  ```

#### manage.sh
- **Purpose**: Management utility for deployed instances
- **Language**: Bash
- **Features**:
  - List all instances
  - Access specific instance
  - Show detailed status
  - Refresh kubeconfigs
  - Execute kubectl commands
  - View logs
  - Delete instances
  - Show resource usage
- **Commands**:
  - `list` - List all k3s instances
  - `access <name>` - Access an instance
  - `status <name>` - Show detailed status
  - `refresh-kubeconfig <name>` - Refresh kubeconfig
  - `exec <name> -- <command>` - Execute kubectl command
  - `logs <name> [container]` - Show logs
  - `delete <name>` - Delete instance
  - `delete-all` - Delete all instances
  - `resources` - Show resource usage

### Examples

#### examples/single-instance.yaml
- **Purpose**: Basic single instance configuration
- **Use Case**: Development, testing
- **Features**:
  - NodePort access (port 30443)
  - 10Gi storage
  - Standard resource limits

#### examples/loadbalancer.yaml
- **Purpose**: LoadBalancer access configuration
- **Use Case**: Cloud environments, staging/production
- **Features**:
  - LoadBalancer service
  - Cloud-specific annotation examples
  - Larger resource allocation

#### examples/ingress.yaml
- **Purpose**: Ingress access configuration
- **Use Case**: Production, many instances
- **Features**:
  - Hostname-based routing
  - SSL passthrough annotations
  - Production resource allocation
  - DNS setup instructions

## Runtime Directories

### kubeconfigs/
- **Created**: Automatically during installation
- **Contents**: One kubeconfig file per deployed instance
- **Format**: `k3s-{instance-name}.yaml`
- **Usage**: Set as KUBECONFIG to access inner k3s cluster

## How to Use This Package

### For New Users

1. Read [README.md](README.md) - Get overview
2. Read [QUICKSTART.md](QUICKSTART.md) - Try it out quickly
3. Review [examples/](examples/) - See configuration options
4. If issues, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

### For Deploying to New Cluster

1. Read [IMPLEMENTATION.md](IMPLEMENTATION.md) - Full guide
2. Check prerequisites section
3. Choose access method (NodePort/LoadBalancer/Ingress)
4. Select appropriate example from [examples/](examples/)
5. Run installer
6. Follow post-installation steps

### For Production Deployment

1. Read [IMPLEMENTATION.md](IMPLEMENTATION.md) completely
2. Review [examples/ingress.yaml](examples/ingress.yaml)
3. Plan resource allocation
4. Configure storage class
5. Set up monitoring
6. Review [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for platform-specific notes

### For Managing Existing Instances

1. Use `./manage.sh` commands
2. Reference [README.md](README.md) for command syntax
3. If issues, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Key Design Decisions

### Why Bash Scripts?
- Maximum portability
- No dependencies beyond kubectl
- Easy to read and modify
- Works everywhere Kubernetes works

### Why DinD + k3d?
- Most reliable way to run k3s in containers
- k3d handles k3s lifecycle management
- DinD provides isolated Docker environment
- Proven approach used by k3d project itself

### Why Multiple Access Methods?
- Different use cases need different access patterns
- NodePort: Simple, works everywhere
- LoadBalancer: Clean, cloud-native
- Ingress: Most scalable for many instances

### Why Per-Instance Namespaces?
- Clear isolation
- Easy resource tracking
- Simple cleanup
- Standard Kubernetes multi-tenancy pattern

## Customization Points

### Modifying installer behavior
Edit `install.sh`:
- Line ~200: `generate_deployment()` - Modify deployment spec
- Line ~350: `deploy_instance()` - Change deployment logic
- Line ~50: Default values

### Adding new access methods
Edit `install.sh`:
- Add new `generate_service_*()` function
- Update `deploy_instance()` to handle new method
- Add validation in `validate_config()`

### Adding new management commands
Edit `manage.sh`:
- Add `cmd_*()` function
- Add case in `main()` function
- Update `show_usage()`

## Testing

### Manual Testing Checklist

```bash
# 1. Test basic installation
./install.sh --name test-basic

# 2. Test each access method
./install.sh --name test-np --access-method nodeport
./install.sh --name test-lb --access-method loadbalancer
./install.sh --name test-ing --access-method ingress --ingress-hostname test.local

# 3. Test management commands
./manage.sh list
./manage.sh status test-basic
./manage.sh access test-basic
./manage.sh refresh-kubeconfig test-basic

# 4. Test cleanup
./manage.sh delete test-basic
./manage.sh delete-all

# 5. Test dry-run
./install.sh --name test-dry --dry-run
```

### Compatibility Testing

Test on different platforms:
- Vanilla Kubernetes
- GKE
- EKS
- AKS
- MicroK8s
- Kind
- OpenShift

## Version History

### v1.0 (Current)
- Initial release
- Support for NodePort, LoadBalancer, Ingress
- Multi-instance support
- Management utility
- Comprehensive documentation

### Future Enhancements
- Helm chart packaging
- Batch installation support
- Backup/restore automation
- Monitoring integration
- HA multi-server support
- GitOps examples

## Support Resources

- Main documentation: [README.md](README.md)
- Implementation guide: [IMPLEMENTATION.md](IMPLEMENTATION.md)
- Quick start: [QUICKSTART.md](QUICKSTART.md)
- Troubleshooting: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- Examples: [examples/](examples/)

## Contributing

To contribute to this package:

1. **Documentation**: Improve guides, add examples
2. **Scripts**: Enhance installer or management utility
3. **Testing**: Test on new platforms, report issues
4. **Examples**: Share your configurations

## License

[Your License Information]

---

**Package maintained by**: [Your Name/Organization]

**Last updated**: 2025-11-06
