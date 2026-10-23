#!/bin/bash

set -euo pipefail

# Define colors for terminal output
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Define Android NDK version and download URL
ndkdir="android-ndk-r30"
ndkver="https://dl.google.com/android/repository/${ndkdir}-linux.zip"
sdkver="35"

# Define Mesa version and download URL
mesa_ver="26.2.3"
mesadir="mesa-mesa-${mesa_ver}"
mesaver="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-${mesa_ver}/mesa-mesa-${mesa_ver}.zip?ref_type=tags"

# Define working directories
workdir="$(pwd)/turnip_workdir"         # Base directory for all operations

# Download an archive unless a cached copy passes an integrity check.
# The archive is only moved into place once it is complete, so an interrupted
# download is never reused as a valid cache entry.
fetch_archive() {
    local url="$1" dest="$2" label="$3"

    if [ -f "$dest" ] && unzip -tq "$dest" &> /dev/null; then
        echo -e "$green - Found $dest, skipping $label download. $nocolor" $'\n'
        return 0
    fi

    echo "Downloading $label..." $'\n'
    curl -sSL --fail "$url" --output "$dest.part"

    if ! unzip -tq "$dest.part" &> /dev/null; then
        rm -f "$dest.part"
        echo -e "$red Downloaded archive failed validation: $dest $nocolor"
        exit 1
    fi

    mv "$dest.part" "$dest"
}

# List of required packages to build the Turnip driver
deps="meson ninja patchelf unzip curl flex bison clang ccache pkg-config patch"
[ -t 1 ] && clear || true

echo "Checking system for required dependencies..."

# Check for required dependencies 
for deps_chk in $deps; do

    [ -t 1 ] && sleep 0.25 || true
    if command -v "$deps_chk" >/dev/null 2>&1; then
        if [ "$deps_chk" = "meson" ]; then
            meson_ver=$(meson --version 2>/dev/null || echo "0")
            if [ "$(printf '%s\n' "1.4.0" "$meson_ver" | sort -V | head -n1)" != "1.4.0" ]; then
                echo -e "$red - meson found ($meson_ver), but >= 1.4.0 is required. Upgrade with: pip3 install --upgrade --break-system-packages meson $nocolor"
                deps_missing=1
            else
                echo -e "$green - meson found ($meson_ver) $nocolor"
            fi
        else
            echo -e "$green - $deps_chk found $nocolor"
        fi
    else
        echo -e "$red - $deps_chk not found, cannot continue. $nocolor"
        deps_missing=1
    fi
done

if [ "${deps_missing:-0}" = "1" ]; then
    echo -e "$red Missing or outdated dependencies. Please install them and try again. $nocolor"
    exit 1
fi

[ -t 1 ] && sleep 0.25 || true
[ -t 1 ] && clear || true

# Ensure work directory exists and enter it
echo "Ensuring work directory exists: $workdir" $'\n'
mkdir -p "$workdir"
cd "$workdir" || exit 1

# Clean only build artifacts, keeping downloaded source archives
echo "Cleaning previous build artifacts (if any)..." $'\n'
rm -rf "$ndkdir" "$mesadir" "fake-cc" \
       "libvulkan_freedreno.so" "vulkan.adreno.so" \
       "arm64-v8a" "armeabi-v7a" \
       "meson_log" "ninja_log" "meson_log-"* "ninja_log-"* \
       "cross-"*.txt "native.txt" \
       "${ndkdir}.zip.part" "${mesadir}.zip.part"

# Download Android NDK
fetch_archive "$ndkver" "${ndkdir}.zip" "Android NDK"

[ -t 1 ] && clear || true

echo "Extracting Android NDK..." $'\n'
unzip "$ndkdir".zip &> /dev/null

# Download Mesa source
fetch_archive "$mesaver" "${mesadir}.zip" "Mesa source"

[ -t 1 ] && clear || true

echo "Extracting Mesa source..." $'\n'
unzip "$mesadir".zip &> /dev/null
cd $mesadir

