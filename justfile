set default-list := true

output_dir := f"{{justfile_dir()}}/.output"
container_file := f"{{output_dir}}/Containerfile"
recipe_file := f"{{justfile_dir()}}/recipes/recipe.yml"

_init_output_dir:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p {{output_dir}}

# Remove build directory and output files.
[group('environment')]
clean:
    #!/usr/bin/env bash
    set -euo pipefail

    rm -rf {{output_dir}}

# Install CLI tools required by build recipes.
[group('environment')]
install-deps:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f /etc/os-release ] || ! grep -q '^ID=fedora' /etc/os-release; then
        echo "ERROR: Build host is expected to be Fedora Linux."
        exit 1
    fi
    if (! command -v rustc || ! command -v cargo) >/dev/null 2>&1; then
        echo "ERROR: Rust toolchain and cargo must be present."
        exit 1
    fi

    if ! command -v podman >/dev/null 2>&1; then
        echo "Installing podman..."
        sudo dnf install podman
    fi
    if ! (cargo install --list | grep blue-build >/dev/null 2>&1); then
        echo "Installing blue-build..."
        cargo install blue-build
    fi
    echo "All dependencies installed."

# Generate raw Containerfile from BlueBuild template recipes.
[group('container')]
gen-containerfile:
    #!/usr/bin/env bash
    set -euo pipefail

    $(just _init_output_dir)
    bluebuild generate -o {{container_file}} {{recipe_file}}

# Build bootc compatible container image from BlueBuild template recipes.
[group('container')]
build-container:
    #!/usr/bin/env bash
    set -euo pipefail

    $(just _init_output_dir)
    bluebuild build \
        --build-driver podman \
        --run-driver podman \
        --tempdir {{output_dir}} \
        {{recipe_file}}
