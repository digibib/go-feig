package main

// The FEDM SDK is linked via -lfedm; the unversioned libfedm.so symlink is
// created in ./build by 'make install-fedm-libs'
// (fedm/linux-x64/bin/release/install-linux-libs.sh), which 'make build' runs
// before compiling. Build with make, or run that target first.
//
// At runtime the SDK's shared libraries are resolved from the directory
// containing the binary (-Wl,-rpath,$ORIGIN), so deploy ./build/ as a unit.
// --disable-new-dtags records a legacy DT_RPATH instead of DT_RUNPATH:
// RUNPATH only covers this binary's direct deps, not libfedm.so's transitive
// NEEDED libs (libfeisp.so.1, ...); RPATH covers the whole closure.
// The -Wl flags live here (not in the Makefile) so no shell ever expands $ORIGIN.
//
// Windows: the SDK (win-vc143-x64) is MSVC-ABI (MSVC name mangling,
// 40-byte std::string), so the shim must be built with the MSVC ABI to
// call it correctly. The supported build is MSVC (cl) on a Windows
// machine with the 'msvc' build tag: see reader_msvc.go and
// scripts/build-msvc.bat. With /MD (cl's default) the exe and the FEIG
// DLLs share the same msvcp140.dll heap, so std::string objects returned
// by the DLLs are safe to destroy here.
// zig cannot do this from a Linux host: zig's x86_64-windows-msvc target
// provides no MSVC libc, and the MinGW target has the wrong ABI (Itanium
// mangling, 32-byte std::string). reader_zig.go keeps the zig (MinGW ABI)
// flags for a hypothetical MinGW/clang (Itanium) build of the Windows SDK.
// -DFEDMDLL (both windows paths) selects the __declspec(dllexport)
// branch of FedmBase.h (the consumer/dllimport branch is the #else),
// which keeps references as plain symbols that the import lib thunks
// resolve.

/*
#cgo linux CXXFLAGS: -I${SRCDIR}/../fedm/linux-x64/include -I${SRCDIR}/../fedm/linux-x64/include/fedm -g -Wall
#cgo linux LDFLAGS: -L${SRCDIR}/../build -lfedm -lstdc++ -lpthread -Wl,-rpath-link,${SRCDIR}/../build -Wl,-rpath,$ORIGIN -Wl,--disable-new-dtags
// windows #cgo flags live in reader_zig.go (tags: windows && !msvc) and
// reader_msvc.go (tag: msvc)
#include <stdlib.h>
#include "fedm_shim.h"
*/
import "C"

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

