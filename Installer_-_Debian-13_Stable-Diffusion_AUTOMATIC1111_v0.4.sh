#!/usr/bin/env bash
#
# ==============================================================================
# Install script: Stable Diffusion AUTOMATIC1111 on Debian 13 (netinstall)
#                 using pyenv / Python 3.11.11
# ==============================================================================
#
# Prerequisites:
#   - NVIDIA driver already installed (nvidia-smi must work)
#   - sudo privileges (apt install steps require it)
#
# Usage:
#   bash Installer_-_Debian-13_Stable-Diffusion_AUTOMATIC1111_v0.4.sh
#
# What this script does:
#   1. Verifies the NVIDIA driver is present. If not, warns the user and
#      waits up to 10 seconds for an explicit confirmation to continue
#      anyway (CPU-only); aborts on timeout, no input, or a non-"y" answer.
#   2. Asks whether pyenv/Python should be installed system-wide (/opt/pyenv,
#      readable by all users) or per-user ($HOME/.pyenv) - important if the
#      WebUI might later be run under a different Linux user
#   3. Checks available RAM; only if it's below 8 GB does it ask (10s
#      timeout, defaults to yes) whether to redirect TMPDIR/pip cache to
#      /var/tmp, so pip/torch downloads and build artifacts don't fill up
#      RAM on a tmpfs-backed /tmp. Skipped entirely on systems with 8 GB+
#      RAM available.
#   4. Asks (10s timeout, defaults to yes) whether the systemd service
#      (set up later) should be enabled for automatic start on boot
#   4. Installs required system packages (build tools, git, etc.)
#   5. Installs pyenv (if not already present), in the chosen scope
#   6. Builds Python 3.11.11 via pyenv, side by side with the system Python
#      (Debian 13 ships Python 3.13 by default, which is too new for
#      AUTOMATIC1111's pinned dependencies such as torch==2.1.2)
#   7. Clones AUTOMATIC1111/stable-diffusion-webui
#   8. Writes webui-user.sh with the pyenv Python path, sane launch args,
#      and a working fork for the Stable Diffusion base repo (the original
#      Stability-AI/stablediffusion repo was removed from public GitHub)
#   9. Proactively creates the venv and installs torch/torchvision and CLIP
#      manually, BEFORE the first webui.sh run. This sidesteps a known,
#      reproducible failure: AUTOMATIC1111's own installer runs "pip install"
#      for CLIP inside an isolated build environment, where the old CLIP
#      package (2021) fails to build because pkg_resources is missing from
#      modern setuptools. AUTOMATIC1111 only re-attempts this if it can't
#      detect an existing "clip" installation (is_installed() check in
#      launch_utils.py), so installing it manually first makes the official
#      launcher skip that fragile step entirely.
#   10. Writes a systemd unit file (stable-diffusion-webui.service) so the
#       WebUI can be started/stopped/enabled via systemctl afterwards,
#       instead of running this script or webui.sh manually every time
#   11. Runs webui.sh once in the foreground, which will now install only
#       the remaining, unproblematic requirements and start the web UI on
#       http://127.0.0.1:7860 - use the systemd service for all later starts
#
# Author: Speefak
#
# ==============================================================================

set -euo pipefail

PYTHON_VERSION="3.11.11"
REPO_DIR="$HOME/stable-diffusion-webui"
CLIP_PACKAGE_URL="https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip"
STABLE_DIFFUSION_FORK="https://github.com/w-e-w/stablediffusion.git"

# PYENV_ROOT and PYENV_PYTHON are set later by ask_pyenv_scope(), depending
# on whether the user chooses a system-wide or a per-user pyenv install.
PYENV_ROOT=""
PYENV_PYTHON=""
PYENV_SYSTEM_WIDE=false

# Set by check_nvidia_driver(): whether an NVIDIA driver was detected, or
# the user explicitly confirmed to continue without one.
NVIDIA_AVAILABLE=true

