#!/bin/bash

# Color codes for premium terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}==============================================${NC}"
echo -e "${CYAN}      OpenWrt Router Script Deployer         ${NC}"
echo -e "${BLUE}==============================================${NC}"

# Define candidate IPs for the router
IPS=("192.168.2.1" "192.168.1.1")
ROUTER_IP=""

# Detect which IP is alive
echo -e "${YELLOW}Detecting active router IP...${NC}"
for ip in "${IPS[@]}"; do
    if ping -c 1 -t 1 "$ip" &> /dev/null; then
        ROUTER_IP="$ip"
        echo -e "${GREEN}✔ Found active router at: $ROUTER_IP${NC}"
        break
    fi
done

# If ping -t didn't work (macOS uses -t, Linux uses -W), let's fallback to standard ping with short deadline
if [ -z "$ROUTER_IP" ]; then
    for ip in "${IPS[@]}"; do
        if ping -c 1 -W 1000 "$ip" &> /dev/null; then
            ROUTER_IP="$ip"
            echo -e "${GREEN}✔ Found active router at: $ROUTER_IP${NC}"
            break
        fi
    done
fi

if [ -z "$ROUTER_IP" ]; then
    echo -e "${RED}✗ Error: Could not ping the router at 192.168.2.1 or 192.168.1.1.${NC}"
    echo -e "${YELLOW}Please check your network connection or enter the IP manually.${NC}"
    read -p "Enter router IP manually (or press Enter to exit): " manual_ip
    if [ -z "$manual_ip" ]; then
        exit 1
    else
        ROUTER_IP="$manual_ip"
    fi
fi

echo -e "${YELLOW}Connecting to root@$ROUTER_IP and transferring scripts...${NC}"

# Ensure /opt/scripts directory exists on the router
echo -e "${BLUE}[1/3] Ensuring /opt/scripts directory exists...${NC}"
ssh -o ConnectTimeout=3 root@$ROUTER_IP "mkdir -p /opt/scripts"
if [ $? -ne 0 ]; then
    echo -e "${RED}✗ SSH Connection failed. Make sure SSH is enabled on the router.${NC}"
    exit 1
fi

# Copy all scripts to /opt/scripts/
echo -e "${BLUE}[2/3] Copying scripts to router...${NC}"
scp opt/scripts/* root@$ROUTER_IP:/opt/scripts/
if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Failed to copy scripts.${NC}"
    exit 1
fi

# Make scripts executable on the router
echo -e "${BLUE}[3/3] Setting executable permissions on the router...${NC}"
ssh root@$ROUTER_IP "chmod +x /opt/scripts/*.sh"
if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Failed to set permissions.${NC}"
    exit 1
fi

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}✔ Deployment completed successfully!          ${NC}"
echo -e "${GREEN}==============================================${NC}"
