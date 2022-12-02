# Deichman Library Feig RFID Integration

This document describes the integration points of this software against a running system.
Feig integration software is currently compiled for the following architectures and systems:

* x86_64 Windows
* x86_64 Linux
* arm64 Raspberry PI

But could easily cross-compile to other targets given the drivers for the system exist

## Server

The software runs a server on the USB (or Serial) connected machine:

    localhost, port 1667, optionally using TLS

Communication with the RFID transponders are done through a JSON API described below.
Two basic flows for communicating with the device are supported: polling or event-based

## API description

```
    GET /.status    server status endpoint
    GET /scan       scan inventory once
    GET /write      write to tags in range (param: barcode)
    GET /alarmOff   turn off AFI alarm on all tags in range
    GET /alarmOn    turn on AFI alarm on all tags in range

    GET /events/    eventsource subscription
    GET /start      start scan loop
    GET /stop       stop scan loop
    POST /spore     send inventory readings to spore (Koha specific api for logistics)
```
### Status endpoint

Get description of reader and info on read successes and failures, as well as:

    Client:         client IP
    Mode:           current mode of operation ("IDLE", "READ", "READONCE", "WRITE", "WRITEAFI", "SCAN")
    LastInventory:  Inventory of last reading

example: *GET /.status*

```JSON
{
  "Uptime": "9h21m1.891119464s",
  "Reader": {
    "StrHandle": null,
    "PortHandle": 268435457,
    "ReaderHandle": 1,
    "Serial": "117716D3",
    "IntSerial": 293017299,
    "Name": "ID ISC.MR101-U",
    "Family": "OBID i-scan Midrange",
    "ReadInvFail": 0,
    "ReadInvSucc": 12,
    "ReadTagFail": 0,
    "ReadTagSucc": 6,
    "WriteTagSucc": 0,
    "WriteTagFail": 0,
    "WriteAFISucc": 0,
    "WriteAFIFail": 0
  },
  "LastInventory": {},
  "Client": "10.173.65.31",
  "Mode": "IDLE"
}
```

### Single inventory scan

Single scan operation to get inventory and data of all tags in range. Used in polling mode.

example: *GET /scan*

```JSON
{
  "E0:04:01:50:33:86:07:AE": {
    "Trtype": 3,
    "Dfsid": 0,
    "Id": "4AQBUDOGB64=",
    "Mac": "E0:04:01:50:33:86:07:AE",
    "Content": {
      "SeqNum": 1,
      "NumItems": 1,
      "Barcode": "1003011860976002",
      "Crc": "L7A=",
      "Country": "NO",
      "Library": "02030000\u0000"
    }
  }
}
```

### Write tags endpoint

*GET /write*

Write operation used to write info to tag in range. Accepts only one query parameter: barcode
Will automatically write data to all tags in range following the RFID standard for Danish libraries:

http://biblstandard.dk/rfid/dk/rfid_data_model_for_libraries_february_2009.pdf

This includes the barcode, number of tags, sequence number, library and country, as well as computed crc.

example:

    GET /write?barcode=03011860976002

Response will either be a HTTP/1.1 200 OK, and a JSON object with the current tag, or a HTTP/1.1 400 Bad Request with String error


### Activate alarm

*GET /alarmOn*

Turn on AFI on all tags in range. Response is always 200 OK

### Deactivate alarm

*GET /alarmOff*

Turn on AFI on all tags in range. Response is always 200 OK


### Polling - not recommended for continuous checkin/checkout operations

Client communicates with simple operations:

    GET /scan

get full inventory at any given interval, but for stability no less than every 300ms is recommended.
Client software would then need to keep track of inventory and changes if to know when an item is removed from range or inserted into range.

### Event-based - recommended for continuous checkin/checkout operations

Using SSE (Server-Side Events) makes more sense in continuous checkin/checkout operations, i.e. a checkout machine or a staff desk.

Server supports the open standard API for EventSource: https://developer.mozilla.org/en-US/docs/Web/API/EventSource

Content-Type is "text/event-stream". Both web browser clients and local applications would support this as it is served on localhost, optionally with self-signed TLS if browser requires this.

Typical checkin flow is then:

1. client connects to eventsource API localhost:1667/events/
2. client software instantiates a session for checkin
3. client starts scan loop (*GET /start*)
4. client software registers new tags in range and handles media in respective manner in library software
5. client turns alarm on for all items in range (*GET /alarmOn*)
6. client software ends checkin session
7. client stops scan loop (*GET /stop*)

Example in javascript:

    // connect and establish eventsource connection
    const es = await new EventSource("localhost:1667/events/")

    // establish handlers for eventsource event types
    es.addEventListener("addTag", handleAddTagEventFunction)
    es.addEventListener("removeTag", handleRemoveTagEventFunction)
    es.addEventListener("error", (e) => { alert("Feil i kobling mot RFID!"); console.log(e) })
    es.addEventListener("open", (e) => { console.log("connected to RFID") })

Testing client using curl:

    curl localhost:1667/events/

```
    event: addTag
    data: {"Trtype":3,"Dfsid":0,"Id":"4AQBUDOGB64=","Mac":"E0:04:01:50:33:86:07:AE","Content":{"SeqNum":1,"NumItems":1,"Barcode":"1003011860976002","Crc":"L7A=","Country":"NO","Library":"02030000\u0000"}}

    event: removeTag
    data: {"Trtype":3,"Dfsid":0,"Id":"4AQBUDOGB64=","Mac":"E0:04:01:50:33:86:07:AE","Content":{"SeqNum":1,"NumItems":1,"Barcode":"1003011860976002","Crc":"L7A=","Country":"NO","Library":"02030000\u0000"}}
```

Consuming events is as easy as acting on event type, and parsing the JSON data containing tag info