const (
	CCITT_REVERSED = 0x1021
	CCITT_FORWARD  = 0x8408
	XMODEM2        = 0x8408
	STX            = 0x02
	BCAST          = 0xFF
	FIRST_DEVICE   = 0x00

	// Legacy FEIG protocol commands, still used by serial.go and its tests
	CMD_BAUDRATE        = 0x52 // kap 6.1 (s.67)
	CMD_CTRL_SOFT_RESET = 0x63 // kap 6.3 (s.68)
	CMD_CTRL_SYST_RESET = 0x64 // kap 6.4 (s.69)
	CMD_SW_VERSION      = 0x65 // kap 6.5 (s.69)
	CMD_GET_READER_INFO = 0x66 // kap 6.6 (s.71)
	CMD_READ_CONFIG     = 0x80 // kap 6.1 (s.64-)
	CMD_WRITE_CONFIG    = 0x81 // kap 6.1 (s.66-)
	CMD_SYSTEM_TIMER    = 0x86
	CMD_ISO15693        = 0xB0 // kap 7 (s.82-)

	ISO15693_INVENTORY      = 0x01 // MOD[1]
	ISO15693_STAY_QUIET     = 0x02 // MOD[1], UID[8]
	ISO15693_READ_BYTES     = 0x23 // MOD[1], UID[8],BloccoIniziale[1],NBlocchi[1]
	ISO15693_WRITE_BYTES    = 0x24 // MOD[1], UID[8],BloccoIniziale[1],NBlocchi[1],{Blocco[4]}* NBlocchi}
	ISO15693_SELECT         = 0x25 // MOD[1], UID[8]
	ISO15693_RESET_TO_READY = 0x26 // MOD[1], UID[8]
	ISO15693_WRITE_AFI      = 0x27 // MOD[1], UID[8],AFI[1]
	ISO15693_LOCK_AFI       = 0x28 // MOD[1], UID[8]
	ISO15693_WRITE_DSFID    = 0x29 // MOD[1], UID[8],DSFID[1]
	ISO15693_LOCK_DSFID     = 0x2A // MOD[1], UID[8],DSFID[1]
	ISO15693_SYSINFO        = 0x2B // MOD[1], UID[8]

	// ISO-14443 Specific High level commands (FEISC_0xB0_ISOCmd)
	ISO14443_INVENTORY   = 0x01 // MOD[1]
	ISO14443_SELECT      = 0x25 // MOD[1], UID[8]
	ISO14443_READ_BYTES  = 0x23 // MOD[1], UID[8],BloccoIniziale[1],NBlocchi[1]
	ISO14443_WRITE_BYTES = 0x24 // MOD[1], UID[8],BloccoIniziale[1],NBlocchi[1]

	// Status bytes
	STATUS_OK                         = 0x00
	STATUS_NO_TRANSPONDER             = 0x01
	STATUS_CRC_ERROR                  = 0x02
	STATUS_WRITE_ERROR                = 0x03
	STATUS_ADDRESS_ERROR              = 0x04
	STATUS_WRONG_TRANSPONDER          = 0x05
	STATUS_WRONG_EEPROM               = 0x10
	STATUS_PARAMETER_LENGHT_ERROR     = 0x11
	STATUS_FIRMWARE_ACTIVATION_NEEDED = 0x17
	STATUS_UNKNOWN_COMMAND            = 0x80
	STATUS_PROTOCOL_ERROR             = 0x81
	STATUS_UNSUPPORTED_COMMAND        = 0x82
	STATUS_RF_COMMUNICATION_ERROR     = 0x83
	STATUS_RF_WARNING                 = 0x84
	STATUS_NO_VALID_DATA              = 0x92
	STATUS_BUFFER_OVERFLOW            = 0x93
	STATUS_MORE_DATA_AVAILABLE        = 0x94
	STATUS_TAG_ERROR                  = 0x95

	maxTagsPerInventory = 256
	tagContentBytes     = 36 // 9 blocks x 4 bytes
)

var respStatus = map[byte]string{
	STATUS_OK:                         "OK",
	STATUS_NO_TRANSPONDER:             "No transponder",
	STATUS_CRC_ERROR:                  "CRC Error",
	STATUS_WRITE_ERROR:                "Write Error",
	STATUS_ADDRESS_ERROR:              "Address Error",
	STATUS_WRONG_TRANSPONDER:          "Wrong Transponder",
	STATUS_WRONG_EEPROM:               "Wrong EEPROM",
	STATUS_PARAMETER_LENGHT_ERROR:     "Wrong Parameter length",
	STATUS_FIRMWARE_ACTIVATION_NEEDED: "Firmware Activation Needed",
	STATUS_UNKNOWN_COMMAND:            "Unknown Command",
	STATUS_PROTOCOL_ERROR:             "Protocol Error",
	STATUS_UNSUPPORTED_COMMAND:        "Unsupported Command",
	STATUS_RF_COMMUNICATION_ERROR:     "RF Communication Error",
	STATUS_RF_WARNING:                 "RF Warning",
	STATUS_NO_VALID_DATA:              "No valid data",
	STATUS_BUFFER_OVERFLOW:            "Buffer Overflow",
	STATUS_MORE_DATA_AVAILABLE:        "More data available",
	STATUS_TAG_ERROR:                  "Tag Error",
}

var (
	ErrResourceTempUnavailable error = errors.New("resource temporarily unavailable")
	ErrInventoryEmpty          error = errors.New("inventory empty")
	ErrNotConnected            error = errors.New("rfid reader not connected")
	ErrTagNotFound             error = errors.New("tag not found in last inventory")
)

