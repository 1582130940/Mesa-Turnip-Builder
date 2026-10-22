# Freedreno Turnip Builder

### Mesa + Android NDK (r30)

Simple Bash script to build Turnip Vulkan drivers.

## How to Build Locally

Clone the repository and run the build script:

```bash
bash build-turnip.sh
```

The driver is built for both Android ABIs:

- `turnip_workdir/arm64-v8a/vulkan.adreno.so` for `/vendor/lib64/hw/`
- `turnip_workdir/armeabi-v7a/vulkan.adreno.so` for `/vendor/lib/hw/`

## Credits

This project wouldn't be possible without the help of these people:

- [@MrMiy4mo](https://github.com/ilhan-athn7) for creating the Turnip build script and letting me modify and learn from it.
- [@Mesa3D Team](https://gitlab.freedesktop.org/mesa/mesa) for the graphics driver stack.
- [Adreno Driver Support Group](https://t.me/adreno_driver) for testing and sharing benchmarks.
