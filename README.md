# Feig RFID integration

Feig RFID hardware integration and API for simple implentation and control.

This software is released under MIT license from Deichman Public Library.

Short description: This is a service that exposes a simple API to communication with FEIG hardware,
connected by USB, serial (COM), TCP or Bluetooth Low Energy (BLE). It is built on the FEIG FEDM C++
SDK (`libfedm`) bundled under `./fedm`. It encompasses the operations to read and write tags and AFI
alarm on ISO15693 transponders using a FEIG device. It also wraps an HTTP eventsource endpoint for
easy use by any browser app. In addition it allows for embedding any HTTP web page if included under
``./cmd/html` folder.

## Installation and Requirements

- go version 1.21 or later
- `make` and a C/C++ compiler toolchain (`gcc`/`g++` for linux x64)
- The FEIG FEDM SDK, bundled under `./fedm`:
  - linux x64: headers `./fedm/linux-x64/include`, shared libraries `./fedm/linux-x64/bin/release`
  - windows x64 (VC++ 14.3): headers `./fedm/win-vc143-x64/include`, DLLs
    `./fedm/win-vc143-x64/bin/release`, import libraries `./fedm/win-vc143-x64/lib/release`

For other platforms (arm, android) the corresponding FEDM SDK must be provided and the
`#cgo CXXFLAGS`/`LDFLAGS` directives in `cmd/reader.go` adjusted accordingly.

To build for linux x64: run `make build`. The build installs the SDK shared libraries into `./build`
(next to the binary, found at runtime via `$ORIGIN` rpath).

To build for windows x64: run `make build_windows` (requires `zig`, used as the
gcc-compatible cross toolchain via `zig cc`/`zig c++`). The SDK DLLs and import libraries
are staged into `./build`, deploy it as a unit (Windows finds the DLLs next to the .exe).
zig statically links its own C/C++ runtime, so no other runtime DLLs are needed.

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
  -port string
        port of http API (default ":1667")
  -tls
        use tls, read cert.pem and key.pem from same folder
  -wake
        Keep inventory state and keep all transponders awake, will not be able to read tag content (default true)
```

Connection type is picked from the flags: BLE (`-bleMac`) > serial (`-comPort`) > TCP
(`-axeHost`/`-axePort`) > USB (auto scan for a plugged reader, default).

Application fires up a http server and mounts optional web content from ./html folder

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
