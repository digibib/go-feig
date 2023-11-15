# Feig RFID integration

Feig RFID hardware integration and API for simple implentation and control.

This software is released under MIT license from Deichman Public Library.

Short description: This is a service that exposes a simple API to communication with FEIG hardware, either connected by USB, Serial or TCP.
It encompasses the operations to read and write tags and AFI alarm on ISO15693 transponders using a FEIG device. It also wraps an HTTP eventsource
endpoint for easy use by any browser app. In addition it allows for embedding any HTTP web page if included under ``./cmd/html` folder.

## Installation and Requirements

go version 1.19 or later is required, as well as `make` and FEIG SDK drivers and header files for the expected system to run on (windows / linux 64bit or Raspberry PI).
Header files `feusb.h` etc. need to be placed under `drivers` or in system header folders.
Drivers need to be included under `drivers/<architecture>` or in system driver folders.

To build, e.g. for windows: run `make build_windows`
## Usage

```
  -debug
    	turn on verbose logging
  -port string
    	port of http API (default ":1666")
  -spore string
    	spore url to log rfid scans
  -wake
    	Keep inventory state and keep all transponders awake (default true)
```

Application fires up a http server and mounts web content from ./html folder

**API routes:**

```
    /.status 	server status endpoint
    /events/    eventsource subscription

    /scan    	scan inventory once
    /start 		start scan loop
    /stop 		stop scan loop
    /spore		send inventory readings to spore
    /write 		write to tags in range (param: barcode)
    /alarmOff 	turn off AFI alarm on all tags in range
    /alarmOn 	turn on AFI alarm on all tags in range
```

Basic flow is:

* inventory is fetched and kept in memory either by polling `/scan` or by activating scan loop with `/start`
* barcodes can be used to fetch and present information, e.g. from spore
* at any time a current inventory can be
    * rewritten: all tags in range are written to using sequence number and number of tags (`/write?barcode=1234567890`)
    * desensitized: (`/alarmOff`)
    * sensitized: (`/alarmOn`)
* `/.status` will at any time display uptime status, inventory and read success/failures

## Documentation

Read more in ./docs folder

## HTML interface

A simple Web Component allows interaction with reader and sends scans top spore