# Apply local Mesa patches
patch_dir="$(dirname "$workdir")/patches"
if [ -d "$patch_dir" ]; then
    for mesa_patch in "$patch_dir"/*.patch; do
        [ -e "$mesa_patch" ] || continue
        echo "Applying $(basename "$mesa_patch")..." $'\n'
        if ! patch -p1 --batch --forward < "$mesa_patch"; then
            echo -e "$red Failed to apply $(basename "$mesa_patch") $nocolor"
            exit 1
        fi
    done
fi

# Report the driver under the name Adreno OEM drivers use
tu_device="src/freedreno/vulkan/tu_device.cc"
sed -i 's/"Turnip Adreno/"Adreno/g' "$tu_device"
if ! grep -q '"Adreno (TM)' "$tu_device"; then
    echo -e "$red Failed to rename the Adreno device name in $tu_device $nocolor"
    exit 1
fi

# Set NDK Clang bin directory
ndk_bin="$workdir/$ndkdir/toolchains/llvm/prebuilt/linux-x86_64/bin"

# Set toolchain variables
export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export OBJDUMP=llvm-objdump
export OBJCOPY=llvm-objcopy
export LDFLAGS="-fuse-ld=lld"

# Create a temporary directory for fake cc/c++
fakecc_dir="$workdir/fake-cc"
mkdir -p "$fakecc_dir"

# Create symbolic links to NDK-Clang
ln -sf "$ndk_bin/clang" "$fakecc_dir/cc"
ln -sf "$ndk_bin/clang++" "$fakecc_dir/c++"

# Prepend both fake-cc and NDK bin to PATH
export PATH="$fakecc_dir:$ndk_bin:$PATH"

echo "Creating Meson cross files..." $'\n'
mkdir -p "$workdir/$ndkdir/pkg-config"

cat <<EOF >"$workdir/native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

# Build the driver for one Android ABI. $2 is the NDK target triple, which
# differs from the ABI name for armv7 (armv7a-linux-androideabi).
build_abi() {
    local abi="$1" triple="$2" cpu_family="$3" cpu="$4" extra="$5"
    local cross_file="$workdir/cross-$abi.txt"
    local build_dir="build-android-$abi"
    local driver_src out_dir

    cat <<EOF >"$cross_file"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/$triple$sdkver-clang'$extra, '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['ccache', '$ndk_bin/$triple$sdkver-clang++'$extra, '--start-no-unused-arguments', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error=c++11-narrowing', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$workdir/$ndkdir/pkg-config', 'pkg-config']

[host_machine]
system = 'android'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

    echo "Generating build files for $abi..." $'\n'
    if ! CC=clang CXX=clang++ meson setup "$build_dir" \
        --cross-file "$cross_file" \
        --native-file "$workdir/native.txt" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true \
        -Dandroid-strict=false \
        -Dgallium-drivers= \
        -Dvulkan-beta=true \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dstrip=true &> "$workdir/meson_log-$abi"; then
        echo -e "$red Meson setup failed for $abi! Log: $nocolor"
        cat "$workdir/meson_log-$abi"
        exit 1
    fi

    echo "Compiling build files for $abi..." $'\n'
    if ! ninja -C "$build_dir" &> "$workdir/ninja_log-$abi"; then
        echo -e "$red Ninja compilation failed for $abi! Log: $nocolor"
        cat "$workdir/ninja_log-$abi"
        exit 1
    fi

    echo "Stripping and patching the $abi driver..." $'\n'
    driver_src="$workdir/$mesadir/$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$driver_src" ]; then
        echo -e "$red Build failed! libvulkan_freedreno.so not found at $driver_src $nocolor" && exit 1
    fi

    out_dir="$workdir/$abi"
    mkdir -p "$out_dir"
    cp "$driver_src" "$out_dir/vulkan.adreno.so"

    # Strip unneeded debug symbols to reduce size from ~60MB+ to ~15-20MB
    "$ndk_bin/llvm-strip" --strip-unneeded "$out_dir/vulkan.adreno.so"

    # Set DT_SONAME using patchelf to match the installed driver name
    patchelf --set-soname vulkan.adreno.so "$out_dir/vulkan.adreno.so"

    # The linker marks shared libraries executable; vendor HAL modules are 0644
    chmod 0644 "$out_dir/vulkan.adreno.so"
}

# -fno-plt is a no-op on armv7: clang warns "argument unused during
# compilation", and Meson's feature probes pass
# -Werror=unused-command-line-argument, so every probe would fail and expat
# would define size_t to nothing. Only aarch64 supports it.
build_abi arm64-v8a aarch64-linux-android aarch64 armv8 ", '-fno-plt'"
build_abi armeabi-v7a armv7a-linux-androideabi arm armv7hl ""

[ -t 1 ] && clear || true
echo -e "Turnip Drivers:" $'\n'
echo -e "  64-bit (vendor/lib64/hw): $workdir/arm64-v8a/vulkan.adreno.so" $'\n'
echo -e "  32-bit (vendor/lib/hw)  : $workdir/armeabi-v7a/vulkan.adreno.so" $'\n'
echo -e "SHA1:" $'\n'
(cd "$workdir" && sha1sum arm64-v8a/vulkan.adreno.so armeabi-v7a/vulkan.adreno.so)

# Clean up fake-cc directory and symbolic links on exit
rm -rf "$fakecc_dir"
