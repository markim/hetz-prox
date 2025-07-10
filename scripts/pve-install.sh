#!/usr/bin/bash
set -e
cd /root

# Define colors for output
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_RESET="\033[m"

clear

# Ensure the script is run as root
if [[ $EUID != 0 ]]; then
    echo -e "${CLR_RED}Please run this script as root.${CLR_RESET}"
    exit 1
fi

echo -e "${CLR_GREEN}Starting Proxmox auto-installation...${CLR_RESET}"

# Function to detect available drives
detect_drives() {
    echo -e "${CLR_YELLOW}Detecting available drives...${CLR_RESET}"
    
    # Ensure lsblk is available
    if ! command -v lsblk &> /dev/null; then
        echo -e "${CLR_RED}lsblk command not found! Please install util-linux package.${CLR_RESET}"
        exit 1
    fi
    
    # Get all block devices that are drives (not partitions)
    mapfile -t AVAILABLE_DRIVES < <(lsblk -dpno NAME | grep -E '/dev/(sd|nvme|vd|hd)' | sort)
    
    if [ ${#AVAILABLE_DRIVES[@]} -eq 0 ]; then
        echo -e "${CLR_RED}No suitable drives found! Exiting.${CLR_RESET}"
        echo -e "${CLR_YELLOW}Looked for drives matching: /dev/sd*, /dev/nvme*, /dev/vd*, /dev/hd*${CLR_RESET}"
        exit 1
    fi
    
    echo -e "${CLR_YELLOW}Available drives:${CLR_RESET}"
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        drive="${AVAILABLE_DRIVES[$i]}"
        size=$(lsblk -dpno SIZE "$drive" 2>/dev/null || echo "Unknown")
        model=$(lsblk -dpno MODEL "$drive" 2>/dev/null || echo "Unknown")
        echo "  $((i+1)). $drive ($size, $model)"
    done
}

# Function to get ZFS configuration based on number of drives
get_zfs_config() {
    local num_drives=$1
    
    case $num_drives in
        1)
            echo "single"
            ;;
        2)
            echo "raid1"
            ;;
        3)
            echo "raidz-1"
            ;;
        4)
            # For 4 drives, we could use RAID10 or RAIDZ-1
            # RAID10 gives better performance but less usable space
            echo "raid10"
            ;;
        5)
            echo "raidz-1"
            ;;
        6|7|8|9)
            echo "raidz-2"
            ;;
        *)
            echo "raidz-3"
            ;;
    esac
}

