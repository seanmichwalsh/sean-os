set default-list := true

output_dir := f"{{justfile_dir()}}/.output"
container_file := f"{{output_dir}}/Containerfile"
recipe_file := f"{{justfile_dir()}}/recipes/recipe.yml"

image_name := "sean-os"
build_image := "quay.io/fedora/fedora-bootc:44"

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

    for pkg in podman image-builder; do
        if ! command -v $pkg >/dev/null 2>&1; then
            echo "Installing RPM package $pkg..."
            sudo dnf install $pkg
        fi
    done
    if ! (cargo install --list | grep blue-build >/dev/null 2>&1); then
        echo "Installing cargo crate blue-build..."
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

# Run bootc container image interactively.
[group('container')]
run-container:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! podman image exists localhost/{{image_name}}:latest; then
        echo "ERROR: Image 'localhost/{{image_name}}:latest' not found." \
             "Build it with 'just build-container'."
        exit 1
    fi
    podman run -it localhost/{{image_name}}:latest /bin/bash

# Build a qcow2 image from the container image.
[group('vm')]
build-qcow2:
    #!/usr/bin/env bash
    set -euo pipefail

    $(just _init_output_dir)

    # Rootless builds are supported by image-builder via `--in-vm` flag, but
    # currently fail on Fedora hosts enforcing SELinux.
    #
    # Separate build image is required since image-builder defaults to using
    # target image as the build container. Secureblue's container policy rejects
    # transport layer of type 'containers-storage' entirely, which prevents the
    # build container from loading target image as an overlay.
    sudo image-builder build \
        --bootc-build-ref {{build_image}} \
        --bootc-ref localhost/{{image_name}}:latest \
        --bootc-default-fs btrfs \
        --output-name "{{image_name}}.qcow2" \
        --output-dir {{output_dir}} \
        qcow2

    sudo chown -R $USER:$USER {{output_dir}}
