import 'vars.just'

set default-list := true

output_dir := f"{{justfile_dir()}}/.output"
container_file := f"{{output_dir}}/Containerfile"
recipe_file := f"{{justfile_dir()}}/recipes/recipe.yml"

_init_output_dir:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p {{output_dir}}

_validate_container_exists:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! podman image exists localhost/{{image_name}}:latest; then
        echo "ERROR: Container image 'localhost/{{image_name}}:latest' not found." \
             "Build it with 'just build-container'."
        exit 1
    fi

_validate_image_exists:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ ! -f "{{output_dir}}/{{image_name}}.qcow2" ]]; then
        echo "ERROR: qcow2 image {{output_dir}}/{{image_name}}.qcow2 not found." \
             "Build it with 'just build-qcow2'."
        exit 1
    fi

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

    for pkg in podman libvirt virt-install; do
        if grep -q '^ID=fedora' /etc/os-release >/dev/null 2>&1; then
            sudo dnf install $pkg
        elif grep -q '^ID=ubuntu' /etc/os-release >/dev/null 2>&1; then
            sudo apt install $pkg
        else
            echo "ERROR: Only Fedora and Ubuntu are supported as build environments."
            exit 1
        fi
    done
    echo "All dependencies installed."

# Generate raw Containerfile from BlueBuild template recipes.
[group('container')]
gen-containerfile: _init_output_dir
    #!/usr/bin/env bash
    set -euo pipefail

    podman run \
        --privileged \
        --rm \
        --entrypoint bluebuild \
        -v "{{output_dir}}/bluebuild-storage:/var/lib/containers/storage" \
        -v "{{justfile_dir()}}:/build" \
        -w /build \
        {{bluebuild_image}} \
        generate \
        -o /build/.output/Containerfile \
        /build/recipes/recipe.yml

# Build bootc compatible container image from BlueBuild template recipes.
[group('container')]
build-container: _init_output_dir
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p {{output_dir}}/bluebuild-storage
    rm -f "{{output_dir}}/{{image_name}}-image.tar"

    podman run \
        --privileged \
        --rm \
        --entrypoint /bin/sh \
        -v "{{output_dir}}/bluebuild-storage:/var/lib/containers/storage" \
        -v "{{justfile_dir()}}:/build" \
        -w /build \
        {{bluebuild_image}} \
        -ec 'bluebuild build --build-driver podman --run-driver podman /build/recipes/recipe.yml &&
            podman save -o /build/.output/{{image_name}}-image.tar localhost/{{image_name}}:latest'

    podman load -i "{{output_dir}}/{{image_name}}-image.tar"

# Run bootc container image interactively.
[group('container')]
run-container: _validate_container_exists
    #!/usr/bin/env bash
    set -euo pipefail

    podman run -it localhost/{{image_name}}:latest /bin/bash

# Build a qcow2 image from the container image.
[group('vm')]
build-qcow2: _init_output_dir _validate_container_exists
    #!/usr/bin/env bash
    set -euo pipefail

    # image-builder container needs to be run as root, non-root image storage DB
    # conflicts with root one when mounted inside image-builder image.
    podman image scp \
        "$USER@localhost::localhost/{{image_name}}:latest" \
        "root@localhost::localhost/{{image_name}}:latest"

    # Rootless builds are supported by image-builder via `--in-vm` flag, but
    # currently fail on Fedora hosts enforcing SELinux.
    #
    # Separate build image is required since image-builder defaults to using
    # target image as the build container. Secureblue's container policy rejects
    # transport layer of type 'containers-storage' entirely, which prevents the
    # build container from loading target image as an overlay.
    sudo podman run \
        --privileged \
        --rm \
        -v "{{output_dir}}:/output" \
        -v "/var/lib/containers/storage:/var/lib/containers/storage" \
        {{osbuild_image}} \
        build \
        --bootc-ref "localhost/{{image_name}}:latest" \
        --bootc-build-ref "{{build_image}}" \
        --bootc-default-fs btrfs \
        --output-dir "/output" \
        --output-name "{{image_name}}.qcow2" \
        qcow2

    sudo chown -R $USER:$USER {{output_dir}}

# Boot a qcow2 image in a QEMU VM.
[group('vm')]
create-vm: _validate_image_exists
    #!/usr/bin/env bash
    set -euo pipefail

    virt-install \
        --connect="qemu:///session" \
        --name "{{image_name}}" \
        --os-variant "generic" \
        --vcpus "4" \
        --memory "4096" \
        --disk "size=20,backing_store={{output_dir}}/{{image_name}}.qcow2" \
        --network default \
        --import \
        --graphics spice \
        --autoconsole graphical

# Show virsh commands used in VM lifecycle.
[group('vm')]
vm-commands:
    #!/usr/bin/env bash
    set -euo pipefail

    cat << EOF
    virsh list          - Show available VMs
    virsh start <vm>    - Boot target VM.
    virsh shutdown <vm> - Gracefully shutdown target VM.
    virsh destroy <vm>  - Hard shutdown target VM.
    virsh reboot <vm>   - Gracefully reboot target VM.
    virsh reset <vm>    - Hard reboot target VM.
    virsh suspend <vm>  - Pause active VM without releasing its RAM state.
    virsh resume <vm>   - Unpause target suspended VM.
    virsh undefine <vm> - Destroy VM definition and release it from namespace.
    virt-viewer <vm>    - Connect to graphical session for running target VM.
    EOF