// BLE scan result item, as returned by /ble/scan
type BleItem struct {
	Mac        string `json:"mac"`
	DeviceId   string `json:"deviceId"`
	ReaderType string `json:"readerType"`
	New        bool   `json:"new"`
}

// Reader wraps the FEIG FEDM SDK (via the cgo shim in fedm_shim.cpp)
type Reader struct {
	mu sync.Mutex // serializes all reader operations, top level methods lock it

	Connected  bool
	ConnType   string // "usb" | "tcp" | "com" | "ble"
	Serial     string // reader device ID (hex)
	Name       string // reader type
	FwVersion  string // reader firmware version
	LibVersion string // FEDM library version
	ReadInvFail  uint64
	ReadInvSucc  uint64
	ReadTagFail  uint64
	ReadTagSucc  uint64
	WriteTagSucc uint64
	WriteTagFail uint64
	WriteAFISucc uint64
	WriteAFIFail uint64
}

func newReader() *Reader {
	r := Reader{}
	buf := make([]C.char, 256)
	C.fedm_lib_version(&buf[0], C.int(len(buf)))
	r.LibVersion = C.GoString(&buf[0])
	return &r
}

/* UTILITY FUNCTIONS */

func shimErrorText() string {
	buf := make([]C.char, 256)
	C.fedm_last_error_text(&buf[0], C.int(len(buf)))
	return C.GoString(&buf[0])
}

// pluginLoadHint annotates SDK errors where one of the on-demand transport
// plugins failed to load. The BLE plugin (libfeble.so) is not part of the
// FEDM SDK 7.1.0 linux package, so this is what BLE failures look like until
// the library is obtained from FEIG.
func pluginLoadHint(s string) string {
	if strings.Contains(s, "Cannot load plugin") {
		return s + " (missing FEBLE plugin library libfeble.so - not included in the FEDM SDK 7.1.0 linux package, obtain from FEIG)"
	}
	return s
}

func (r *Reader) IsConnected() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.Connected
}

/* CONNECTION */

func (r *Reader) connect(connType string, cRet C.int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if cRet != 0 {
		return fmt.Errorf("connect (%s): %s", connType, pluginLoadHint(shimErrorText()))
	}
	r.Connected = true
	r.ConnType = connType
	buf := make([]C.char, 256)
	C.fedm_reader_serial(&buf[0], C.int(len(buf)))
	r.Serial = C.GoString(&buf[0])
	C.fedm_reader_name(&buf[0], C.int(len(buf)))
	r.Name = C.GoString(&buf[0])
	C.fedm_reader_fwversion(&buf[0], C.int(len(buf)))
	r.FwVersion = C.GoString(&buf[0])
	return nil
}

// ConnectUsb scans for a plugged USB reader and connects to the first one found
func (r *Reader) ConnectUsb() error {
	return r.connect("usb", C.fedm_connect_usb())
}

// ConnectTcp connects to a reader at the given host and port (e.g. a feiging axe)
func (r *Reader) ConnectTcp(host string, port int) error {
	chost := C.CString(host)
	defer C.free(unsafe.Pointer(chost))
	return r.connect("tcp", C.fedm_connect_tcp(chost, C.int(port)))
}

// ConnectCom connects to a reader on a serial COM port (frame: 8E1 | 8N1 | 8O1)
func (r *Reader) ConnectCom(port, frame string, baud int) error {
	cport := C.CString(port)
	defer C.free(unsafe.Pointer(cport))
	cframe := C.CString(frame)
	defer C.free(unsafe.Pointer(cframe))
	return r.connect("com", C.fedm_connect_com(cport, cframe, C.int(baud)))
}

// ConnectBle connects to a reader over Bluetooth Low Energy using its MAC address
func (r *Reader) ConnectBle(mac string) error {
	cmac := C.CString(mac)
	defer C.free(unsafe.Pointer(cmac))
	return r.connect("ble", C.fedm_connect_ble(cmac))
}

// Disconnect closes the connection to the reader
func (r *Reader) Disconnect() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	C.fedm_disconnect()
	r.Connected = false
	return nil
}

