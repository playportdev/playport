# SPDX-License-Identifier: GPL-3.0-or-later
# A Linux build host for Playport's tree stages on an Apple silicon Mac
# (build/docker/README.md): arm64 Ubuntu 24.04 with the host tools
# docs/BUILDING.md lists. The repository and the build area live on a Docker
# volume (case-sensitive ext4), never on the Mac's APFS bind mount.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release software-properties-common \
        build-essential gcc g++ make bison flex gettext cmake ninja-build meson pkg-config \
        python3 python3-pip python3-venv python3-pefile python3-mako python3-yaml python3-ply python3-packaging \
        xxd openssl libssl-dev patch git rsync p7zip-full xz-utils bzip2 zstd unzip zip file jq \
        zlib1g-dev libexpat1-dev libxml2-dev libelf-dev libzstd-dev uuid-dev libbsd-dev \
        spirv-tools glslang-tools autoconf automake libtool texinfo nasm procps \
        libdrm-dev python3-pycparser libvulkan-dev libunwind-dev \
    && rm -rf /var/lib/apt/lists/*

# Host LLVM 22.x as /usr/bin/clang etc. (the stages call /usr/bin/clang by path).
ARG LLVM=22
RUN wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh && bash /tmp/llvm.sh ${LLVM} all \
    && apt-get install -y --no-install-recommends libclc-${LLVM} libclc-${LLVM}-dev libpolly-${LLVM}-dev \
       libllvmlibc-${LLVM}-dev libclang-${LLVM}-dev libclang-cpp${LLVM}-dev llvm-${LLVM}-dev \
    && for t in clang clang++ clang-cpp ld.lld ld64.lld lld llvm-ar llvm-nm llvm-objdump llvm-objcopy llvm-lipo \
                llvm-ranlib llvm-strip llvm-readobj llvm-config llvm-as llvm-dis llvm-link llvm-otool llvm-install-name-tool \
                llvm-libtool-darwin llvm-dsymutil llvm-size llvm-readelf; do \
           [ -e /usr/bin/$t-${LLVM} ] && ln -sf /usr/bin/$t-${LLVM} /usr/bin/$t || true; \
       done \
    && rm -rf /var/lib/apt/lists/*

# Mesa's host shader tools need SPIRV-LLVM-Translator for the host LLVM; no
# package carries it for LLVM 22, so it is built against llvm-22-dev.
RUN git clone -q --depth 1 -b llvm_release_220 https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git /tmp/spirv \
    && cmake -S /tmp/spirv -B /tmp/spirv/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
       -DLLVM_DIR=/usr/lib/llvm-${LLVM}/lib/cmake/llvm -DLLVM_SPIRV_BUILD_EXTERNAL=YES -DLLVM_SPIRV_INCLUDE_TESTS=OFF \
       -DBUILD_SHARED_LIBS=ON -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    && ninja -C /tmp/spirv/build install && rm -rf /tmp/spirv

# Swift for Linux (the inputs check, and xtool if the app stage is ever run here),
# in /opt/swift so that its own clang does not replace /usr/bin/clang; the
# stages read its clang resource headers from /usr/lib/swift.
ARG SWIFT=6.2.1
RUN mkdir -p /opt/swift && curl -fsSL https://download.swift.org/swift-${SWIFT}-release/ubuntu2404-aarch64/swift-${SWIFT}-RELEASE/swift-${SWIFT}-RELEASE-ubuntu24.04-aarch64.tar.gz \
        | tar xz -C /opt/swift --strip-components=1 \
    && ln -s /opt/swift/usr/lib/swift /usr/lib/swift \
    && mkdir -p /opt/swift/usr/lib/swift/lib && ln -s /opt/swift/usr/lib/clang /opt/swift/usr/lib/swift/lib/clang \
    && for t in swift swiftc swift-build swift-package swift-frontend swift-driver; do ln -sf /opt/swift/usr/bin/$t /usr/local/bin/$t; done \
    && apt-get update && apt-get install -y --no-install-recommends libcurl4-openssl-dev libncurses-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Mesa needs Meson 1.4 or later; Ubuntu 24.04 has 1.3.
RUN pip3 install --break-system-packages "meson>=1.4,<2"

# Madeira's scripts call sysctl by its macOS path (build/stages/unix.sh shims).
RUN ln -sf /usr/sbin/sysctl /usr/bin/sysctl

WORKDIR /w
