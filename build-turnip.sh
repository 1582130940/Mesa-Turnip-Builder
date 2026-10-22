#!/bin/bash -e

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
deps="meson ninja patchelf unzip curl flex bison clang ccache pkg-config"
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
       "meson_log" "ninja_log" \
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
mkdir -p "$workdir/$ndkdir/pkg-config"

cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang', '-fno-plt', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--start-no-unused-arguments', '-fno-plt', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error=c++11-narrowing', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$workdir/$ndkdir/pkg-config', 'pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[properties]
needs_exe_wrapper = true
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
if ! CC=clang CXX=clang++ meson setup build-android-aarch64 \
    --cross-file "$workdir/$mesadir/android-aarch64.txt" \
    --native-file "$workdir/$mesadir/native.txt" \
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
    -Dstrip=true &> "$workdir/meson_log"; then
    echo -e "$red Meson setup failed! Log: $nocolor"
    cat "$workdir/meson_log"
    exit 1
fi

# Compile build files using Ninja
echo "Compiling build files..." $'\n'
if ! ninja -C build-android-aarch64 &> "$workdir"/ninja_log; then
    echo -e "$red Ninja compilation failed! Log: $nocolor"
    cat "$workdir/ninja_log"
    exit 1
fi

echo "Stripping and patching driver binaries..." $'\n'
driver_src="$workdir/$mesadir/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so"
if [ ! -f "$driver_src" ]; then
    echo -e "$red Build failed! libvulkan_freedreno.so not found at $driver_src $nocolor" && exit 1
fi

cp "$driver_src" "$workdir/libvulkan_freedreno.so"
cd "$workdir"

# Strip unneeded debug symbols to reduce size from ~60MB+ to ~15-20MB
"$ndk_bin/llvm-strip" --strip-unneeded libvulkan_freedreno.so

# Prepare driver files
cp libvulkan_freedreno.so vulkan.adreno.so

# Set DT_SONAME using patchelf to match driver filenames
patchelf --set-soname vulkan.adreno.so vulkan.adreno.so

[ -t 1 ] && clear || true
echo -e "Turnip Driver : $workdir/vulkan.adreno.so" $'\n'

# Clean up fake-cc directory and symbolic links on exit
rm -rf "$fakecc_dir"
