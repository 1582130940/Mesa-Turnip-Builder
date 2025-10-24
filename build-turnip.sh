#!/bin/bash -e

# Define colors for terminal output
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Define Android NDK version and download URL
ndkdir="android-ndk-r29"
ndkver="https://dl.google.com/android/repository/${ndkdir}-linux.zip"
sdkver="34"

# Define Mesa version and download URL
mesadir="mesa-mesa-25.2.4"
mesaver="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-25.2.4/mesa-mesa-25.2.4.zip?ref_type=tags"

# Define working directories
workdir="$(pwd)/turnip_workdir"         # Base directory for all operations

# List of required packages to build the Turnip driver
deps="meson ninja patchelf unzip curl pip flex bison zip glslang"
clear

echo "Checking system for required dependencies..."

# Check for required dependencies 
for deps_chk in $deps; do

    sleep 0.5
    if command -v "$deps_chk" >/dev/null 2>&1; then
        echo -e "$green - $deps_chk found $nocolor"
    else
        echo -e "$red - $deps_chk not found, cannot continue. $nocolor"
        deps_missing=1

        if [ "$deps_missing" == "1" ]; then
            echo "Missing dependencies, installing them now..." $'\n'
            sudo apt install -y meson-1.5 patchelf unzip curl python3-pip flex bison zip python3-mako glslang-tools vulkan-tools python-is-python3 &> /dev/null
        fi
    fi
done

sleep 1.5
clear

# Ensure work directory exists and enter it
echo "Ensuring work directory exists: $workdir" $'\n'
mkdir -p "$workdir"
cd "$workdir"

# Clean *only* build artifacts, keeping existing .zip files
echo "Cleaning previous build artifacts (if any)..." $'\n'
rm -rf "$ndkdir" "$mesadir" "fake-cc" \
       "libvulkan_freedreno.so" "vulkan.adreno.so" \
       "meson_log" "ninja_log" "android-aarch64.txt" "native.txt"
sleep 2

# Download Android NDK
if [ ! -f "${ndkdir}.zip" ]; then
    echo "Downloading Android NDK..." $'\n'
    curl $ndkver --output "${ndkdir}.zip" &> /dev/null
else
    echo -e "$green - Found ${ndkdir}.zip. Skipping NDK download. $nocolor" $'\n'
fi

clear

echo "Extracting Android NDK..." $'\n'
unzip "${ndkdir}.zip" &> /dev/null

# Download Mesa source
if [ ! -f "${mesadir}.zip" ]; then
    echo "Downloading Latest Mesa source ..." $'\n'
    curl $mesaver --output "${mesadir}.zip" &> /dev/null
else
    echo -e "$green - Found ${mesadir}.zip. Skipping Mesa download. $nocolor" $'\n'
fi

clear

echo "Extracting Mesa source..." $'\n'
unzip "${mesadir}.zip" &> /dev/null
cd $mesadir

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

echo "Creating Meson cross file..." $'\n'

cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--start-no-unused-arguments', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error=c++11-narrowing', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

cat <<EOF >"native.txt"
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

echo "Generating build files..." $'\n'
CC=clang CXX=clang++ meson setup build-android-aarch64 \
    --cross-file "$workdir/$mesadir/android-aarch64.txt" \
    --native-file "$workdir/$mesadir/native.txt" \
    -Dbuildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version="$sdkver" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Db_lto=true \
    -Degl=disabled \
    -Dstrip=true &> $workdir/meson_log

# Compile build files using Ninja
echo "Compiling build files..." $'\n'
ninja -C build-android-aarch64 &> "$workdir"/ninja_log

echo "Using patchelf to match .so name..." $'\n'
cp "$workdir"/"$mesadir"/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
cd "$workdir"

if ! [ -a libvulkan_freedreno.so ]; then
    echo -e "$red Build failed! libvulkan_freedreno.so not found $nocolor" && exit 1
fi

echo "Copy necessary files from the work directory..." $'\n'
cp "$workdir"/libvulkan_freedreno.so "$workdir"/vulkan.adreno.so
