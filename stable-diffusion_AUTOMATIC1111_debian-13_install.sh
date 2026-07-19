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
#   bash SD-Automatic1111_install_D13.sh
#
# What this script does:
#   1. Verifies the NVIDIA driver is present
#   2. Redirects TMPDIR/pip cache to disk (important on low-RAM systems,
#      so pip/torch downloads and build artifacts don't fill up RAM)
#   3. Installs required system packages (build tools, git, etc.)
#   4. Installs pyenv (if not already present)
#   5. Builds Python 3.11.11 via pyenv, side by side with the system Python
#      (Debian 13 ships Python 3.13 by default, which is too new for
#      AUTOMATIC1111's pinned dependencies such as torch==2.1.2)
#   6. Clones AUTOMATIC1111/stable-diffusion-webui
#   7. Writes webui-user.sh with the pyenv Python path, sane launch args,
#      and a working fork for the Stable Diffusion base repo (the original
#      Stability-AI/stablediffusion repo was removed from public GitHub)
#   8. Proactively creates the venv and installs torch/torchvision and CLIP
#      manually, BEFORE the first webui.sh run. This sidesteps a known,
#      reproducible failure: AUTOMATIC1111's own installer runs "pip install"
#      for CLIP inside an isolated build environment, where the old CLIP
#      package (2021) fails to build because pkg_resources is missing from
#      modern setuptools. AUTOMATIC1111 only re-attempts this if it can't
#      detect an existing "clip" installation (is_installed() check in
#      launch_utils.py), so installing it manually first makes the official
#      launcher skip that fragile step entirely.
#   9. Runs webui.sh, which will now install only the remaining, unproblematic
#      requirements and start the web UI on http://127.0.0.1:7860
#
# Author: Speefak
#
# ==============================================================================

set -euo pipefail

PYTHON_VERSION="3.11.11"
REPO_DIR="$HOME/stable-diffusion-webui"
PYENV_ROOT="$HOME/.pyenv"
PYENV_PYTHON="$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python3.11"
CLIP_PACKAGE_URL="https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip"
STABLE_DIFFUSION_FORK="https://github.com/w-e-w/stablediffusion.git"

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
check_nvidia_driver() {
    section "Step 0: Checking NVIDIA driver"

    if ! command -v nvidia-smi &>/dev/null; then
        echo "ERROR: nvidia-smi not found. Install the NVIDIA driver first."
        exit 1
    fi

    echo "-> NVIDIA driver found:"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
}

# ------------------------------------------------------------------
# Step 1: Redirect TMPDIR/pip cache to disk
# ------------------------------------------------------------------
# NOTE: On low-RAM systems, pip's temporary build/download files can end up
# on a RAM-backed /tmp (tmpfs) and exhaust memory during the torch/CLIP
# install. Setting TMPDIR to a directory on disk avoids that, since pip and
# most Python build tools respect this environment variable.
setup_tmpdir_on_disk() {
    section "Step 1: Redirecting TMPDIR/pip cache to disk (RAM protection)"

    mkdir -p "$HOME/tmp" "$HOME/pip_cache"
    export TMPDIR="$HOME/tmp"
    export PIP_CACHE_DIR="$HOME/pip_cache"

    if ! grep -q "export TMPDIR=" "$HOME/.bashrc" 2>/dev/null; then
        echo "export TMPDIR=$HOME/tmp" >> "$HOME/.bashrc"
    fi
    if ! grep -q "export PIP_CACHE_DIR=" "$HOME/.bashrc" 2>/dev/null; then
        echo "export PIP_CACHE_DIR=$HOME/pip_cache" >> "$HOME/.bashrc"
    fi

    echo "-> TMPDIR=$TMPDIR"
    echo "-> PIP_CACHE_DIR=$PIP_CACHE_DIR"
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
    section "Step 3: Installing pyenv"

    export PYENV_ROOT

    if [ ! -d "$PYENV_ROOT" ]; then
        echo "-> Installing pyenv..."
        curl https://pyenv.run | bash
    else
        echo "-> pyenv already installed, skipping."
    fi

    if ! grep -q "PYENV_ROOT" "$HOME/.bashrc" 2>/dev/null; then
        {
            echo 'export PYENV_ROOT="$HOME/.pyenv"'
            echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
            echo 'eval "$(pyenv init -)"'
        } >> "$HOME/.bashrc"
    fi

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
# Step 8: Launch webui.sh
# ------------------------------------------------------------------
# NOTE: venv/torch/CLIP already exist at this point, so AUTOMATIC1111 will
# skip those steps and only install the remaining, unproblematic
# requirements before starting the web UI.
launch_webui() {
    section "Step 8: Launching webui.sh (venv/torch/CLIP already prepared)"

    ./webui.sh
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
    section "AUTOMATIC1111 installation on Debian 13 (pyenv / Python $PYTHON_VERSION)"

    check_nvidia_driver
    setup_tmpdir_on_disk
    install_system_packages
    install_pyenv
    install_python_via_pyenv
    clone_repository
    write_webui_user_config
    setup_venv_torch_clip
    launch_webui
}

main "$@"