# Set by ask_systemd_autostart(): whether the systemd service should be
# enabled for automatic start on boot.
ENABLE_SYSTEMD_AUTOSTART=true

# ------------------------------------------------------------------
# Helper: section header
# ------------------------------------------------------------------
section() {
    echo ""
    echo "=================================================================="
    echo " $1"
    echo "=================================================================="
}

# ------------------------------------------------------------------
# Step 0: Check NVIDIA driver
# ------------------------------------------------------------------
# NOTE: If no NVIDIA driver is found, the script no longer aborts
# immediately. Instead it warns the user and waits up to 10 seconds for an
# explicit confirmation to continue anyway (CPU-only, drastically slower).
# No input, a timeout, or anything other than an explicit "y" aborts the
# script - this is a safety default, not an assumption that CPU-only is fine.
check_nvidia_driver() {
    section "Step 0: Checking NVIDIA driver"

    if ! command -v nvidia-smi &>/dev/null; then
        echo "WARNING: nvidia-smi not found - no NVIDIA driver detected."
        echo "AUTOMATIC1111 would run CPU-only, which is drastically slower"
        echo "and not what this script's torch/CUDA setup (cu121 wheels) is"
        echo "designed for."
        echo ""

        local confirm=""
        if ! read -r -t 10 -p "Continue anyway without an NVIDIA driver? [y/N] (10s timeout): " confirm; then
            echo ""
            echo "No input received within 10 seconds. Aborting."
            exit 1
        fi

        if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            echo "Aborting. Install the NVIDIA driver first, then re-run this script."
            exit 1
        fi

        echo "-> Continuing without an NVIDIA driver, as confirmed by the user."
        NVIDIA_AVAILABLE=false
    else
        echo "-> NVIDIA driver found:"
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
        NVIDIA_AVAILABLE=true
    fi
}

# ------------------------------------------------------------------
# Step 0b: Ask whether pyenv should be installed system-wide or per-user
# ------------------------------------------------------------------
# NOTE: A per-user pyenv install lives under $HOME/.pyenv. If webui-user.sh
# hardcodes that path and the WebUI is later run as a different Linux user,
# the python_cmd path no longer exists for that user and the WebUI breaks.
# A system-wide install under /opt/pyenv, readable by all users, avoids that
# problem - at the cost of requiring sudo/root for the pyenv install itself.
ask_pyenv_scope() {
    section "Step 0b: Choosing pyenv installation scope"

    echo "Where should pyenv (and Python $PYTHON_VERSION) be installed?"
    echo ""
    echo "  [1] System-wide (/opt/pyenv, readable by all users, requires sudo)"
    echo "      Recommended if the WebUI might later be run under a"
    echo "      different Linux user than the one running this script."
    echo "  [2] User-space (\$HOME/.pyenv, only for the current user: $USER)"
    echo "      Simpler, no system-wide changes, but python_cmd in"
    echo "      webui-user.sh will only work for this user."
    echo ""

    local choice=""
    while [[ "$choice" != "1" && "$choice" != "2" ]]; do
        read -r -p "Enter 1 or 2: " choice
    done

    if [ "$choice" = "1" ]; then
        PYENV_SYSTEM_WIDE=true
        PYENV_ROOT="/opt/pyenv"
        echo "-> Selected: system-wide install at $PYENV_ROOT"
    else
        PYENV_SYSTEM_WIDE=false
        PYENV_ROOT="$HOME/.pyenv"
        echo "-> Selected: user-space install at $PYENV_ROOT"
    fi

    PYENV_PYTHON="$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python3.11"
}