# Function to select drives for installation
select_drives() {
    detect_drives
    
    echo ""
    echo -e "${CLR_YELLOW}Drive Selection Options:${CLR_RESET}"
    echo "1. Use all available drives (recommended for maximum redundancy)"
    echo "2. Select specific drives manually"
    
    read -e -p "Choose option (1 or 2): " -i "1" DRIVE_OPTION
    
    case $DRIVE_OPTION in
        1)
            SELECTED_DRIVES=("${AVAILABLE_DRIVES[@]}")
            ;;
        2)
            echo ""
            echo "Enter the numbers of drives to use (space-separated, e.g., '1 2 3'):"
            read -e -p "Drive numbers: " DRIVE_NUMBERS
            
            SELECTED_DRIVES=()
            for num in $DRIVE_NUMBERS; do
                if [[ $num -ge 1 && $num -le ${#AVAILABLE_DRIVES[@]} ]]; then
                    SELECTED_DRIVES+=("${AVAILABLE_DRIVES[$((num-1))]}")
                else
                    echo -e "${CLR_RED}Invalid drive number: $num${CLR_RESET}"
                    exit 1
                fi
            done
            ;;
        *)
            echo -e "${CLR_RED}Invalid option. Exiting.${CLR_RESET}"
            exit 1
            ;;
    esac
    
    # Validate minimum drive requirements
    if [ ${#SELECTED_DRIVES[@]} -eq 0 ]; then
        echo -e "${CLR_RED}No drives selected! Exiting.${CLR_RESET}"
        exit 1
    fi
    
    # Determine ZFS configuration
    ZFS_RAID=$(get_zfs_config ${#SELECTED_DRIVES[@]})
    
    echo ""
    echo -e "${CLR_GREEN}Selected drives for installation:${CLR_RESET}"
    for drive in "${SELECTED_DRIVES[@]}"; do
        size=$(lsblk -dpno SIZE "$drive" 2>/dev/null || echo "Unknown")
        echo "  - $drive ($size)"
    done
    
    echo ""
    echo -e "${CLR_GREEN}ZFS Configuration: $ZFS_RAID${CLR_RESET}"
    
    # Explain the ZFS configuration
    case $ZFS_RAID in
        "single")
            echo -e "${CLR_YELLOW}Note: Single drive - no redundancy. Consider backup strategy.${CLR_RESET}"
            ;;
        "raid1")
            echo -e "${CLR_YELLOW}Note: RAID1 (Mirror) - can survive 1 drive failure.${CLR_RESET}"
            ;;
        "raid10")
            echo -e "${CLR_YELLOW}Note: RAID10 - can survive multiple drive failures, excellent performance.${CLR_RESET}"
            ;;
        "raidz-1")
            echo -e "${CLR_YELLOW}Note: RAIDZ-1 - can survive 1 drive failure, more space efficient than mirror.${CLR_RESET}"
            ;;
        "raidz-2")
            echo -e "${CLR_YELLOW}Note: RAIDZ-2 - can survive 2 drive failures, recommended for 6+ drives.${CLR_RESET}"
            ;;
        "raidz-3")
            echo -e "${CLR_YELLOW}Note: RAIDZ-3 - can survive 3 drive failures, best for large arrays.${CLR_RESET}"
            ;;
    esac
    
    # Confirm selection
    echo ""
    echo -e "${CLR_RED}WARNING: This will COMPLETELY ERASE all data on the selected drives!${CLR_RESET}"
    echo -e "${CLR_RED}Make sure you have backed up any important data.${CLR_RESET}"
    echo ""
    read -e -p "Proceed with this configuration? (y/n): " -i "n" CONFIRM_DRIVES
    if [[ "$CONFIRM_DRIVES" != "y" ]]; then
        echo -e "${CLR_YELLOW}Drive selection cancelled. Exiting.${CLR_RESET}"
        exit 0
    fi
}

# Function to get user input
get_system_inputs() {
    # Select drives first
    select_drives
    
    # Get default interface name and available alternative names first
    DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$DEFAULT_INTERFACE" ]; then
        DEFAULT_INTERFACE=$(udevadm info -e | grep -m1 -A 20 ^P.*eth0 | grep ID_NET_NAME_PATH | cut -d'=' -f2)
    fi
    
    # Get all available interfaces and their altnames
    AVAILABLE_ALTNAMES=$(ip -d link show | grep -v "lo:" | grep -E '(^[0-9]+:|altname)' | awk '/^[0-9]+:/ {interface=$2; gsub(/:/, "", interface); printf "%s", interface} /altname/ {printf ", %s", $2} END {print ""}' | sed 's/, $//')
    
    # Set INTERFACE_NAME to default if not already set
    if [ -z "$INTERFACE_NAME" ]; then
        INTERFACE_NAME="$DEFAULT_INTERFACE"
    fi
    
    # Prompt user for interface name
    read -e -p "Interface name (options are: ${AVAILABLE_ALTNAMES}) : " -i "$INTERFACE_NAME" INTERFACE_NAME
    
    # Now get network information based on the selected interface
    MAIN_IPV4_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet " | xargs | cut -d" " -f2)
    MAIN_IPV4=$(echo "$MAIN_IPV4_CIDR" | cut -d'/' -f1)
    MAIN_IPV4_GW=$(ip route | grep default | xargs | cut -d" " -f3)
    MAC_ADDRESS=$(ip link show "$INTERFACE_NAME" | awk '/ether/ {print $2}')
    IPV6_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet6 " | xargs | cut -d" " -f2)
    MAIN_IPV6=$(echo "$IPV6_CIDR" | cut -d'/' -f1)
    
    # Set a default value for FIRST_IPV6_CIDR even if IPV6_CIDR is empty
    if [ -n "$IPV6_CIDR" ]; then
        FIRST_IPV6_CIDR="$(echo "$IPV6_CIDR" | cut -d'/' -f1 | cut -d':' -f1-4):1::1/80"
    else
        FIRST_IPV6_CIDR=""
    fi
    
    # Display detected information
    echo -e "${CLR_YELLOW}Detected Network Information:${CLR_RESET}"
    echo "Interface Name: $INTERFACE_NAME"
    echo "Main IPv4 CIDR: $MAIN_IPV4_CIDR"
    echo "Main IPv4: $MAIN_IPV4"
    echo "Main IPv4 Gateway: $MAIN_IPV4_GW"
    echo "MAC Address: $MAC_ADDRESS"
    echo "IPv6 CIDR: $IPV6_CIDR"
    echo "IPv6: $MAIN_IPV6"
    
    # Get user input for other configuration
    read -e -p "Enter your hostname : " -i "proxmox-example" HOSTNAME
    read -e -p "Enter your FQDN name : " -i "proxmox.example.com" FQDN
    read -e -p "Enter your timezone : " -i "Europe/Istanbul" TIMEZONE
    read -e -p "Enter your email address: " -i "admin@example.com" EMAIL
    read -e -p "Enter your private subnet : " -i "192.168.26.0/24" PRIVATE_SUBNET
    read -e -p "Enter your System New root password: " NEW_ROOT_PASSWORD
    
    # Get the network prefix (first three octets) from PRIVATE_SUBNET
    PRIVATE_CIDR=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
    # Append .1 to get the first IP in the subnet
    PRIVATE_IP="${PRIVATE_CIDR}.1"
    # Get the subnet mask length
    SUBNET_MASK=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f2)
    # Create the full CIDR notation for the first IP
    PRIVATE_IP_CIDR="${PRIVATE_IP}/${SUBNET_MASK}"
    
    # Check password was not empty, do it in loop until password is not empty
    while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
        # Print message in a new line
        echo ""
        read -e -p "Enter your System New root password: " NEW_ROOT_PASSWORD
    done

    echo ""
    echo "Private subnet: $PRIVATE_SUBNET"
    echo "First IP in subnet (CIDR): $PRIVATE_IP_CIDR"
}


