# retune driver (libASPL)

This folder contains a minimal CoreAudio AudioServerPlugIn skeleton using libASPL.

Notes:
- This builds a HAL plugin (.driver bundle). Installing requires admin privileges.
- The driver must be copied to /Library/Audio/Plug-Ins/HAL/ and coreaudiod must be restarted.
- This is the only robust no-permission path for "system output -> virtual device -> app" routing.

Build (CMake):
1) Ensure libASPL is available (cloned in ../ref-repos/libASPL)
2) Configure and build:
   mkdir -p build && cd build
   cmake ..
   cmake --build .

Install:
1) Copy the built .driver bundle into /Library/Audio/Plug-Ins/HAL/
2) Restart coreaudiod:
   sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod

Uninstall:
- Remove the .driver bundle from /Library/Audio/Plug-Ins/HAL/
- Restart coreaudiod