# ------------------------------------------------------------------
# Step 1: Redirect TMPDIR/pip cache to disk (only if RAM is low)
# ------------------------------------------------------------------
# NOTE: On low-RAM systems, pip's temporary build/download files can end up
# on a RAM-backed /tmp (tmpfs) and exhaust memory during the torch/CLIP
# install. Systems with 8 GB RAM or more don't need this redirect. Below
# that threshold, the script asks for confirmation (10s timeout, defaults
# to yes - unlike the NVIDIA prompt, doing the redirect is the safe
# default here, not skipping it).
setup_tmpdir_on_disk() {
    section "Step 1: Checking whether a TMPDIR redirect is needed"

    local mem_available_mb
    # LC_ALL=C forces free's row label to stay "Mem:" regardless of the
    # system locale (e.g. German locales show "Speicher:" instead, which
    # would silently break the awk pattern match below).
    mem_available_mb=$(LC_ALL=C free -m | awk '/^Mem:/ {val=$7; if (val=="") val=$4; print val}')

    if ! [[ "$mem_available_mb" =~ ^[0-9]+$ ]]; then
        echo "-> Could not reliably determine available RAM from 'free -m'."
        echo "   Assuming a low-RAM system to be safe."
        mem_available_mb=0
    fi

    if [ "$mem_available_mb" -ge 8192 ]; then
        echo "-> $mem_available_mb MB RAM available (>= 8 GB) - no TMPDIR redirect needed."
        return
    fi

    echo "-> Only $mem_available_mb MB RAM available (< 8 GB)."
    echo "pip/torch build and download files could end up on a RAM-backed"
    echo "/tmp (tmpfs) and exhaust memory during installation."
    echo ""

    local confirm=""
    if ! read -r -t 10 -p "Redirect TMPDIR/pip cache to /var/tmp? [Y/n] (10s timeout, defaults to yes): " confirm; then
        echo ""
        echo "No input received within 10 seconds - proceeding with the redirect (default)."
        confirm="y"
    fi

    if [[ "$confirm" =~ ^[Nn]([Oo])?$ ]]; then
        echo "-> Skipping TMPDIR redirect, as confirmed by the user."
        return
    fi

    local pip_cache_dir="/var/tmp/sd-webui-pip-cache-$USER"
    mkdir -p "$pip_cache_dir"

    export TMPDIR="/var/tmp"
    export PIP_CACHE_DIR="$pip_cache_dir"

    if ! grep -q "export TMPDIR=" "$HOME/.bashrc" 2>/dev/null; then
        echo "export TMPDIR=/var/tmp" >> "$HOME/.bashrc"
    fi
    if ! grep -q "export PIP_CACHE_DIR=" "$HOME/.bashrc" 2>/dev/null; then
        echo "export PIP_CACHE_DIR=$pip_cache_dir" >> "$HOME/.bashrc"
    fi

    echo "-> TMPDIR=$TMPDIR"
    echo "-> PIP_CACHE_DIR=$PIP_CACHE_DIR"
}

# ------------------------------------------------------------------
# Step 1b: Ask whether the systemd service should auto-start on boot
# ------------------------------------------------------------------
# NOTE: Asked here (right after the TMPDIR decision) so all prompts happen
# early, before the longer unattended install steps run. The actual
# "systemctl enable" call happens later in write_systemd_unit(), once the
# service file has been installed - this function only records the choice.
ask_systemd_autostart() {
    section "Step 1b: Enable systemd autostart on boot?"

    echo "The WebUI will be set up as a systemd service (see later step)."
    echo ""

    local confirm=""
    if ! read -r -t 10 -p "Enable it to start automatically on boot? [Y/n] (10s timeout, defaults to yes): " confirm; then
        echo ""
        echo "No input received within 10 seconds - enabling autostart (default)."
        confirm="y"
    fi

    if [[ "$confirm" =~ ^[Nn]([Oo])?$ ]]; then
        ENABLE_SYSTEMD_AUTOSTART=false
        echo "-> Autostart on boot will NOT be enabled. Start manually via:"
        echo "   sudo systemctl start stable-diffusion-webui"
    else
        ENABLE_SYSTEMD_AUTOSTART=true
        echo "-> Autostart on boot will be enabled."
    fi
}

