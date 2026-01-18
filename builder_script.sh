#!/bin/bash

# ============================================================================
# SCRIPT DI BUILD AUTOMATIZZATO (Eseguito nel container ARM64)
# TARGET: Asterisk 22 LTS per Debian 12 (Bookworm)
# VERSIONE: Debug Enhanced v1.5 (Stabilizzata per QEMU)
# ============================================================================

# Interrompi l'esecuzione in caso di errore
set -e

# --- 1. UTILITY DI DEBUG ---

# Funzione per visualizzare lo stato del sistema (RAM, Disco, Python)
sys_status() {
    echo "--- [STATO DEBUG] ---"
    echo "Spazio Disco:"
    df -h / | tail -n 1
    
    echo "Utilizzo Memoria:"
    if command -v free >/dev/null 2>&1; then
        free -m
    else
        echo "Comando 'free' non trovato (procps mancante)"
    fi
    
    echo "Versione Python:"
    if command -v python3 >/dev/null 2>&1; then
        python3 --version
    else
        echo "Python3 non trovato"
    fi
    echo "----------------------"
}

# Gestore dei fallimenti: cattura la linea esatta dell'errore e stampa i log
failure_handler() {
    echo ">>> [FATALE] Build fallito alla riga $1"
    sys_status
    
    # Stampa i log di configurazione di Asterisk se esistono
    if [ -f "config.log" ]; then
        echo ">>> [DEBUG] Ultime 100 righe di Asterisk config.log:"
        tail -n 100 config.log
    fi
    
    # Stampa i log di PJProject (causa comune di fallimento)
    if [ -f "third-party/pjproject/source/config.log" ]; then
        echo ">>> [DEBUG] Ultime 100 righe di PJProject config.log:"
        tail -n 100 third-party/pjproject/source/config.log
    fi
    exit 1
}

# Attivazione del TRAP: chiama failure_handler su ogni errore
trap 'failure_handler $LINENO' ERR

# --- 2. VARIABILI GLOBALI ---
ASTERISK_VER="$1"
[ -z "$ASTERISK_VER" ] && ASTERISK_VER="22-current"

BUILD_DIR="/usr/src/asterisk_build"
OUTPUT_DIR="/workspace"
DEBIAN_FRONTEND=noninteractive

# --- 3. PROCESSO DI BUILD PRINCIPALE ---
echo ">>> [BUILDER] Avvio build per la versione: $ASTERISK_VER"
sys_status

log_step() { echo -e "\n>>> [BUILDER] $1\n"; }

log_step "Installazione dipendenze..."
apt-get update -qq
# Inclusi strumenti critici come bison, flex e procps
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
    python3 python3-dev python-is-python3 procps

mkdir -p $BUILD_DIR
cd $BUILD_DIR

log_step "Download sorgenti Asterisk..."
wget -qO asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}.tar.gz"
tar -xzf asterisk.tar.gz --strip-components=1
rm asterisk.tar.gz

log_step "Download risorse MP3..."
contrib/scripts/get_mp3_source.sh

log_step "Configurazione Asterisk..."
# --host: corregge l'errore 77 (cross-compile check) sotto QEMU
# --with-jansson: forza l'uso della libreria di sistema per evitare build bundled fallimentari
# CFLAGS -O1: ottimizzazione sicura per prevenire segfault del compilatore
./configure --libdir=/usr/lib \
    --host=aarch64-linux-gnu \
    --with-pjproject-bundled \
    --with-jansson \
    --without-x11 \
    --without-gtk2 \
    ac_cv_func_strtoq=yes \
    CFLAGS='-O1' \
    CXXFLAGS='-O1'

log_step "Pulizia artefatti third-party..."
make -C third-party/pjproject clean || true
rm -rf third-party/jansson/dist || true

log_step "Selezione moduli (Menuselect)..."
make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts

log_step "Compilazione (Modalità Single Core)..."
sys_status
# Obbligatorio -j1 in ambienti QEMU per evitare corruzioni di memoria
make -j1

log_step "Creazione struttura di installazione..."
make install DESTDIR=$BUILD_DIR/staging
make samples DESTDIR=$BUILD_DIR/staging
make config DESTDIR=$BUILD_DIR/staging

log_step "Packaging finale..."
sys_status
cd $BUILD_DIR/staging
TAR_NAME="asterisk-${ASTERISK_VER}-arm64-debian12.tar.gz"
du -sh .
tar -czvf "$OUTPUT_DIR/$TAR_NAME" .

echo ">>> [BUILDER] Successo! Artefatto creato: $TAR_NAME"
