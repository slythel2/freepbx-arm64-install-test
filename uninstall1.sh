#!/bin/bash

# FIX CRLF: Auto-correction for Windows line endings
(set -o igncr) 2>/dev/null && set -o igncr; # Cywin/MinGW workaround

if grep -q $'\r' "$0"; then
    echo "Windows line endings (CRLF) detected. Fixing..."
    sed -i 's/\r$//' "$0"
    echo "File fixed. Restarting script..."
    exec bash "$0" "$@"
fi

# ============================================================================
# SCRIPT: uninstall.sh (v0.9.8 - Safe Mode)
# PURPOSE: Remove Asterisk/FreePBX without killing System Networking
# TARGET:  Armbian 12
# ============================================================================

# Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================================${NC}"
echo -e "${RED}   WARNING: FREEPBX UNINSTALLATION SCRIPT (SAFE MODE)       ${NC}"
echo -e "${RED}========================================================${NC}"
echo "This script will delete Asterisk, FreePBX, and LAMP stack."
echo "Network components will be preserved."
echo ""
read -p "Are you SURE? (type 'yes' to confirm): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo -e "${YELLOW}[1/8] Stopping services & Killing processes...${NC}"

# 1. Kill FreePBX Console first to avoid DB connection errors
if command -v fwconsole &> /dev/null; then
    fwconsole stop &> /dev/null || true
fi

# 2. Stop Services
systemctl stop asterisk &> /dev/null
systemctl stop freepbx &> /dev/null
systemctl stop apache2 &> /dev/null
systemctl stop mariadb &> /dev/null

# 3. Aggressive Process Kill
killall -9 asterisk &> /dev/null || true
killall -9 safe_asterisk &> /dev/null || true
pkill -u asterisk &> /dev/null || true
if command -v pm2 &> /dev/null; then
    pm2 kill &> /dev/null || true
fi

echo -e "${YELLOW}[2/8] Removing Systemd Services...${NC}"
systemctl disable asterisk &> /dev/null
systemctl disable free-perm-fix.service &> /dev/null
rm -f /etc/systemd/system/asterisk.service
rm -f /etc/systemd/system/free-perm-fix.service
rm -f /usr/local/bin/fix_free_perm.sh
systemctl daemon-reload

echo -e "${YELLOW}[3/8] Deep Cleaning Directories...${NC}"
rm -rf /etc/asterisk
rm -rf /var/lib/asterisk
rm -rf /var/log/asterisk
rm -rf /var/spool/asterisk
rm -rf /var/run/asterisk
rm -rf /usr/lib/asterisk
rm -rf /usr/sbin/asterisk
# Be careful not to delete system web files if not asterisk related
rm -rf /var/www/html/admin
rm -rf /var/www/html/index.php
rm -rf /home/asterisk

# Clean Logs & Configs for LAMP Stack
rm -rf /etc/apache2
rm -rf /var/log/apache2
rm -rf /var/lib/apache2
rm -rf /etc/php
rm -rf /var/lib/php
rm -rf /var/lib/mysql
rm -rf /var/log/mysql

echo -e "${YELLOW}[4/8] Removing Users and Groups...${NC}"
deluser --remove-home asterisk &> /dev/null || true
delgroup asterisk &> /dev/null || true

echo -e "${YELLOW}[5/8] Removing NodeJS & PM2...${NC}"
if command -v npm &> /dev/null; then
    npm uninstall -g pm2 &> /dev/null
fi
rm -rf /usr/lib/node_modules
rm -rf /etc/npm
rm -rf ~/.npm

echo -e "${YELLOW}[6/8] Purging Main Packages...${NC}"
# SAFETY CHECK: Ensure we don't remove network essentials
apt-mark manual network-manager netplan.io armbian-config &> /dev/null

DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    apache2* \
    mariadb* \
    php* \
    nodejs npm \
    unixodbc* odbcinst* \
    libasterisk* \
    xmlstarlet \
    libjwt0 liburiparser1 liblua5.4-0 &> /dev/null

echo -e "${YELLOW}[7/8] Cleaning up Package Manager...${NC}"
# We skip aggressive library purge (libltdl7) to avoid breaking system tools
apt-get autoremove -y &> /dev/null
apt-get clean &> /dev/null

echo -e "${YELLOW}[8/8] Final Sweep...${NC}"
rm -rf /etc/apache2 2>/dev/null
rm -rf /etc/php 2>/dev/null
rm -rf /etc/asterisk 2>/dev/null
rm -rf /etc/mysql 2>/dev/null
# Remove Status Banner
rm -f /etc/update-motd.d/99-pbx-status 2>/dev/null

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}   SYSTEM CLEANED (NETWORK PRESERVED)                   ${NC}"
echo -e "${GREEN}========================================================${NC}"
echo "Reboot recommended."