# ------------------------------------------------------------------
# Step 2: Install system packages
# ------------------------------------------------------------------
install_system_packages() {
    section "Step 2: Installing system packages"

    sudo apt update
    sudo apt install -y \
        git python3 python3-venv python3-full python3-pip wget \
        libgl1 libglib2.0-0 google-perftools bc \
        make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev curl llvm \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
        libffi-dev liblzma-dev
}

# ------------------------------------------------------------------
# Step 3: Install pyenv
# ------------------------------------------------------------------
install_pyenv() {
    section "Step 3: Installing pyenv ($([ "$PYENV_SYSTEM_WIDE" = true ] && echo "system-wide at $PYENV_ROOT" || echo "user-space at $PYENV_ROOT"))"

    if [ "$PYENV_SYSTEM_WIDE" = true ]; then
        # System-wide install: clone pyenv into /opt/pyenv (requires sudo),
        # make it readable/executable for all users, and expose it via
        # /etc/profile.d so every user's login shell picks it up.
        if [ ! -d "$PYENV_ROOT" ]; then
            echo "-> Cloning pyenv into $PYENV_ROOT (system-wide)..."
            sudo git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
        else
            echo "-> pyenv already present at $PYENV_ROOT, skipping."
        fi

        # Temporarily own it as the current user so "pyenv install" (step 4)
        # can write new Python versions/build caches. Read/execute access
        # for all other users is restored below via chmod o+rX.
        sudo chown -R "$USER":"$USER" "$PYENV_ROOT"
        sudo chmod -R o+rX "$PYENV_ROOT"

        if [ ! -f /etc/profile.d/pyenv.sh ]; then
            echo "-> Writing /etc/profile.d/pyenv.sh (system-wide environment)..."
            sudo tee /etc/profile.d/pyenv.sh > /dev/null <<EOF
export PYENV_ROOT="$PYENV_ROOT"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
EOF
            sudo chmod +x /etc/profile.d/pyenv.sh
        else
            echo "-> /etc/profile.d/pyenv.sh already exists, skipping."
        fi
    else
        # User-space install: standard pyenv-installer into $HOME/.pyenv.
        if [ ! -d "$PYENV_ROOT" ]; then
            echo "-> Installing pyenv into $PYENV_ROOT..."
            curl https://pyenv.run | bash
        else
            echo "-> pyenv already installed at $PYENV_ROOT, skipping."
        fi

        if ! grep -q "PYENV_ROOT" "$HOME/.bashrc" 2>/dev/null; then
            {
                echo 'export PYENV_ROOT="$HOME/.pyenv"'
                echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
                echo 'eval "$(pyenv init -)"'
            } >> "$HOME/.bashrc"
        fi
    fi

    # Make pyenv available in the current shell session, regardless of scope
    export PYENV_ROOT
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
}

# ------------------------------------------------------------------
# Step 4: Install Python 3.11.11 via pyenv
# ------------------------------------------------------------------
# NOTE: Debian 13 ships Python 3.13 by default. AUTOMATIC1111's pinned
# dependencies (torch==2.1.2, Pillow==9.5.0, tokenizers, CLIP, ...) don't
# have prebuilt wheels for Python 3.13, which leads to a long chain of
# build failures (missing Rust compiler, missing pkg_resources, missing
# avif.h headers, version conflicts). Installing Python 3.11.11 via pyenv,
# side by side with the system Python, avoids all of that.
install_python_via_pyenv() {
    section "Step 4: Installing Python $PYTHON_VERSION via pyenv"

    if ! pyenv versions --bare | grep -qx "$PYTHON_VERSION"; then
        echo "-> Building Python $PYTHON_VERSION via pyenv (this can take a few minutes)..."
        pyenv install "$PYTHON_VERSION"
    else
        echo "-> Python $PYTHON_VERSION already available via pyenv, skipping."
    fi

    if [ "$PYENV_SYSTEM_WIDE" = true ]; then
        echo "-> Restoring read/execute access for all users on $PYENV_ROOT..."
        sudo chmod -R o+rX "$PYENV_ROOT"
    fi

    if [ ! -x "$PYENV_PYTHON" ]; then
        echo "ERROR: $PYENV_PYTHON not found. pyenv installation failed."
        exit 1
    fi

    echo "-> Python version confirmed: $("$PYENV_PYTHON" --version)"
}

