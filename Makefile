.PHONY: build all
.DEFAULT_GOAL := help

DEBUG    ?= false
WAKE     ?= true
PORT     ?= :1667
AXEHOST  ?= 10.172.2.61
AXEPORT  ?= 10001
MAC      ?=

# FEIG FEDM SDK (C++), bundled per platform: linux x64 and windows x64 (VC++ 14.3)
FEDM_LNX := ./fedm/linux-x64
FEDM_WIN := ./fedm/win-vc143-x64

# The system's static C++ runtime, located via the same g++ that compiles
# the shim (prints the bare name if not found). zig 0.16 can only link
# its own libc++ as the C++ runtime, so the shim's libstdc++ symbols are
# resolved by statically linking this archive (like g++ -static-libstdc++).
LIBSTDCXX_A := $(shell g++ -print-file-name=libstdc++.a)


help:  	## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

clean:
	rm -rf ./build/* ./zig-out/*

##@ Linux build (zig, primary)

build: ## build linux x64 with zig (FEDM SDK, deploy unit in zig-out/bin)
	mkdir -p ./build build/fedm-libs
	# The shim is compiled with the system g++ (libstdc++ ABI, matching the
	# SDK); zig only links the object. See build.zig for details.
	g++ -O2 -fPIC -fexceptions -I $(FEDM_LNX)/include -I $(FEDM_LNX)/include/fedm -c cmd/fedm_shim.cpp -o ./build/fedm_shim.o
	test "$(LIBSTDCXX_A)" != "libstdc++.a" -a -f "$(LIBSTDCXX_A)" || { echo "ERROR: g++ cannot find its libstdc++.a (printed: '$(LIBSTDCXX_A)') - install libstdc++-dev"; exit 1; }
	cp -f "$(LIBSTDCXX_A)" build/libstdc++.a
	# stage the versioned .so's plus the SONAME (libfedm.so.7) and
	# unversioned (libfedm.so) symlink chain - zig build resolves -lfedm
	# from build/fedm-libs (see build.zig)
	bash -c "cd $(FEDM_LNX)/bin/release && ./install-linux-libs.sh $(abspath build/fedm-libs)"
	test -e build/fedm-libs/libfedm.so || { echo "ERROR: build/fedm-libs/libfedm.so missing after staging - SDK layout changed?"; exit 1; }
	zig build
	# zig 0.16 records the $ORIGIN rpath as DT_RUNPATH, which glibc ignores
	# for the SDK's dlopen of the transport plugins - convert it to DT_RPATH
	# so ./zig-out/bin/feig runs directly (see scripts/elf_rpath.c)
	gcc -O2 -o build/elf_rpath scripts/elf_rpath.c
	./build/elf_rpath zig-out/bin/feig
	# stage the same deploy unit next to the exe (runtime; the run targets
	# set LD_LIBRARY_PATH until zig gets a rpath API - see build.zig)
	bash -c "cd $(FEDM_LNX)/bin/release && ./install-linux-libs.sh $(abspath zig-out/bin)"

run: build ## build and run linux x64 with USB driver
	# LD_LIBRARY_PATH until zig 0.16 gets a rpath API (see build.zig)
	LD_LIBRARY_PATH=$(abspath zig-out/bin) ./zig-out/bin/feig -debug=$(DEBUG) -wake=$(WAKE) -port=$(PORT)

swing-axe: build ## build and run linux x64 with TCP driver (axe)
	LD_LIBRARY_PATH=$(abspath zig-out/bin) ./zig-out/bin/feig -debug=$(DEBUG) -wake=$(WAKE) -port=$(PORT) -axeHost=$(AXEHOST) -axePort=$(AXEPORT)

run-ble: build ## build and run connected to a BLE reader, e.g. make run-ble MAC=AA:BB:CC:DD:EE:FF
	LD_LIBRARY_PATH=$(abspath zig-out/bin) ./zig-out/bin/feig -port=$(PORT) -bleMac=$(MAC)

##@ Windows build (zig cross compile, primary)
# The FEDM windows SDK (win-vc143-x64) is MSVC-ABI (MSVC name mangling,
# 40-byte std::string), so the C++ shim (cmd/fedm_shim.cpp) cannot be
# compiled with zig from Linux. It is prebuilt ONCE on a Windows box as
# feigshim.dll + feigshim.lib (committed under fedm/shim-windows/):
#
#   1. on a Windows box with VS 2022 (C++ workload):
#        scripts\build-feigshim-windows.bat
#   2. copy fedm\shim-windows\ back into the repo and commit it
#   3. on Linux:  make build_windows
#
# The zig build (x86_64-windows-gnu) links feigshim.lib and stages
# feigshim.dll + the FEIG DLLs + the VC++ runtime DLLs next to the exe;
# deploy zig-out/bin as a unit. Note: the exe is mingw-ABI, it needs the
# mingw runtime DLLs (libgcc_s_seh-1.dll, libwinpthread-1.dll) - zig
# copies them to zig-out/bin automatically if your zig install ships them.

build_windows: ## cross-compile windows x64 .exe on linux (zig, needs fedm/shim-windows)
	@test -f fedm/shim-windows/feigshim.lib || { echo "ERROR: fedm/shim-windows/feigshim.lib not found."; echo "Run scripts\\build-feigshim-windows.bat on a Windows box (VS 2022), copy fedm\\shim-windows\\ back here, commit it, and retry."; exit 1; }
	zig build -Dwindows -Dtarget=x86_64-windows-gnu
	# stage the deploy unit: shim DLL + VC++ runtime + FEIG DLLs next to the exe
	cp -f fedm/shim-windows/feigshim.dll fedm/shim-windows/vcruntime140.dll fedm/shim-windows/vcruntime140_1.dll fedm/shim-windows/msvcp140.dll fedm/win-vc143-x64/bin/release/*.dll zig-out/bin/

zip_windows: build_windows ## zip the windows deploy unit (feig-windows.zip)
	cd zig-out/bin && zip -r ../../feig-windows.zip .

##@ Legacy go builds (the go sources under cmd/ are kept for reference;
## the zig builds above are the primary path)
# The old go windows cross build (clang/MSVC-ABI sysroot) was abandoned:
# see the git history for build_windows (clang), msvc-sysroot and the
# scripts/collect-msvc-sysroot.bat flow.

build_go: ## legacy: build linux x64 with go + cgo (output in ./build)
	mkdir -p ./build
	bash -c "cd $(FEDM_LNX)/bin/release && ./install-linux-libs.sh $(abspath build)"
	go vet ./cmd/...
	go build -o ./build/feig ./cmd/

run_go: build_go ## legacy: run the go linux build
	./build/feig -debug=$(DEBUG) -wake=$(WAKE) -port=$(PORT)

##@ Legacy arm builds (go + cgo, requires the arm FEDM SDK)
# NOTE: requires the FEDM SDK for the target platform (linux-x64 and
# win-vc143-x64 are bundled under fedm/). Adjust the #cgo CXXFLAGS/LDFLAGS
# directives in cmd/reader.go to point at the SDK headers and libraries
# for the target.
# raspberry arm: sudo apt install gcc-multilib-arm-linux-gnueabihf
# arm64: sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
# android aarch64: gcc-aarch64-linux-gnu
#PI:
# wget https://github.com/Pro/raspi-toolchain/releases/latest/download/raspi-toolchain.tar.gz
# sudo tar xfz raspi-toolchain.tar.gz --strip-components=1 -C /opt

build_pi: clean ## build raspberry 32bit armv6 binary (requires arm FEDM SDK)
	go vet ./cmd/...
	CC="arm-linux-gnueabihf-gcc -mfloat-abi=hard -mfpu=vfp -march=armv6+fp" GOOS=linux GOARCH=arm GOARM=6 \
	CGO_ENABLED=1 \
	go build -a -ldflags="-r . -L./build" -o ./build/feig ./cmd/

build_armv7: clean ## build raspberry 32bit armv7 binary (requires arm FEDM SDK)
	go vet ./cmd/...
	CC="/opt/cross-pi-gcc/bin/arm-linux-gnueabihf-gcc -march=armv7-a -mfpu=vfp -mfloat-abi=hard" GOOS=linux GOARCH=arm GOARM=7 \
	CGO_ENABLED=1 \
	go build -a -ldflags="-r . -L ./build" -o ./build/feig ./cmd/

build_armv7l: clean ## build raspberry 32bit armv7-l binary 3B+ (requires arm FEDM SDK)
	go vet ./cmd/...
	CC="zig cc -v -target arm-linux-gnueabihf" \
	CGO_ENABLED=1 \
	GOOS=linux GOARCH=arm GOARM=7 \
	go build -a -ldflags="-r . -L ./build" -o ./build/feig ./cmd/

build_arm64: clean ## build raspberry 64bit binary (requires arm64 FEDM SDK)
	go vet ./cmd/...
	CC="zig cc -v -target aarch64-linux-gnu" \
	GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CGO_LDFLAGS="-v -fuse-ld=gold" \
	go build -a -ldflags="-r ." -o ./build/feig ./cmd/

push_pi: ## push to raspberry pi
	rsync -avz build/ pi@

build_android: clean ## build android binary (requires android FEDM SDK)
	go vet ./cmd/...
	CC=/home/benjab/android-ndk-r23/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
	GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
	go build -a -ldflags="-r ." -o ./build/feig ./cmd/

build_shared_arm64: clean ## build android c-shared library (requires android FEDM SDK)
	go vet ./cmd/...
	CC=/home/benjab/android-ndk-r23/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
	GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
	go build -a -buildmode=c-shared -o ./build/libfeiging.so ./cmd/

push_android: ## push to usb or tcp connected adb device
	adb push ./build/* /data/local/tmp/
