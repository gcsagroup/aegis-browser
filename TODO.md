# Aegis TODO

## Build System — CMake

CMake is planned as build infrastructure for future native C/C++ components. The current application build remains on the existing Xcode workflow until a native module needs this support.

- [ ] Introduce the CMake project foundation.
  - Add the initial `CMakeLists.txt` structure.
  - Support Debug and Release configurations.
- [ ] Add Xcode generator support.
  - Verify CMake can generate an Xcode project for supported native targets.
  - Keep the existing Aegis Xcode build workflow compatible.
- [ ] Prepare reusable native module build infrastructure.
  - C++ core libraries.
  - Network engine modules.
  - Cross-platform components shared by supported platforms.
- [ ] Add CI validation for the CMake path.
  - Verify CMake configuration succeeds.
  - Verify project/build generation succeeds for the supported macOS path.

### Activation criteria

Start implementing this roadmap when Aegis introduces a native component that benefits from an independent C/C++ build, such as a reusable network core, performance-sensitive native module, browser-engine integration component, or cross-platform library.