/* BLE DISCOVERY */

// BleStartDiscover starts the Bluetooth LE discovery, idempotent
func (r *Reader) BleStartDiscover() error {
	if cRet := C.fedm_ble_start_discover(); cRet != 0 {
		buf := make([]C.char, 256)
		C.fedm_ble_last_error(&buf[0], C.int(len(buf)))
		return fmt.Errorf("ble start: %s", pluginLoadHint(C.GoString(&buf[0])))
	}
	return nil
}

// BleStopDiscover stops the Bluetooth LE discovery
func (r *Reader) BleStopDiscover() error {
	if cRet := C.fedm_ble_stop_discover(); cRet != 0 {
		buf := make([]C.char, 256)
		C.fedm_ble_last_error(&buf[0], C.int(len(buf)))
		return fmt.Errorf("ble stop: %s", pluginLoadHint(C.GoString(&buf[0])))
	}
	return nil
}

// BleList drains the BLE discovery queue and returns the readers seen so far
func (r *Reader) BleList() []BleItem {
	n := int(C.fedm_ble_reader_count())
	items := make([]BleItem, 0, n)
	for i := 0; i < n; i++ {
		var it C.FedmBleItem
		if C.fedm_ble_pop(&it) != 0 {
			break
		}
		items = append(items, BleItem{
			Mac:        C.GoString(&it.mac[0]),
			DeviceId:   C.GoString(&it.deviceId[0]),
			ReaderType: C.GoString(&it.readerType[0]),
			New:        it.state == 1,
		})
	}
	return items
}

/* RFID OPERATIONS
 *
 * Top level methods lock r.mu, the do* helpers assume the lock is held.
 */

// doInventory performs an inventory and returns the tags in range
func (r *Reader) doInventory() (map[string]Tag, error) {
	if !r.Connected {
		return nil, ErrNotConnected
	}
	buf := make([]C.FedmTag, maxTagsPerInventory)
	n := C.fedm_inventory(&buf[0], C.int(len(buf)))
	if n < 0 {
		return nil, fmt.Errorf("inventory: %s", shimErrorText())
	}
	tags := make(map[string]Tag, int(n))
	for i := 0; i < int(n); i++ {
		id, err := hex.DecodeString(C.GoString(&buf[i].iddHex[0]))
		if err != nil || len(id) == 0 {
			continue
		}
		dsfid := buf[i].dsfid
		if dsfid < 0 {
			dsfid = 0
		}
		t := Tag{
			Trtype: uint16(buf[i].trType),
			Dfsid:  uint16(dsfid),
			Id:     id,
			Mac:    tagIDtoMAC(id),
		}
		tags[t.Mac] = t
	}
	return tags, nil
}

// doReadTagContent reads blocks 0..8 (36 bytes) of the given tag
func (r *Reader) doReadTagContent(t *Tag) ([]byte, error) {
	if !r.Connected {
		return nil, ErrNotConnected
	}
	out := make([]byte, tagContentBytes)
	n := C.fedm_tag_read((*C.uchar)(unsafe.Pointer(&t.Id[0])), C.int(len(t.Id)),
		(*C.uchar)(unsafe.Pointer(&out[0])), C.int(len(out)))
	if n < 0 {
		return nil, fmt.Errorf("tag read: %s", shimErrorText())
	}
	return out[:n], nil
}

// doWriteTagContent writes the tag content (blocks 0..8) to the given tag
func (r *Reader) doWriteTagContent(t Tag) error {
	bs, err := t.Content.ToBytes()
	if err != nil {
		return err
	}
	if len(bs) != tagContentBytes {
		return fmt.Errorf("tag write: wrong content length %d", len(bs))
	}
	// Retry a few times or give up, BLE and busy readers can be flaky
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Millisecond * 100)
		}
		cRet := C.fedm_tag_write((*C.uchar)(unsafe.Pointer(&t.Id[0])), C.int(len(t.Id)),
			(*C.uchar)(unsafe.Pointer(&bs[0])), C.int(len(bs)))
		if cRet >= 0 {
			return nil
		}
	}
	return fmt.Errorf("tag write: %s", shimErrorText())
}

