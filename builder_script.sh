#!/bin/bash

# ============================================================================
# AUTOMATED BUILD SCRIPT (Executed inside the ARM64 container)
# TARGET: Asterisk 22 LTS for Debian 12 (Bookworm)
# VERSION: Debug Enhanced v2.4 (Toolchain & AR Fix)
# ============================================================================

# --- 0. CRLF AUTO-FIX ---
if [ "$(printf '%s' "$0" | xxd -p | tail -c 4)" == "0d0a" ]; then
    echo ">>> [BUILDER] Windows line endings detected. Attempting self-fix..."
    sed -i 's/\r$//' "$0"
fi

# --- 1. BOOTSTRAP ENVQIRONMENT ---
echo ">>> [BUILDER] ENVIRONMENT INITIALIZATION - VERSION 2.4"
export DEBIAN_FRONTEND=noninteractive

# Force absolute paths for ARM64 toolchain
export AR=aarch64-linux-gnu-ar
export AS=aarch64-linux-gnu-as
export LD=aarch64-linux-gnu-ld
export RANLIB=aarch64-linux-gnu-ranlib
export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Enable strict mode
set -e

# --- 2. DEBUG UTILS ---

sys_status() {
    echo "--- [SYSTEM STATUS V2.4] ---"
    echo "Disk Space:"
    df -h / | tail -n 1
    echo "Memory Usage:"
    if command -v free >/dev/null 2>&1; then free -m; fi
    echo "----------------------------"
}

failure_handler() {
    echo ">>> [FATAL ERROR] Build failed at line $1"
    sys_status
    if [ -f "config.log" ]; then
        echo ">>> [DEBUG] Asterisk config.log tail:"
        tail -n 50 config.log
    fi
    if [ -f "third-party/pjproject/source/config.log" ]; then
        echo ">>> [DEBUG] PJProject config.log tail:"
        tail -n 50 third-party/pjproject/source/config.log
    fi
    exit 1
}

trap 'failure_handler $LINENO' ERR

# --- 3. GLOBAL VARIABLES ---
ASTERISK_VER="$1"
[ -z "$ASTERISK_VER" ] && ASTERISK_VER="22-current"
BUILD_DIR="/usr/src/asterisk_build"
OUTPUT_DIR="/workspace"

# --- 4. MAIN BUILD PROCESS ---
log_step() { echo -e "\n>>> [BUILDER] STEP: $1\n"; }

log_step "Installing core build dependencies..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential libc6-dev linux-libc-dev gcc g++ \
    git curl wget subversion pkg-config \
    autoconf automake libtool binutils \
    bison flex xmlstarlet libxml2-utils \
    libncurses5-dev libncursesw5-dev libxml2-dev libsqlite3-dev \
    libssl-dev uuid-dev libjansson-dev libedit-dev libxslt1-dev \
    libicu-dev libsrtp2-dev libopus-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev libsystemd-dev \
    libasound2-dev libpulse-dev \
    python3 python3-dev python-is-python3 procps ca-certificates gnupg

sys_status

mkdir -p $BUILD_DIR
cd $BUILD_DIR

log_step "Downloading Asterisk sources..."
wget --tries=3 --timeout=30 --no-check-certificate \
    -O asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}.tar.gz"
tar -xzf asterisk.tar.gz --strip-components=1
rm asterisk.tar.gz

log_step "Downloading MP3 resources..."
contrib/scripts/get_mp3_source.sh

log_step "Configuring Asterisk..."
# Added explicit AR and RANLIB to configure to avoid Error 2 in pjmedia
./configure --libdir=/usr/lib \
    --host=aarch64-linux-gnu \
    --with-pjproject-bundled \
    --with-jansson \
    --without-x11 \
    --without-gtk2 \
    ac_cv_func_strtoq=yes \
    AR=$AR \
    RANLIB=$RANLIB \
    CFLAGS='-O1' \
    CXXFLAGS='-O1'

log_step "Cleaning third-party artifacts..."
make -C third-party/pjproject clean || true

log_step "Selecting modules (Menuselect)..."
make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts

log_step "Compiling (Single Core Mode - V=1 NOISY_BUILD=yes)..."
sys_status
# V=1 and NOISY_BUILD=yes ensure full command visibility even for sub-projects
make -j1 V=1 NOISY_BUILD=yes

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
