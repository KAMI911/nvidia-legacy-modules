# nvidia-legacy-modules

Reproducible **prebuilt kernel-module** packages for the legacy NVIDIA drivers
on Debian & Ubuntu — one `.deb` per *(driver series × kernel ABI × arch)*, so
users install a matching module with **no compiler on the target**.

The source-on-device sibling is [`nvidia-legacy-dkms`](https://github.com/kami911/nvidia-legacy-dkms).
Shared templates/patches/tooling: [`nvidia-legacy-common`](https://github.com/kami911/nvidia-legacy-common) (`common/` submodule).

## What it produces (example, 390xx / Debian 13 / amd64)

```
nvidia-legacy-390xx-kernel-6.12.0-1-amd64      the .ko set for that exact ABI
nvidia-legacy-390xx-kernel-amd64               metapackage -> tracks the newest ABI
nvidia-legacy-390xx-driver, -driver-libs, ...  userspace (same as the dkms repo)
```

`nvidia-legacy-390xx-kernel-6.12.0-1-amd64` ships
`Provides: nvidia-legacy-390xx-kernel-6.12.0-1-amd64` so the metapackage and the
driver metapackage can depend on "a module for the running kernel".

## The kernel matrix

`tools/kernels.yaml` lists every ABI we build for, per target — Debian stock,
Ubuntu HWE, the Ubuntu **kernel PPA**, and kernel.org **mainline**.
`tools/gen-kernel-packages.py` turns it into one rendered source package per ABI
under `packaging/<series>/<target>/<abi>/`. `kernel-refresh.yml` re-runs it
weekly and opens a PR, so "every newer kernel that comes from the Ubuntu kernel
PPA" is covered automatically.

Because a full matrix is large, generation is incremental and each ABI builds
independently on OBS; a new ABI never blocks an existing one.

## Build locally

```sh
make submodule
make gen                                   # kernels.yaml -> packaging/**/<abi>/
make build SERIES=390xx TARGET=debian13 ABI=6.12.0-1-amd64
make test  SERIES=390xx TARGET=debian13 ABI=6.12.0-1-amd64
```

## Release gate

Same no-GPU gate as `nvidia-legacy-dkms` (static · build+reprotest · module
compile · autopkgtest · qemu module-load + Xorg ABI), evaluated per ABI. Only
green `(series, target, abi)` tuples get their OBS `publish` flag set.

## Security

Legacy EOL drivers — see [SECURITY.md](SECURITY.md). Same provenance and
reproducibility guarantees as the dkms repo.
