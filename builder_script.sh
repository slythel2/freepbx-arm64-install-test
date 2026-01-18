#!/bin/bash

# ============================================================================
# AUTOMATED BUILD SCRIPT (Executed inside the ARM64 container)
# TARGET: Asterisk 22 LTS for Debian 12 (Bookworm)
# VERSION: Debug Enhanced v1.7 (Stable Environment)
# ============================================================================

# Stop execution on any error
set -e

# --- 1. INITIAL SYSTEM SETUP (No debug calls here) ---
echo ">>> [BUILDER] Initializing environment and installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# We install everything needed for the script to run safely first
apt-get install -y -qq --no-install-recommends procps python3 python3-dev python-is-python3 > /dev/null

# --- 2. DEBUG UTILS ---

# Function to display system status (RAM, Disk, Python)
sys_status() {
    echo "--- [SYSTEM STATUS] ---"
    echo "Disk Space:"
    df -h / | tail -n 1
    
    echo "Memory Usage:"
    if command -v free >/dev/null 2>&1; then
        free -m
    else
        echo "free command not found"
    fi
    
    echo "Python version:"
    python3 --version 2>/dev/null || echo "Python3 not active"
    echo "-----------------------"
}

# Failure Handler: Captures failure line and prints logs
failure_handler() {
    echo ">>> [FATAL] Build failed at line $1"
    sys_status
    
    # Print Asterisk config logs
    if [ -f "config.log" ]; then
        echo ">>> [DEBUG] Last 100 lines of Asterisk config.log:"
        tail -n 100 config.log
    fi
    
    # Print PJProject config logs
    if [ -f "third-party/pjproject/source/config.log" ]; then
        echo ">>> [DEBUG] Last 100 lines of PJProject config.log:"
        tail -n 100 third-party/pjproject/source/config.log
    fi
    exit 1
}

# Activate TRAP now that we have the tools
trap 'failure_handler $LINENO' ERR

# --- 3. GLOBAL VARIABLES ---
ASTERISK_VER="$1"
[ -z "$ASTERISK_VER" ] && ASTERISK_VER="22-current"

BUILD_DIR="/usr/src/asterisk_build"
OUTPUT_DIR="/workspace"

# --- 4. MAIN BUILD PROCESS ---
echo ">>> [BUILDER] Starting build for version: $ASTERISK_VER"
sys_status

log_step() { echo -e "\n>>> [BUILDER] $1\n"; }

log_step "Installing full build dependencies..."
apt-get install -y -qq --no-install-recommends \
    build-essential libc6-dev linux-libc-dev gcc g++ \
    git curl wget subversion pkg-config \
    autoconf automake libtool binutils \
    bison flex xmlstarlet libxml2-utils \
    libncurses5-dev libncursesw5-dev libxml2-dev libsqlite3-dev \
    libssl-dev uuid-dev libjansson-dev libedit-dev libxslt1-dev \
    libicu-dev libsrtp2-dev libopus-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev libsystemd-dev

mkdir -p $BUILD_DIR
cd $BUILD_DIR

log_step "Downloading Asterisk sources..."
wget -qO asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}.tar.gz"
tar -xzf asterisk.tar.gz --strip-components=1
rm asterisk.tar.gz

log_step "Downloading MP3 resources..."
contrib/scripts/get_mp3_source.sh

log_step "Configuring Asterisk..."
# --host: fixes Error 77 (cross-compile check) under QEMU
# --with-jansson: forces system library to avoid broken bundled build
# CFLAGS -O1: safe optimization to prevent compiler segfaults
./configure --libdir=/usr/lib \
    --host=aarch64-linux-gnu \
    --with-pjproject-bundled \
    --with-jansson \
    --without-x11 \
    --without-gtk2 \
    ac_cv_func_strtoq=yes \
    CFLAGS='-O1' \
    CXXFLAGS='-O1'

log_step "Cleaning third-party artifacts..."
make -C third-party/pjproject clean || true
rm -rf third-party/jansson/dist || true

log_step "Selecting modules (Menuselect)..."
make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts

log_step "Compiling (Single Core Mode)..."
sys_status
# Mandatory -j1 in QEMU to avoid memory corruption
make -j1

log_step "Creating installation structure..."
make install DESTDIR=$BUILD_DIR/staging
make samples DESTDIR=$BUILD_DIR/staging
make config DESTDIR=$BUILD_DIR/staging

log_step "Final packaging..."
sys_status
cd $BUILD_DIR/staging
TAR_NAME="asterisk-${ASTERISK_VER}-arm64-debian12.tar.gz"
du -sh .
tar -czvf "$OUTPUT_DIR/$TAR_NAME" .

echo ">>> [BUILDER] Success! Artifact created: $TAR_NAME"
