FROM localhost/sean-os-unsealed as rootfs

RUN << EORUN
set -euo pipefail
export KERNEL_VERSION=$(cd "/usr/lib/modules" && echo *)
mv "/usr/lib/modules/$KERNEL_VERSION/vmlinuz" "/vmlinuz"
EORUN

FROM scratch
COPY --from=rootfs /vmlinuz /vmlinuz