prepare_packages() {
    echo -e "${CLR_BLUE}Installing packages...${CLR_RESET}"
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve.list
    curl -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
    apt clean && apt update && apt install -yq proxmox-auto-install-assistant xorriso ovmf wget sshpass

    echo -e "${CLR_GREEN}Packages installed.${CLR_RESET}"
}

# Fetch latest Proxmox VE ISO
get_latest_proxmox_ve_iso() {
    local base_url="https://enterprise.proxmox.com/iso/"
    local latest_iso
    latest_iso=$(curl -s "$base_url" | grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -n1)

    if [[ -n "$latest_iso" ]]; then
        echo "${base_url}${latest_iso}"
    else
        echo "No Proxmox VE ISO found." >&2
        return 1
    fi
}

download_proxmox_iso() {
    echo -e "${CLR_BLUE}Downloading Proxmox ISO...${CLR_RESET}"
    PROXMOX_ISO_URL=$(get_latest_proxmox_ve_iso)
    if [[ -z "$PROXMOX_ISO_URL" ]]; then
        echo -e "${CLR_RED}Failed to retrieve Proxmox ISO URL! Exiting.${CLR_RESET}"
        exit 1
    fi
    wget -O pve.iso "$PROXMOX_ISO_URL"
    echo -e "${CLR_GREEN}Proxmox ISO downloaded.${CLR_RESET}"
}