// doWriteAFI performs a non-addressed (broadcast) write AFI, all tags in range
func (r *Reader) doWriteAFI(afi byte) error {
	if !r.Connected {
		return ErrNotConnected
	}
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Millisecond * 50)
		}
		if cRet := C.fedm_tag_write_afi(C.uchar(afi)); cRet >= 0 {
			return nil
		}
	}
	return fmt.Errorf("afi write: %s", shimErrorText())
}

// doResetToReady performs a non-addressed (broadcast) reset to ready
func (r *Reader) doResetToReady() error {
	if !r.Connected {
		return ErrNotConnected
	}
	if cRet := C.fedm_tag_reset_to_ready(); cRet < 0 {
		return fmt.Errorf("reset to ready: %s", shimErrorText())
	}
	return nil
}

/*
ReadTagsInRange reads the inventory and content of all new tags in range.
The current inventory is kept and tags out of range are removed.
*/
func (r *Reader) ReadTagsInRange(s *server) map[string]Tag {
	r.mu.Lock()
	defer r.mu.Unlock()

	tags, err := r.doInventory()
	if err != nil {
		// Keep the current inventory, don't wipe it on transient errors
		s.Log.Debugf("ERROR READING INVENTORY: %v", err)
		atomic.AddUint64(&r.ReadInvFail, 1)
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.inventory
	}
	atomic.AddUint64(&r.ReadInvSucc, 1)

	if s.keepTranspondersAwake {
		if err := r.doResetToReady(); err != nil {
			s.Log.Debugf("ERROR RESET TO READY: %v", err)
		}
	}

	return (&Inventory{Count: uint16(len(tags)), Tags: tags}).Process(s)
}

/*
WriteTagBarcode overwrites the barcode on a single tag in the current inventory
*/
func (r *Reader) WriteTagBarcode(s *server, tagId, barcode string) (Tag, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	s.mu.Lock()
	tag, ok := s.inventory[tagId]
	s.mu.Unlock()
	if !ok {
		return Tag{}, fmt.Errorf("tag %s not in inventory", tagId)
	}
	tag.Content.Barcode = barcode
	if err := r.doWriteTagContent(tag); err != nil {
		atomic.AddUint64(&r.WriteTagFail, 1)
		return tag, err
	}
	atomic.AddUint64(&r.WriteTagSucc, 1)
	s.mu.Lock()
	s.inventory[tagId] = tag
	s.mu.Unlock()
	s.Log.Debugf("WRITE TIMING: %s", time.Since(now))
	return tag, nil
}

/*
WriteToTagsInRange writes the barcode (with sequence number and total count)
to all tags in the current inventory
*/
func (r *Reader) WriteToTagsInRange(s *server, barcode string) (map[string]Tag, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	l := len(s.inventory)
	c := 0
	for id, tag := range s.inventory {
		c++
		tc := TagContent{
			SeqNum:   uint8(c),
			NumItems: uint8(l),
			Barcode:  barcode,
			Country:  "NO", // hard coded for now
			Library:  s.library,
		}
		tag.Content = tc
		if err := r.doWriteTagContent(tag); err != nil {
			atomic.AddUint64(&r.WriteTagFail, 1)
			s.Log.Debugf("ERROR WRITING INVENTORY: %v", err)
			return s.inventory, err
		}
		s.inventory[id] = tag
	}
	atomic.AddUint64(&r.WriteTagSucc, uint64(c))
	s.Log.Debugf("WRITE INVENTORY TIMING: %s", time.Since(now))
	if c == l {
		return s.inventory, nil
	}
	return s.inventory, errors.New("wrong count of written tags")
}

/*
WriteAFI turns the AFI alarm on or off on all tags in range (broadcast)
*/
func (r *Reader) WriteAFI(afi byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.doWriteAFI(afi); err != nil {
		atomic.AddUint64(&r.WriteAFIFail, 1)
		return err
	}
	atomic.AddUint64(&r.WriteAFISucc, 1)
	return nil
}
