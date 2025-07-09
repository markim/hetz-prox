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

# Function to detect available disks
detect_disks() {
    echo -e "${CLR_BLUE}Detecting available disks...${CLR_RESET}"
    
    # Get all NVMe and SATA disks, excluding partitions
    mapfile -t AVAILABLE_DISKS < <(lsblk -nd -o NAME | grep -E '^(nvme[0-9]+n[0-9]+|sd[a-z]+)$' | sort)
    
    if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
        echo -e "${CLR_RED}No suitable disks found!${CLR_RESET}"
        exit 1
    fi
    
    echo -e "${CLR_YELLOW}Available disks:${CLR_RESET}"
    for disk in "${AVAILABLE_DISKS[@]}"; do
        SIZE=$(lsblk -nd -o SIZE /dev/"$disk")
        echo "  /dev/$disk ($SIZE)"
    done
    
    # Configure disk setup based on number of disks
    DISK_COUNT=${#AVAILABLE_DISKS[@]}
    
    if [ "$DISK_COUNT" -eq 1 ]; then
        DISK_SETUP="single"
        DISK_LIST="[\"/dev/${AVAILABLE_DISKS[0]}\"]"
        echo -e "${CLR_YELLOW}Single disk detected: /dev/${AVAILABLE_DISKS[0]} - will use ZFS single disk${CLR_RESET}"
    elif [ $((DISK_COUNT % 2)) -eq 0 ]; then
        DISK_SETUP="raid1_multiple"
        # Create pairs for RAID1 mirrors
        DISK_LIST="["
        for ((i=0; i<DISK_COUNT; i+=2)); do
            if [ $i -gt 0 ]; then
                DISK_LIST+=", "
            fi
            DISK_LIST+="\"/dev/${AVAILABLE_DISKS[i]}\", \"/dev/${AVAILABLE_DISKS[i+1]}\""
        done
        DISK_LIST+="]"
        echo -e "${CLR_YELLOW}Even number of disks detected ($DISK_COUNT) - will create $((DISK_COUNT/2)) RAID1 mirror(s)${CLR_RESET}"
    else
        # Odd number of disks - use all but the last one for RAID1 pairs, last one as single
        DISK_SETUP="raid1_plus_single"
        PAIR_COUNT=$((DISK_COUNT-1))
        DISK_LIST="["
        for ((i=0; i<PAIR_COUNT; i+=2)); do
            if [ $i -gt 0 ]; then
                DISK_LIST+=", "
            fi
            DISK_LIST+="\"/dev/${AVAILABLE_DISKS[i]}\", \"/dev/${AVAILABLE_DISKS[i+1]}\""
        done
        DISK_LIST+=", \"/dev/${AVAILABLE_DISKS[-1]}\"]"
        echo -e "${CLR_YELLOW}Odd number of disks detected ($DISK_COUNT) - will create $((PAIR_COUNT/2)) RAID1 mirror(s) and 1 single disk${CLR_RESET}"
    fi
    
    QEMU_DISKS_ARRAY=()
    for disk in "${AVAILABLE_DISKS[@]}"; do
        QEMU_DISKS_ARRAY+=("-drive" "file=/dev/$disk,format=raw,media=disk,if=virtio")
    done
}

# Function to get user input
get_system_inputs() {
    # Detect disks first
    detect_disks
    
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
    read -er -p "Interface name (options are: ${AVAILABLE_ALTNAMES}) : " -i "$INTERFACE_NAME" INTERFACE_NAME
    
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
    read -er -p "Enter your hostname : " -i "proxmox" HOSTNAME
    read -er -p "Enter your FQDN name : " -i "proxmox.e.com" FQDN
    read -er -p "Enter your timezone : " -i "America/Phoenix" TIMEZONE
    read -er -p "Enter your email address: " -i "a@e.com" EMAIL
    read -er -p "Enter your private subnet : " -i "192.168.1.10/24" PRIVATE_SUBNET
    read -er -p "Enter your System New root password: " NEW_ROOT_PASSWORD
    
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
        read -er -p "Enter your System New root password: " NEW_ROOT_PASSWORD
    done

    echo ""
    echo "Private subnet: $PRIVATE_SUBNET"
    echo "First IP in subnet (CIDR): $PRIVATE_IP_CIDR"
    
    # Display final configuration summary
    echo ""
    echo -e "${CLR_GREEN}=== CONFIGURATION SUMMARY ===${CLR_RESET}"
    echo -e "${CLR_YELLOW}Network:${CLR_RESET}"
    echo "  Interface: $INTERFACE_NAME"
    echo "  Main IP: $MAIN_IPV4_CIDR"
    echo "  Gateway: $MAIN_IPV4_GW"
    echo "  IPv6: $IPV6_CIDR"
    echo "  Hostname: $HOSTNAME"
    echo "  FQDN: $FQDN"
    echo ""
    echo -e "${CLR_YELLOW}Disk Configuration:${CLR_RESET}"
    echo "  Disk Count: $DISK_COUNT"
    echo "  Setup Type: $DISK_SETUP"
    echo "  Disks: $DISK_LIST"
    echo ""
}


prepare_packages() {
    echo -e "${CLR_BLUE}Installing packages...${CLR_RESET}"
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve.list
    curl -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
    apt clean && apt update && apt install -yq proxmox-auto-install-assistant xorriso ovmf wget sshpass

    echo -e "${CLR_GREEN}Packages installed.${CLR_RESET}"
}

download_proxmox_iso() {
    echo -e "${CLR_BLUE}Downloading Proxmox ISO from Hetzner mirror...${CLR_RESET}"
    PROXMOX_ISO_URL="https://hetzner:download@download.hetzner.com/bootimages/iso/proxmox-ve_8.3-1.iso"
    wget -O pve.iso "$PROXMOX_ISO_URL"
    echo -e "${CLR_GREEN}Proxmox ISO downloaded.${CLR_RESET}"
}

make_answer_toml() {
    echo -e "${CLR_BLUE}Making answer.toml...${CLR_RESET}"
    
    # Create the answer.toml with dynamic disk configuration
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
    filesystem = "zfs"
EOF

    # Add ZFS RAID configuration based on disk setup
    if [ "$DISK_SETUP" = "single" ]; then
        cat <<EOF >> answer.toml
    disk_list = $DISK_LIST
EOF
    else
        cat <<EOF >> answer.toml
    zfs.raid = "raid1"
    disk_list = $DISK_LIST
EOF
    fi

    echo "" >> answer.toml
    echo -e "${CLR_GREEN}answer.toml created with $DISK_COUNT disk(s).${CLR_RESET}"
}

make_autoinstall_iso() {
    echo -e "${CLR_BLUE}Making autoinstall.iso...${CLR_RESET}"
    proxmox-auto-install-assistant prepare-iso pve.iso --fetch-from iso --answer-file answer.toml --output pve-autoinstall.iso
    echo -e "${CLR_GREEN}pve-autoinstall.iso created.${CLR_RESET}"
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
    echo -e "${CLR_YELLOW}Installing Proxmox VE${CLR_RESET}"
	echo -e "${CLR_YELLOW}=================================${CLR_RESET}"
    echo -e "${CLR_RED}Do NOT do anything, just wait about 5-10 min!${CLR_RED}"
	echo -e "${CLR_YELLOW}=================================${CLR_RESET}"
    qemu-system-x86_64 \
        -enable-kvm "$UEFI_OPTS" \
        -cpu host -smp 4 -m 4096 \
        -boot d -cdrom ./pve-autoinstall.iso \
        "${QEMU_DISKS_ARRAY[@]}" -no-reboot -display none > /dev/null 2>&1
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
    # UEFI_OPTS=""
    # Start QEMU in background with port forwarding
    nohup qemu-system-x86_64 -enable-kvm "$UEFI_OPTS" \
        -cpu host -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::5555-:22 \
        -smp 4 -m 4096 \
        "${QEMU_DISKS_ARRAY[@]}" \
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
        if [ "$i" -eq 60 ]; then
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
    read -er -p "Do you want to reboot the system? (y/n): " -i "y" REBOOT
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