make_answer_toml() {
    echo -e "${CLR_BLUE}Making answer.toml...${CLR_RESET}"
    
    # Build disk list for toml format
    DISK_LIST_TOML=""
    for i in "${!SELECTED_DRIVES[@]}"; do
        if [ $i -eq 0 ]; then
            DISK_LIST_TOML="\"${SELECTED_DRIVES[$i]}\""
        else
            DISK_LIST_TOML="${DISK_LIST_TOML}, \"${SELECTED_DRIVES[$i]}\""
        fi
    done
    
    # Determine filesystem and raid configuration
    if [ ${#SELECTED_DRIVES[@]} -eq 1 ]; then
        FILESYSTEM="ext4"
        RAID_CONFIG=""
        echo -e "${CLR_YELLOW}Using ext4 filesystem for single drive setup${CLR_RESET}"
    else
        FILESYSTEM="zfs"
        RAID_CONFIG="    zfs.raid = \"$ZFS_RAID\""
        echo -e "${CLR_YELLOW}Using ZFS filesystem with $ZFS_RAID configuration${CLR_RESET}"
    fi
    
    cat <<EOF > answer.toml
[global]
    keyboard = "en-us"
    country = "us"
    fqdn = "$FQDN"
    mailto = "$EMAIL"
    timezone = "$TIMEZONE"
    root_password = "$NEW_ROOT_PASSWORD"
    reboot_on_error = false

[network]
    source = "from-dhcp"

[disk-setup]
    filesystem = "$FILESYSTEM"
$RAID_CONFIG
    disk_list = [$DISK_LIST_TOML]

EOF
    echo -e "${CLR_GREEN}answer.toml created with ${#SELECTED_DRIVES[@]} drive(s) using $FILESYSTEM${CLR_RESET}"
}

make_autoinstall_iso() {
    echo -e "${CLR_BLUE}Making autoinstall.iso...${CLR_RESET}"
    proxmox-auto-install-assistant prepare-iso pve.iso --fetch-from iso --answer-file answer.toml --output pve-autoinstall.iso
    echo -e "${CLR_GREEN}pve-autoinstall.iso created.${CLR_RESET}"
}

# Function to build QEMU drive arguments
build_qemu_drives() {
    local drive_args=""
    for drive in "${SELECTED_DRIVES[@]}"; do
        drive_args="$drive_args -drive file=$drive,format=raw,media=disk,if=virtio"
    done
    echo "$drive_args"
}

is_uefi_mode() {
  [ -d /sys/firmware/efi ]
}

# Install Proxmox via QEMU/VNC
install_proxmox() {
    echo -e "${CLR_GREEN}Starting Proxmox VE installation...${CLR_RESET}"

    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        echo -e "UEFI Supported! Booting with UEFI firmware."
    else
        UEFI_OPTS=""
        echo -e "UEFI Not Supported! Booting in legacy mode."
    fi
    
    # Build drive arguments dynamically
    DRIVE_ARGS=$(build_qemu_drives)
    
    echo -e "${CLR_YELLOW}Installing Proxmox VE${CLR_RESET}"
	echo -e "${CLR_YELLOW}=================================${CLR_RESET}"
    echo -e "${CLR_RED}Do NOT do anything, just wait about 5-10 min!${CLR_RED}"
	echo -e "${CLR_YELLOW}=================================${CLR_RESET}"
    qemu-system-x86_64 \
        -enable-kvm $UEFI_OPTS \
        -cpu host -smp 4 -m 4096 \
        -boot d -cdrom ./pve-autoinstall.iso \
        $DRIVE_ARGS -no-reboot -display none > /dev/null 2>&1
}

# Function to boot the installed Proxmox via QEMU with port forwarding
boot_proxmox_with_port_forwarding() {
    echo -e "${CLR_GREEN}Booting installed Proxmox with SSH port forwarding...${CLR_RESET}"

    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        echo -e "${CLR_YELLOW}UEFI Supported! Booting with UEFI firmware.${CLR_RESET}"
    else
        UEFI_OPTS=""
        echo -e "${CLR_YELLOW}UEFI Not Supported! Booting in legacy mode.${CLR_RESET}"
    fi
    
    # Build drive arguments dynamically
    DRIVE_ARGS=$(build_qemu_drives)
    
    # Start QEMU in background with port forwarding
    nohup qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::5555-:22 \
        -smp 4 -m 4096 \
        $DRIVE_ARGS \
        > qemu_output.log 2>&1 &
    
    QEMU_PID=$!
    echo -e "${CLR_YELLOW}QEMU started with PID: $QEMU_PID${CLR_RESET}"
    
    # Wait for SSH to become available on port 5555
    echo -e "${CLR_YELLOW}Waiting for SSH to become available on port 5555...${CLR_RESET}"
    for i in {1..60}; do
        if nc -z localhost 5555; then
            echo -e "${CLR_GREEN}SSH is available on port 5555.${CLR_RESET}"
            break
        fi
        echo -n "."
        sleep 5
        if [ $i -eq 60 ]; then
            echo -e "${CLR_RED}SSH is not available after 5 minutes. Check the system manually.${CLR_RESET}"
            return 1
        fi
    done
    
    return 0
}

make_template_files() {
    echo -e "${CLR_BLUE}Modifying template files...${CLR_RESET}"
    
    echo -e "${CLR_YELLOW}Downloading template files...${CLR_RESET}"
    mkdir -p ./template_files

    wget -O ./template_files/99-proxmox.conf https://github.com/markim/hetz-prox/raw/refs/heads/main/files/template_files/99-proxmox.conf
    wget -O ./template_files/hosts https://github.com/markim/hetz-prox/raw/refs/heads/main/files/template_files/hosts
    wget -O ./template_files/interfaces https://github.com/markim/hetz-prox/raw/refs/heads/main/files/template_files/interfaces
    wget -O ./template_files/sources.list https://github.com/markim/hetz-prox/raw/refs/heads/main/files/template_files/sources.list

    # Process hosts file
    echo -e "${CLR_YELLOW}Processing hosts file...${CLR_RESET}"
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/hosts
    sed -i "s|{{FQDN}}|$FQDN|g" ./template_files/hosts
    sed -i "s|{{HOSTNAME}}|$HOSTNAME|g" ./template_files/hosts
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/hosts

    # Process interfaces file
    echo -e "${CLR_YELLOW}Processing interfaces file...${CLR_RESET}"
    sed -i "s|{{INTERFACE_NAME}}|$INTERFACE_NAME|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_CIDR}}|$MAIN_IPV4_CIDR|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_GW}}|$MAIN_IPV4_GW|g" ./template_files/interfaces
    sed -i "s|{{MAC_ADDRESS}}|$MAC_ADDRESS|g" ./template_files/interfaces
    sed -i "s|{{IPV6_CIDR}}|$IPV6_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_IP_CIDR}}|$PRIVATE_IP_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_SUBNET}}|$PRIVATE_SUBNET|g" ./template_files/interfaces
    sed -i "s|{{FIRST_IPV6_CIDR}}|$FIRST_IPV6_CIDR|g" ./template_files/interfaces

    echo -e "${CLR_GREEN}Template files modified successfully.${CLR_RESET}"
}

# Function to configure the installed Proxmox via SSH
configure_proxmox_via_ssh() {
    echo -e "${CLR_BLUE}Starting post-installation configuration via SSH...${CLR_RESET}"
    make_template_files
	ssh-keygen -f "/root/.ssh/known_hosts" -R "[localhost]:5555" || true
    # copy template files to the server using scp
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/hosts root@localhost:/etc/hosts
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/interfaces root@localhost:/etc/network/interfaces
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/99-proxmox.conf root@localhost:/etc/sysctl.d/99-proxmox.conf
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/sources.list root@localhost:/etc/apt/sources.list
    
    # comment out the line in the sources.list file
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/pve-enterprise.list"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/ceph.list"
    #sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo -e 'nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 4.2.2.4\nnameserver 9.9.9.9' | tee /etc/resolv.conf"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo -e 'nameserver 185.12.64.1\nnameserver 185.12.64.2\nnameserver 1.1.1.1\nnameserver 8.8.4.4' | tee /etc/resolv.conf"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo $HOSTNAME > /etc/hostname"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "systemctl disable --now rpcbind rpcbind.socket"
    # Power off the VM
    echo -e "${CLR_YELLOW}Powering off the VM...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'poweroff' || true
    
    # Wait for QEMU to exit
    echo -e "${CLR_YELLOW}Waiting for QEMU process to exit...${CLR_RESET}"
    wait $QEMU_PID || true
    echo -e "${CLR_GREEN}QEMU process has exited.${CLR_RESET}"
}

# Function to reboot into the main OS
reboot_to_main_os() {
    echo -e "${CLR_GREEN}Installation complete!${CLR_RESET}"
    echo -e "${CLR_YELLOW}After rebooting, you will be able to access your Proxmox at https://${MAIN_IPV4_CIDR%/*}:8006${CLR_RESET}"
    
    #ask user to reboot the system
    read -e -p "Do you want to reboot the system? (y/n): " -i "y" REBOOT
    if [[ "$REBOOT" == "y" ]]; then
        echo -e "${CLR_YELLOW}Rebooting the system...${CLR_RESET}"
        reboot
    else
        echo -e "${CLR_YELLOW}Exiting...${CLR_RESET}"
        exit 0
    fi
}



# Main execution flow
get_system_inputs
prepare_packages
download_proxmox_iso
make_answer_toml
make_autoinstall_iso
install_proxmox

echo -e "${CLR_YELLOW}Waiting for installation to complete...${CLR_RESET}"

# Boot the installed Proxmox with port forwarding
boot_proxmox_with_port_forwarding || {
    echo -e "${CLR_RED}Failed to boot Proxmox with port forwarding. Exiting.${CLR_RESET}"
    exit 1
}

# Configure Proxmox via SSH
configure_proxmox_via_ssh

# Reboot to the main OS
reboot_to_main_os
