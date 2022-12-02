PHONY: build all
.DEFAULT_GOAL := help

KOHA_API ?= http://localhost:8081/api
DEBUG    ?= false
WAKE     ?= true
PORT     ?= :1667
AXEHOST  ?= 10.172.2.61
AXEPORT  ?= 10001

help:  	## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

clean:
	rm -rf ./build/*

# STATIC BUILD (NOT SUPPORTED)
static:
	CGO_LDFLAGS="-L$(pwd)/drivers/x64" CGO_CFLAGS="-Idrivers" go build -tags "seccomp netgo cgo static_build" \
	-ldflags "-linkmode external -w -extldflags -static" feiging_usb.go eshub.go

dynamic:
	go build -tags "seccomp netgo cgo static_build" feiging_usb.go eshub.go

##@ Linux builds

build:	clean ## build linux x64
	go vet ./cmd/...
	go build -o ./build/feig cmd/server.go cmd/logger.go cmd/reader.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/linux/{libfeisc*,libfeusb*,libfetcp*,install*} ./build/"

run: ## run linux x64 with USB driver
	go vet ./cmd/...
	go run cmd/server.go cmd/logger.go cmd/reader.go cmd/handlers.go cmd/inventory.go cmd/main.go -debug=$(DEBUG) -wake=$(WAKE) -koha=$(KOHA_API) -spore=$(KOHA_API)/spore/hub/feig -port=$(PORT)

run-ssl: ## run linux x64 with USB driver
	go vet ./cmd/...
	go run cmd/server.go cmd/logger.go cmd/reader.go cmd/handlers.go cmd/inventory.go cmd/main.go -debug=$(DEBUG) -wake=$(WAKE) -koha=$(KOHA_API) -spore=$(KOHA_API)/spore/hub/feig -port=$(PORT) -tls

swing-axe: ## run linux x64 with TCP driver (axe)
	go run cmd/server.go cmd/logger.go cmd/reader.go cmd/handlers.go cmd/inventory.go cmd/main.go \
		-debug=$(DEBUG) -wake=$(WAKE) -koha=$(KOHA_API) -spore=$(KOHA_API)/spore/hub/feig -port=$(PORT) -axeHost=$(AXEHOST) -axePort=$(AXEPORT)

##@ Windows builds

build_windows: clean ## build Windows .exe 64bit
	go vet ./cmd/...
	GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ go build -o ./build/feig.exe cmd/reader.go cmd/server.go cmd/logger.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/vc141/{*.dll,VC_redist.x64.exe} ./build/"

##@ arm builds
# PI:
# wget https://github.com/Pro/raspi-toolchain/releases/latest/download/raspi-toolchain.tar.gz
# sudo tar xfz raspi-toolchain.tar.gz --strip-components=1 -C /opt
#	CC="/opt/cross-pi-gcc/bin/arm-linux-gnueabihf-gcc -march=armv6 -mfpu=vfp -mfloat-abi=hard" GOOS=linux GOARCH=arm GOARM=6 \

build_pi:	clean ## build raspberry 32bit armv5 binary
	go vet ./cmd/...
	CC="arm-linux-gnueabihf-gcc -mfloat-abi=hard -mfpu=vfp -march=armv6+fp" GOOS=linux GOARCH=arm GOARM=6 \
	GOOS=linux GOARCH=arm GOARM=6 \
	CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/arm -Wl,-rpath-link,~/src/gitlab.deichman.no/digibib/feiging/drivers/arm" \
	go build -a -ldflags="-r=. -L./drivers/arm" -o ./build/feig cmd/reader.go cmd/server.go cmd/logger.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/arm/lib* ./build/"

build_armv7:	clean ## build raspberry 32bit armv7 binary
	go vet ./cmd/...
	CC="arm-linux-gnueabihf-gcc" \
	GOOS=linux GOARCH=arm GOARM=7 \
	CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/armv7-a -Wl,-rpath-link,~/src/gitlab.deichman.no/digibib/feiging/drivers/armv7-a" \
	go build -a -ldflags="-r ." -o ./build/feig cmd/reader.go cmd/server.go cmd/logger.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/armv7-a/lib* ./build/"

build_arm64:	clean ## build raspberry 64bit binary
	go vet ./cmd/...
	CC=aarch64-linux-gnu-gcc \
	GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CGO_LDFLAGS="-v -fuse-ld=gold" \
	go build -buildmode=c-shared -ldflags="-extldflags=-static" -a -o ./build/feig cmd/reader.go cmd/server.go cmd/logger.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/android/arm64-v8a/libfe* ./build/"

# sudo apt install sdkmanager
# sudo sdkmanager --install "platforms;android-30"
# sudo sdkmanager --install "build-tools;33.0.0"
# sudo sdkmanager --install "ndk;25.1.8937393"
# https://github.com/vamolessa/zig-sdl-android-template
build_android:	clean ## build android binary
	go vet ./cmd/...
	CC=/opt/android-sdk/ndk/25.1.8937393/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang \
	GOOS=android GOARCH=arm64 CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/android/arm64-v8a" \
	go build -a -ldflags="-r ." -o ./build/feig cmd/reader.go cmd/server.go cmd/logger.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/android/arm64-v8a/{libfe*,libc*,libusb*} ./build/"

build_shared_arm64:	clean ## build android binary
	go vet ./cmd/...
	CC=/opt/android-sdk/ndk/25.1.8937393/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang \
	GOOS=android GOARCH=arm64 CGO_ENABLED=1 CGO_LDFLAGS="-v -L./drivers/android/arm64-v8a" \
	go build -a -buildmode=c-shared -o ./build/libfeiging.so cmd/reader.go cmd/server.go cmd/logger.go cmd/handlers.go cmd/inventory.go cmd/main.go
	bash -c "cp -a ./drivers/android/arm64-v8a/{libfe*,libc*,libusb*} ./build/"

push_android: ## push to usb or tcp connected adb device
	adb push ./build/* /data/local/tmp/
