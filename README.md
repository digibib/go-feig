# Feig RFID integration

Feig RFID hardware integration and API for simple implentation and control.

This software is released under MIT license from Deichman Public Library.

Short description: This is a service that exposes a simple API to communication with FEIG hardware,
connected by USB, serial (COM), TCP or Bluetooth Low Energy (BLE). It is built on the FEIG FEDM C++
SDK (`libfedm`) bundled under `./fedm`. It encompasses the operations to read and write tags and AFI
alarm on ISO15693 transponders using a FEIG device. It also wraps an HTTP eventsource endpoint for
easy use by any browser app. The bundled web UI is embedded at build time
from `src/assets/index.html` and served at `/`.

## Installation and Requirements

- zig 0.16 (primary build) plus `make`
- The FEIG FEDM SDK, bundled under `./fedm`:
  - linux x64: headers `./fedm/linux-x64/include`, shared libraries `./fedm/linux-x64/bin/release`
  - windows x64 (VC++ 14.3): headers `./fedm/win-vc143-x64/include`, DLLs
    `./fedm/win-vc143-x64/bin/release`, import libraries `./fedm/win-vc143-x64/lib/release`

To build for linux x64: run `make build`. This runs `zig build` (the C++ shim
`src/fedm_shim.cpp` is compiled directly into the binary against the linux SDK)
and stages the SDK shared libraries next to the binary in `zig-out/bin` (found
at runtime via the `$ORIGIN` rpath - deploy `zig-out/bin` as a unit).

To build for windows x64: run `make build_windows` - a pure-Linux cross build
with zig (`x86_64-windows-gnu`). The FEDM windows SDK is MSVC-ABI, so the C++
shim is prebuilt **once** on a Windows box as `feigshim.dll` + `feigshim.lib`
(plain C interface, safe to call across the ABI):

1. on a Windows box with VS 2022 (C++ workload): `scripts\build-feigshim-windows.bat`
2. copy the resulting `fedm\shim-windows\` back into the repo and commit it
   (it is **not** gitignored - the cross build needs it)
3. on Linux: `make build_windows`

The zig build links `feigshim.lib` and stages the exe + `feigshim.dll` + the
FEIG DLLs + the VC++ runtime DLLs into `zig-out/bin`; deploy that directory as
a unit (Windows finds the DLLs next to the .exe).

For BLE support the host needs a working Bluetooth Low Energy stack (BlueZ on Linux, built in on
Windows). Note: the FEDM SDK 7.1.0 linux package does not include the FEBLE plugin library
(`libfeble.so`), so BLE currently only works with the windows build (which ships `feble.dll`).

## Usage

```
  -axeHost string
        host of feiging axe (tcp)
  -axePort int
        port of feiging axe
  -bleMac string
        MAC address of reader to connect to over Bluetooth LE (e.g. AA:BB:CC:DD:EE:FF)
  -comPort string
        serial port of reader (e.g. /dev/ttyUSB0)
  -comFrame string
        serial byte frame (8E1 | 8N1 | 8O1) (default "8E1")
  -comBaud int
        serial baudrate (default 38400)
  -debug
        turn on verbose logging
  -library string
        library ISIL number (default "02030000")
  -onlyOne
        only one active /events/ subscriber (default true)
  -port string
        port of http API (default ":1667")
  -tagStandard string
        tag content standard (default "dansk")
  -tls
        use tls (not supported in the zig build)
  -wake
        Keep inventory state and keep all transponders awake, will not be able to read tag content (default true)
```

Connection type is picked from the flags: BLE (`-bleMac`) > serial (`-comPort`) > TCP
(`-axeHost`/`-axePort`) > USB (auto scan for a plugged reader, default).

Application fires up a http server and serves the embedded web UI (src/assets/index.html)

**API routes:**

```
    /.status 	server status endpoint
    /events/    eventsource subscription

    /scan    	scan inventory once
    /start 		start scan loop (send to any connected EventSource client)
    /stop 		stop scan loop
    /write 		write to tags in range (param: barcode)
    /writetagbarcode  write to a single tag in current inventory (params: tagid, barcode)
    /alarmOff 	turn off AFI alarm on all tags in range
    /alarmOn 	turn on AFI alarm on all tags in range

    /ble/scan 	start/continue BLE discovery, list discovered readers
    /ble/stop 	stop BLE discovery
```

Basic flow is:

* inventory is fetched and kept in memory either by polling `/scan` or by activating scan loop with `/start`
* barcodes can be used to fetch and present information
* at any time a current inventory can be
    * rewritten: all tags in range are written to using sequence number and number of tags (`/write?barcode=1234567890`)
    * desensitized: (`/alarmOff`)
    * sensitized: (`/alarmOn`)
* `/.status` will at any time display uptime status, current inventory and read success/failures

## Bluetooth LE

Discover BLE readers with `GET /ble/scan` (repeated calls keep discovery running and list newly
seen readers, e.g. `{"mac":"AA:BB:CC:DD:EE:FF","deviceId":"...","readerType":"...","new":true}`).
Stop discovery with `GET /ble/stop`. To use a discovered reader as the connected device, start the
app with `-bleMac <mac>`.

## Documentation

Read more in ./docs folder
