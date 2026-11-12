const std = @import("std");

const FEDM_LNX = "fedm/linux-x64";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = b.option(bool, "windows", "Target Microsoft Windows") orelse false;

    const feigModule = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (windows) {
        // The FEIG Windows SDK is MSVC-ABI (MSVC name mangling, 40-byte
        // std::string), so the C++ shim cannot be compiled with zig here.
        // It is prebuilt as feigshim.dll with MSVC - one-time, on a Windows
        // box: scripts\build-feigshim-windows.bat (output committed under
        // fedm/shim-windows/). The DLL exposes a plain C interface
        // (src/fedm_shim.h), which is safe to call from a GNU-ABI zig exe.
        const exe = b.addExecutable(.{
            .name = "feig",
            .root_module = feigModule,
        });
        // feigshim.lib lives next to the prebuilt shim DLL
        exe.root_module.addLibraryPath(b.path("fedm/shim-windows"));
        // bare name: zig appends the platform suffixes itself
        // (feigshim.dll / feigshim.lib / feigshim.a)
        exe.root_module.linkSystemLibrary("feigshim", .{});
        // TLS shim (SChannel), cross-compiled by 'make build_windows';
        // it resolves all win32 functions at runtime (LoadLibraryA /
        // GetProcAddress, kernel32), so no extra system libraries
        exe.root_module.addObjectFile(b.path("build/tls_shim_win.o"));
        b.installArtifact(exe);
    } else {
        // The shim is compiled by the system g++ in 'make build'. The SDK is
        // built with libstdc++; zig's own C++ runtime (libc++) would mangle
        // std::string as std::__1::basic_string, so the SDK's exported
        // symbols taking a std::string (create*Connector) could never
        // resolve - no amount of -l flags fixes a mangled-name mismatch.
        // 'make build' compiles build/fedm_shim.o before 'zig build'; if
        // it is missing, the link fails with a file-not-found here.
        feigModule.addObjectFile(b.path("build/fedm_shim.o"));
        // TLS (OpenSSL) shim; dlopens libssl at runtime, so no -lssl
        feigModule.addObjectFile(b.path("build/tls_shim.o"));
        // The shim's C++ runtime: zig's linkSystemLibrary("stdc++") links
        // zig's own bundled libc++ (a different std::string ABI than the
        // SDK's libstdc++), so the shim's libstdc++ symbols are resolved
        // by statically linking the system g++ libstdc++.a instead - the
        // same as g++ -static-libstdc++ ('make build' stages it here).
        // libfedm.so keeps its own dynamic libstdc++.so.6 dependency.
        feigModule.addObjectFile(b.path("build/libstdc++.a"));
        feigModule.addLibraryPath(b.path("build/fedm-libs"));
        feigModule.addIncludePath(b.path("fedm/linux-x64/include"));
        feigModule.addIncludePath(b.path("fedm/linux-x64/include/fedm"));
        const feigLib = b.addLibrary(.{
            .name = "feig-lib",
            .linkage = .static,
            .root_module = feigModule,
        });
        b.installArtifact(feigLib);

        const exe = b.addExecutable(.{
            .name = "feig",
            .root_module = feigModule,

        });
        exe.root_module.addLibraryPath(b.path("build/fedm-libs"));
        // zig records -L dirs as the exe's RUNPATH (that's how libfedm is
        // found at runtime); keep the staged deploy dir in there too.
        exe.root_module.addLibraryPath(b.path("zig-out/bin"));
        // -lfedm resolves build/fedm-libs/libfedm.so, whose symlink chain
        // (made by install-linux-libs.sh) points at the versioned
        // libfedm.so.7.1.0.
        exe.root_module.linkSystemLibrary("fedm", .{});
        // libfedm.so NEEDS libfeisp.so.1, but the linker does not copy
        // that NEEDED onto the exe, and glibc does not consult the exe's
        // RUNPATH when resolving a dependency's own NEEDEDs - so link it
        // explicitly, making it a direct NEEDED of the exe (resolved via
        // the RUNPATH dirs above).
        exe.root_module.linkSystemLibrary("feisp", .{});
        // Exception unwinding for the shim and the statically linked
        // libstdc++ (a g++ driver would add this automatically).
        exe.root_module.linkSystemLibrary("gcc_s", .{});
        // $ORIGIN rpath: the FEIG SDK dlopens the transport plugins by
        // bare name (e.g. "libfeusb2.so") from inside libfeisp. That
        // lookup only inherits old-style DT_RPATH down the dependency
        // chain - the exe's DT_RUNPATH (recorded from the -L dirs
        // above) is NOT consulted, so without this the plugin dlopen
        // fails with "cannot open shared object file" whenever the
        // binary is run directly. addRPathSpecial takes linker tokens.
        exe.root_module.addRPathSpecial("$ORIGIN");
        b.installArtifact(exe);
    }
}
