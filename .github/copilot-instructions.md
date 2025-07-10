# Copilot Instructions for hetz-prox

## Project Overview
This project automates Proxmox VE installation on Hetzner dedicated servers **without console access**. It uses a rescue system approach with QEMU virtualization to perform automated installation via ISO generation and SSH configuration.

## Core Architecture

### Main Components
- **`scripts/pve-install.sh`**: Primary installation orchestrator (531 lines)
  - Drive detection and ZFS RAID configuration (single, raid1, raid10, raidz-1/2/3)
  - Network interface auto-detection with IPv4/IPv6 support
  - QEMU-based virtualized installation with SSH port forwarding (5555)
  - Template-based post-installation configuration via SSH
- **`files/template_files/`**: Configuration templates with `{{VARIABLE}}` placeholders
  - `interfaces`: Network bridge configuration for Proxmox
  - `hosts`: Hostname/FQDN resolution
  - `99-proxmox.conf`: System optimization settings
  - `sources.list`: APT repository configuration
- **`files/`**: Static configuration files and utilities
  - `main_vmbr0_basic_template.txt`: Alternative network template with `#VARIABLE#` syntax
  - `rules.v4/v6`: iptables firewall rules with NAT/port forwarding examples
  - `update_main_vmbr0_basic_from_template.sh`: Standalone network updater

### Critical Workflow Pattern
1. **Rescue Mode Setup**: Must run from Hetzner rescue system (Debian-based)
2. **Drive Selection**: Interactive drive detection with automatic ZFS RAID selection based on drive count
3. **Network Auto-detection**: Uses `ip route`, `udevadm`, and interface introspection
4. **ISO Generation**: Creates custom Proxmox ISO with `answer.toml` for unattended installation
5. **QEMU Installation**: Runs Proxmox installation in virtualized environment with port forwarding
6. **SSH Configuration**: Post-install configuration via SSH on port 5555 using `sshpass`

## Key Development Patterns

### Template Variable Substitution
Two template systems are used:
- **Double braces**: `{{VARIABLE}}` in `files/template_files/` (primary)
- **Hash syntax**: `#VARIABLE#` in legacy templates (compatibility)

```bash
# Template processing pattern
sed -i "s|{{INTERFACE_NAME}}|$INTERFACE_NAME|g" ./template_files/interfaces
sed -i "s|#IFACE_NAME#|$IFACE_NAME|g" ~/interfaces_sample
```

### Drive Mapping Strategy
Physical drives are mapped to virtual drives for QEMU installation:
```bash
# Convert physical /dev/sda, /dev/sdb to virtual /dev/vda, /dev/vdb
VIRTUAL_DRIVE="/dev/vd$(printf "%c" $((97+i)))"
```

### Network Configuration
Proxmox uses bridge networking (`vmbr0`) with specific Hetzner requirements:
- Point-to-point gateway configuration
- VLAN awareness (bridge-vids 2-4094)
- IPv6 with `fe80::1` gateway
- MAC address preservation for licensing

### Error Handling & User Interaction
- Color-coded output with `CLR_*` variables for visibility
- Defensive programming with drive count validation
- Interactive confirmations for destructive operations
- Background process management with PID tracking

## Development Workflow

### Testing Approach
- **Target Environment**: Hetzner AX/EX/SX series servers in rescue mode
- **Primary Test Platform**: AX-102 with RAID-1 ZFS
- **Network Requirements**: Public IPv4/IPv6 with gateway access

### Adding New Features
1. **Drive Support**: Extend `detect_drives()` and `get_zfs_config()` functions
2. **Network Templates**: Add variables to template files and processing functions
3. **Post-Install Steps**: Extend `configure_proxmox_via_ssh()` with new SSH commands

### Configuration Management
- All user inputs are collected upfront in `get_system_inputs()`
- Template files are downloaded fresh from GitHub during installation
- Configuration is applied via SSH using `sshpass` for automation

## External Dependencies
- **Hetzner Robot API**: For rescue mode activation (manual process)
- **Proxmox Enterprise**: ISO downloads from `enterprise.proxmox.com`
- **GitHub Raw**: Template file distribution during installation
- **System Tools**: `lsblk`, `ip`, `udevadm`, `qemu-system-x86_64`, `sshpass`

## Critical Success Factors
- Network interface detection must work across different Hetzner hardware
- ZFS RAID configuration must match physical drive topology
- SSH port forwarding (5555) must be available during QEMU installation
- Template variable substitution must handle edge cases (empty IPv6, interface naming)

When modifying this project, always consider the automation-first approach - the script must run unattended after initial user input collection.