# ------------------------------------------------------------------
# Step 5: Clone the repository
# ------------------------------------------------------------------
clone_repository() {
    section "Step 5: Cloning AUTOMATIC1111/stable-diffusion-webui"

    if [ ! -d "$REPO_DIR" ]; then
        echo "-> Cloning repository..."
        git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git "$REPO_DIR"
    else
        echo "-> Repository already exists at $REPO_DIR, skipping clone."
    fi

    cd "$REPO_DIR"
}

# ------------------------------------------------------------------
# Step 6: Write webui-user.sh
# ------------------------------------------------------------------
# NOTE on STABLE_DIFFUSION_REPO: the original Stability-AI/stablediffusion
# repository was removed/privatized from public GitHub (a confirmed, global
# issue affecting all fresh AUTOMATIC1111 installs since ~December 2025).
# Without overriding this variable, the clone step fails with a 401/login
# prompt. w-e-w/stablediffusion.git is the fork recommended by the
# AUTOMATIC1111 project itself (used on its "dev" branch) and is a drop-in
# replacement with identical content.
# NOTE on --listen --port 7860: binds the web UI to 0.0.0.0 instead of only
# 127.0.0.1, making it reachable from other devices on the LAN at
# http://<lan-ip>:7860. 7860 is AUTOMATIC1111's default port anyway, so
# --port is only needed here to make it explicit. --listen exposes the UI
# to the whole LAN without authentication; if the network isn't fully
# trusted, add --gradio-auth username:password to COMMANDLINE_ARGS as well.
write_webui_user_config() {
    section "Step 6: Writing webui-user.sh"

    cat > webui-user.sh <<EOF
#!/bin/bash
export python_cmd="$PYENV_PYTHON"
export COMMANDLINE_ARGS="--medvram --xformers --listen --port 7860"
export STABLE_DIFFUSION_REPO="$STABLE_DIFFUSION_FORK"
EOF

    echo "-> webui-user.sh written:"
    cat webui-user.sh
}

# ------------------------------------------------------------------
# Step 7: Proactively set up venv, torch and CLIP
# ------------------------------------------------------------------
# NOTE: AUTOMATIC1111 checks is_installed("clip") before attempting its own
# CLIP install. If we install torch and CLIP into the venv ourselves first,
# using --no-build-isolation for CLIP (which lets it use the setuptools
# version already present in the venv instead of pip's fresh, isolated build
# environment where pkg_resources is missing), the official launcher will
# detect CLIP as already installed and skip that fragile step entirely.
setup_venv_torch_clip() {
    section "Step 7: Setting up venv, torch and CLIP proactively"

    if [ ! -d venv ]; then
        "$PYENV_PYTHON" -m venv venv
    fi

    # shellcheck disable=SC1091
    source venv/bin/activate

    python -m pip install --upgrade pip

    echo "-> Installing torch/torchvision (cu121)..."
    pip install torch==2.1.2 torchvision==0.16.2 --extra-index-url https://download.pytorch.org/whl/cu121

    echo "-> Installing setuptools<81 + wheel (required for the CLIP build)..."
    pip install "setuptools<81" wheel

    echo "-> Installing CLIP (--no-build-isolation, avoids the pkg_resources error)..."
    pip install --no-build-isolation "$CLIP_PACKAGE_URL"

    echo "-> Pinning NumPy < 2 (torch 2.1.2 was compiled against NumPy 1.x)..."
    pip install "numpy<2"

    echo "-> Verifying torch/CLIP import..."
    python -c "import torch, clip; print('torch', torch.__version__); print('clip ok')"

    deactivate
}

