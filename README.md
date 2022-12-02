# Feiging

Small project for examining the Feig RFID hardware and building an integration and easy communication/control system.

## Documentation

Read more in ./docs folder


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

## HTML interface

A simple Web Component allows interaction with reader and sends scans top spore
