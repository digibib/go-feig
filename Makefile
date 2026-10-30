PHONY: build all
.DEFAULT_GOAL := help

DEBUG    ?= false
WAKE     ?= true
PORT     ?= :1667
AXEHOST  ?= 10.172.2.61
AXEPORT  ?= 10001

# FEIG FEDM SDK (C++), bundled per platform: linux x64 and windows x64 (VC++ 14.3)
FEDM_LNX := ./fedm/linux-x64
FEDM_WIN := ./fedm/win-vc143-x64


help:  	## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

clean:
	rm -rf ./build/*

install-fedm-libs: ## install FEDM SDK shared libraries and symlinks to ./build (linux)
	mkdir -p ./build
	bash -c "cd $(FEDM_LNX)/bin/release && ./install-linux-libs.sh $(abspath build)"

install-fedm-libs-win: ## install FEDM SDK DLLs and import libs to ./build (windows)
	mkdir -p ./build
	cp $(FEDM_WIN)/bin/release/*.dll ./build/
	# stage each import lib under both names lld may search for on -l<name>:
	# mingw convention lib<name>.a and MSVC convention <name>.lib
	@for f in $(FEDM_WIN)/lib/release/*.lib; do \
		n=$${f##*/}; \
		cp "$$f" "./build/$$n"; \
		cp "$$f" "./build/lib$${n%.lib}.a"; \
	done

##@ Linux builds

build: clean install-fedm-libs ## build linux x64 (FEDM SDK)
	go vet ./cmd/...
	# rpath/rpath-link for the FEDM libs are set in cmd/reader.go's #cgo LDFLAGS
	go build -o ./build/feig ./cmd/

run: build ## build and run linux x64 with USB driver
	./build/feig -debug=$(DEBUG) -wake=$(WAKE) -port=$(PORT)

swing-axe: build ## build and run linux x64 with TCP driver (axe)
	./build/feig -debug=$(DEBUG) -wake=$(WAKE) -port=$(PORT) -axeHost=$(AXEHOST) -axePort=$(AXEPORT)

run-ble: build ## build and run connected to a BLE reader, e.g. make run-ble MAC=AA:BB:CC:DD:EE:FF
	./build/feig -port=$(PORT) -bleMac=$(MAC)

##@ Windows builds
# The FEDM Windows SDK (win-vc143-x64, bundled) is MSVC-ABI: MSVC name
# mangling + 40-byte std::string. Calling it correctly requires the shim
# to be built with the MSVC ABI, so the supported path is MSVC (cl) on a
# Windows machine:
#   scripts\build-msvc.bat   (VS 2022 Developer Command Prompt x64)
# zig cannot produce the MSVC ABI from a Linux host: its
# x86_64-windows-msvc target provides no MSVC libc, and the MinGW target
# (x86_64-windows-gnu) has the wrong ABI (Itanium mangling, 32-byte
# std::string). 'build_windows' (zig, MinGW ABI) is therefore only viable
# if FEIG provides a MinGW/clang (Itanium) build of the Windows SDK -
# with such a SDK it works unchanged (flags in cmd/reader_zig.go, import
# libs staged in ./build by install-fedm-libs-win).
# scripts/zigcc wraps zig: go build injects -mthreads for C++ cgo
# packages, which the msvc target rejects, so the wrapper drops it.

ZIGCC := $(CURDIR)/scripts/zigcc

build_windows: clean install-fedm-libs-win ## build Windows .exe 64bit with zig (needs a MinGW/Itanium build of the SDK)
	go vet ./cmd/...
	@chmod +x $(ZIGCC)
	GOOS=windows GOARCH=amd64 CGO_ENABLED=1 \
		CC="$(ZIGCC) cc -target x86_64-windows-gnu" CXX="$(ZIGCC) c++ -target x86_64-windows-gnu" \
		go build -o ./build/feig.exe ./cmd/

build_windows_msvc: ## build Windows .exe with MSVC - run scripts\build-msvc.bat on Windows in a VS 2022 dev cmd
	@echo Run scripts\build-msvc.bat on Windows (VS 2022 BuildTools, C++ workload, x64).

##@ arm builds
# NOTE: requires the FEDM SDK for the target platform (linux-x64 and
# win-vc143-x64 are bundled under fedm/). Adjust the #cgo CXXFLAGS/LDFLAGS
# directives in cmd/reader.go to point at the SDK headers and libraries for
# the target.
# raspberry arm: sudo apt install gcc-multilib-arm-linux-gnueabihf
# arm64: sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
# android aarch64: gcc-aarch64-linux-gnu
#CC=aarch64-linux-gnu-gcc GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/android/arm64-v8a" \
# CC=arm-linux-gnueabi-gcc GOOS=linux GOARCH=arm GOARM=6 CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/armv7-a -march=armv6" \
# arm-linux-gnueabi-gcc
# CC=/home/benjab/gcc-arm-none-eabi/bin/arm-none-eabi-gcc GOOS=linux GOARCH=arm CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/armv7-a" \
# PI:
# wget https://github.com/Pro/raspi-toolchain/releases/latest/download/raspi-toolchain.tar.gz
# sudo tar xfz raspi-toolchain.tar.gz --strip-components=1 -C /opt
#	CC="/opt/cross-pi-gcc/bin/arm-linux-gnueabihf-gcc -march=armv6 -mfpu=vfp -mfloat-abi=hard" GOOS=linux GOARCH=arm GOARM=6 \

build_pi: clean ## build raspberry 32bit armv6 binary (requires arm FEDM SDK)
	go vet ./cmd/...
	#CC="zig cc -v -target arm-linux-gnueabihf -mfloat-abi=hard -mfpu=vfp -march=armv6+fp" \
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
	#CC=aarch64-linux-gnu-gcc
	CC="zig cc -v -target aarch64-linux-gnu" \
	GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CGO_LDFLAGS="-v -fuse-ld=gold" \
	go build -buildmode=c-shared -ldflags="-extldflags=-static" -a -o ./build/feig ./cmd/

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
