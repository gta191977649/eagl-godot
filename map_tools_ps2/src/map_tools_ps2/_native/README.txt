meshoptimizer.dll is built from the meshoptimizer sources vendored by the
meshopt 0.6.2 Rust crate used by MTA-Eagle-Editor.

Upstream: https://github.com/zeux/meshoptimizer
Version exposed by that crate: meshoptimizer 0.25
License: MIT

The DLL exports meshopt_simplifyWithAttributes and is linked statically against
the MinGW C++ runtime so map_tools_ps2 can call the exact simplifier without a
Rust, MSVC, or Blender-Python dependency.