# ------------------------------------------------------------------
# Step 8: Write a systemd unit file
# ------------------------------------------------------------------
# NOTE: Lets the WebUI be managed via systemctl (start/stop/enable/status)
# instead of running webui.sh manually every time. Written before the first
# launch, since all values it needs (REPO_DIR, USER, HOME, TMPDIR,
# PIP_CACHE_DIR) are already known at this point - no dependency on webui.sh
# having run yet. webui-user.sh itself still controls python_cmd,
# COMMANDLINE_ARGS and STABLE_DIFFUSION_REPO - the service just calls
# webui.sh, same as running it manually would.
write_systemd_unit() {
    section "Step 8: Writing systemd unit file"

    local service_name="stable-diffusion-webui"
    local service_file="/etc/systemd/system/${service_name}.service"
    local tmp_unit
    tmp_unit="$(mktemp)"

    cat > "$tmp_unit" <<EOF
[Unit]
Description=AUTOMATIC1111 Stable Diffusion WebUI
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$REPO_DIR
Environment=HOME=$HOME
EOF

    # TMPDIR/PIP_CACHE_DIR are only set if setup_tmpdir_on_disk() applied the
    # redirect (RAM < 8 GB and confirmed). Add them conditionally so the
    # unit file never ends up with an empty "Environment=" line.
    if [ -n "${TMPDIR:-}" ]; then
        echo "Environment=TMPDIR=$TMPDIR" >> "$tmp_unit"
    fi
    if [ -n "${PIP_CACHE_DIR:-}" ]; then
        echo "Environment=PIP_CACHE_DIR=$PIP_CACHE_DIR" >> "$tmp_unit"
    fi

    cat >> "$tmp_unit" <<EOF
ExecStart=$REPO_DIR/webui.sh

# Graceful stop: systemd sends SIGTERM by default, which Python/Gradio
# handle cleanly. TimeoutStopSec gives it time to shut down before SIGKILL.
KillSignal=SIGTERM
TimeoutStopSec=30

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo cp "$tmp_unit" "$service_file"
    rm -f "$tmp_unit"
    sudo systemctl daemon-reload

    echo "-> systemd unit written to $service_file"

    if [ "$ENABLE_SYSTEMD_AUTOSTART" = true ]; then
        sudo systemctl enable "$service_name"
        echo "-> Autostart on boot enabled."
    else
        echo "-> Autostart on boot NOT enabled (as chosen earlier)."
    fi

    echo ""
    echo "The WebUI can now be managed via systemctl, e.g.:"
    echo "  sudo systemctl start   $service_name"
    echo "  sudo systemctl stop    $service_name"
    echo "  sudo systemctl status  $service_name"
    echo "  sudo systemctl enable  $service_name   # start automatically on boot"
    echo "  journalctl -u $service_name -f          # follow logs"
    echo ""
    echo "For this first run, the script below still launches webui.sh"
    echo "directly in the foreground, so you can watch the initial setup"
    echo "and verify it completes successfully. Use the systemd service for"
    echo "all subsequent starts instead."
}

# ------------------------------------------------------------------
# Step 9: Launch webui.sh
# ------------------------------------------------------------------
# NOTE: venv/torch/CLIP already exist at this point, so AUTOMATIC1111 will
# skip those steps and only install the remaining, unproblematic
# requirements before starting the web UI.
launch_webui() {
    section "Step 9: Launching webui.sh (venv/torch/CLIP already prepared)"

    ./webui.sh
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
    section "AUTOMATIC1111 installation on Debian 13 (pyenv / Python $PYTHON_VERSION)"

    check_nvidia_driver
    ask_pyenv_scope
    setup_tmpdir_on_disk
    ask_systemd_autostart
    install_system_packages
    install_pyenv
    install_python_via_pyenv
    clone_repository
    write_webui_user_config
    setup_venv_torch_clip
    write_systemd_unit
    launch_webui
}

main "$@"
