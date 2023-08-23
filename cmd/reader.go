package main

/*
#cgo CFLAGS: -I../drivers -g -Wall
#cgo linux LDFLAGS: -L../drivers/linux -lfeusb -lfetcp -lfeisc
#cgo windows LDFLAGS: -L../drivers/vc141 -lfeusb -lfetcp -lfeisc
#cgo android LDFLAGS: -L../drivers/arm64-v8a -lfetcp -lfeusb -lfeisc -lfecom -lusb1.0
#cgo arm64 LDFLAGS: -L../drivers/android/arm64-v8a -lfetcp -lfeusb -lfeisc -lfecom -lusb1.0
#cgo armv7-a LDFLAGS: -L../drivers/armv7-a -lfetcp -lfeusb -lfeisc -lfecom -lstdc++ -lusb-1.0
#cgo armv7-a CFLAGS: -mfloat-abi=hard -mfpu=vfp -mtls-dialect=gnu -march=armv7-a
//#cgo arm LDFLAGS: -L../drivers/arm -lfeudp -lfeusb -lfeisp
//#cgo arm CFLAGS: -mfloat-abi=hard -mfpu=vfp -march=armv6+fp
#include <stdlib.h>
#include "../drivers/feusb.h"
#include "../drivers/feisc.h"
#include "../drivers/fetcp.h"
#include "../drivers/libusb.h"
*/
import "C"
import (
	"errors"
	"fmt"
	"strconv"
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

	// Commands
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
)

type Reader struct {
	StrHandle    *C.char
	PortHandle   C.int
	ReaderHandle C.int
	Serial       string
	IntSerial    C.long
	Name         string
	Family       string
	ReadInvFail  uint64
	ReadInvSucc  uint64
	ReadTagFail  uint64
	ReadTagSucc  uint64
	WriteTagSucc uint64
	WriteTagFail uint64
	WriteAFISucc uint64
	WriteAFIFail uint64
}

func newReader(iPortHandle C.int) *Reader {
	iReaderHandle := C.FEISC_NewReader(iPortHandle)
	// err handling
	r := Reader{PortHandle: iPortHandle, ReaderHandle: iReaderHandle}
	var resBuf []C.char
	resBuf = make([]C.char, 56)
	dn := C.CString("DeviceName")
	dId := C.CString("Device-ID")
	dFn := C.CString("FamilyName")
	defer C.free(unsafe.Pointer(dId))
	defer C.free(unsafe.Pointer(dFn))
	defer C.free(unsafe.Pointer(dn))
	_ = C.FEUSB_GetScanListPara(0, dn, &resBuf[0])
	r.Name = C.GoString(&resBuf[0])
	_ = C.FEUSB_GetScanListPara(0, dId, &resBuf[0])
	r.Serial = C.GoString(&resBuf[0])
	_ = C.FEUSB_GetScanListPara(0, dFn, &resBuf[0])
	i, _ := strconv.ParseInt(r.Serial, 16, 0)
	r.IntSerial = C.long(i)
	r.Family = C.GoString(&resBuf[0])

	//_ = C.FEUSB_GetScanListPara(0, C.CString("DeviceHnd"), &sDeviceHandle[0])
	//_ = C.FEUSB_GetScanListPara(0, C.CString("Present"), &sDevicePresence[0])
	/* needed for newer readers. "Standard" is for readers pre 101 */
	_ = C.FEISC_SetReaderPara(r.ReaderHandle, C.CString("FrameSupport"), C.CString("Advanced"))
	return &r
}

func (r *Reader) ReadInventory() ([]byte, error) {
	var reqBuf []C.uchar
	var resBuf []C.uchar
	var l C.int
	reqBuf = []C.uchar{ISO15693_INVENTORY, 0x00}
	//resBuf = make([]C.uchar, 1024)
	resBuf = make([]C.uchar, 512)
	//defer C.free(unsafe.Pointer(&reqBuf))
	//defer C.free(unsafe.Pointer(&resBuf))
	//l := C.int(0) // pointer to data length in response

	// read inventory - uint8 byte response
	// FEISC_0xB0_ISOCmd(handle, address, request, reqlength, resp, resplength, resp format (0=bytes, 2=hex))
	//iRes, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0x00, &reqBuf[0], C.int(2), &resBuf[0], &l, 0)
	_, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(2), &resBuf[0], &l, 0)
	b := C.GoBytes(unsafe.Pointer(&resBuf[0]), l)
	return b, err
}

func (r *Reader) ReadTagContent(t *Tag) ([]byte, error) {
	var reqBuf []C.uchar
	var resBuf []C.uchar
	var l C.int
	reqLen := 12
	reqBuf = make([]C.uchar, reqLen)
	reqBuf[0] = C.uchar(ISO15693_READ_BYTES)
	reqBuf[1] = C.uchar(0x01)
	for i := 0; i < len(t.Id); i++ {
		reqBuf[i+2] = C.uchar(t.Id[i])
	}
	reqBuf[10] = C.uchar(0x00) // start byte
	reqBuf[11] = C.uchar(0x09) // 9 blocks of four bytes
	resBuf = make([]C.uchar, 64)
	//iRes, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(reqLen), &resBuf[0], &l, 0)
	_, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(reqLen), &resBuf[0], &l, 0)
	b := C.GoBytes(unsafe.Pointer(&resBuf[0]), l)
	return b, err
}

func (r *Reader) GetSystemInformation(t *Tag) {
	var reqBuf []C.uchar
	var resBuf []C.uchar
	reqLen := 2 + len(t.Id)
	reqBuf = make([]C.uchar, reqLen)
	reqBuf[0] = C.uchar(ISO15693_SYSINFO)
	reqBuf[1] = C.uchar(0x01) // addressed mode
	for i := 0; i < len(t.Id); i++ {
		reqBuf[i+2] = C.uchar(t.Id[i])
	}

	var l C.int

	resBuf = make([]C.uchar, 64)

	// Retry 5 times or give up
	for t := 0; t < 6; t++ {
		// FEISC_0xB0_ISOCmd(handle, address, request, reqlength, resp, resplength, resp format (0=bytes, 2=hex))
		iRes, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(reqLen), &resBuf[0], &l, 0)
		if err != nil && err.Error() != ErrResourceTempUnavailable.Error() && iRes != C.int(0) {
			time.Sleep(time.Millisecond * 50)
			continue
		}
		b := C.GoBytes(unsafe.Pointer(&resBuf[0]), l)
		fmt.Println(string(b))
		/*
			RESPONSE-DATA
			5 		6...13 	14 	15...16 	17
			DSFID 	UID 	AFI MEM-SIZE 	IC-REF <-ISO
		*/

		break
	}

}

/*
Write Tag Content:
0x24 Write cmd
0x01 adressed mode
8bytes  uid
0x00 start block
0x09 num blocks
0x04 block size
n*4bytes data blocks
*/
func (r *Reader) WriteTagContent(t Tag) ([]byte, error) {
	var reqBuf []C.uchar
	var resBuf []C.uchar
	var resLen C.int
	var err error
	bs, err := t.Content.ToBytes()
	if err != nil {
		return bs, err
	}

	reqLen := 13 + len(bs)
	reqBuf = make([]C.uchar, reqLen)
	reqBuf[0] = C.uchar(ISO15693_WRITE_BYTES)
	reqBuf[1] = C.uchar(0x01)
	for i := 0; i < len(t.Id); i++ {
		reqBuf[i+2] = C.uchar(t.Id[i])
	}
	reqBuf[10] = C.uchar(0x00) // DB-ADR:  start block
	reqBuf[11] = C.uchar(0x09) // DN-N:    9 blocks
	reqBuf[12] = C.uchar(0x04) // DB-SIZE: block size 4 bytes
	for i := 0; i < len(bs); i++ {
		reqBuf[13+i] = C.uchar(bs[i])
	}
	resBuf = make([]C.uchar, 64)
	//iRes, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(reqLen), &resBuf[0], &l, 0)

	/* Retry 5 times or give up */
	for t := 0; t < 6; t++ {
		if t == 5 {
			atomic.AddUint64(&r.WriteTagFail, 1)
			return []byte{}, errors.New("Timeout waiting for RFID")
		}
		time.Sleep(time.Millisecond * 100)
		resBytes, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0x00, &reqBuf[0], C.int(reqLen), &resBuf[0], &resLen, 0)
		if resBytes == C.int(-1130) {
			time.Sleep(time.Millisecond * 100)
			fmt.Printf("RETRYING WRITE... %d\n", t)
			continue
		}
		if err != nil {
			// Ignore resource not available error
			if err.Error() != ErrResourceTempUnavailable.Error() {
				atomic.AddUint64(&r.WriteTagFail, 1)
				return []byte{}, err
			}
		}
		break
	}
	atomic.AddUint64(&r.WriteTagSucc, 1)
	b := C.GoBytes(unsafe.Pointer(&resBuf[0]), resLen)
	return b, err

}

/*
activate AFI - cmd: 18, code: 27, data: 0x07
deactivate AFI - cmd: 18, cmd_code: 27, data: 0xC2
*/
func (r *Reader) WriteAFIByte(t Tag, afi byte) error {
	var reqBuf []C.uchar
	var resBuf []C.uchar
	var l C.int
	reqLen := 11
	reqBuf = make([]C.uchar, reqLen)
	reqBuf[0] = C.uchar(ISO15693_WRITE_AFI)
	reqBuf[1] = C.uchar(0x01)
	for i := 0; i < len(t.Id); i++ {
		reqBuf[i+2] = C.uchar(t.Id[i])
	}
	reqBuf[10] = C.uchar(afi)
	resBuf = make([]C.uchar, 8)

	var err error
	var iRes C.int
	// Retry 5 times or give up
	for t := 0; t < 6; t++ {
		iRes, err = C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(reqLen), &resBuf[0], &l, 0)
		if err != nil && err.Error() != ErrResourceTempUnavailable.Error() && iRes != C.int(0) {
			if t == 5 {
				atomic.AddUint64(&r.WriteAFIFail, 1)
				return err
			}
			time.Sleep(time.Millisecond * 50)
			continue
		}
		atomic.AddUint64(&r.WriteAFISucc, 1)
		return nil
	}
	return err
}

func (r *Reader) ResetToReady() error {
	var reqBuf []C.uchar
	var resBuf []C.uchar
	var l C.int

	reqBuf = []C.uchar{ISO15693_RESET_TO_READY, 0x00} /* RESET TO READY [0xB0] request - wake up transponders */
	resBuf = make([]C.uchar, 56)
	_, err := C.FEISC_0xB0_ISOCmd(r.ReaderHandle, 0xFF, &reqBuf[0], C.int(2), &resBuf[0], &l, 0)
	return err
}

func (r *Reader) ReadTagsInRange(s *server) map[string]Tag {
	now := time.Now()
	b, err := r.ReadInventory()
	if err != nil {
		// don't count these, they come always
		if err.Error() != ErrResourceTempUnavailable.Error() {
			s.Log.Debugf("ERROR READING INVENTORY: %v", err)
			atomic.AddUint64(&r.ReadInvFail, 1)
		}
	}
	s.Log.Debugf("INVENTORY TIMING: %s", time.Since(now))

	inv, err := getInventory(b)
	if err != nil {
		if err.Error() != ErrInventoryEmpty.Error() {
			s.Log.Debugf("ERROR GETTING INVENTORY: %v", err)
			atomic.AddUint64(&r.ReadInvFail, 1)
		}
	} else {
		atomic.AddUint64(&r.ReadInvSucc, 1)
	}
	if s.keepTranspondersAwake {
		_ = r.ResetToReady()
	}

	return inv.Process(s)
}

/*
Overwrite barcode on single tag
*/

func (r *Reader) WriteTagBarcode(s *server, tagId, barcode string) (Tag, error) {
	now := time.Now()
	s.mu.Lock()
	tag := s.inventory[tagId]
	s.mu.Unlock()
	tag.Content.Barcode = barcode
	_, err := r.WriteTagContent(tag)
	if err != nil {
		// don't count these, they come always
		if err.Error() != ErrResourceTempUnavailable.Error() {
			s.Log.Debugf("ERROR READING INVENTORY: %v", err)
			return tag, err
		}
	}
	s.mu.Lock()
	s.inventory[tagId] = tag
	s.mu.Unlock()
	s.Log.Debugf("WRITE TIMING: %s", time.Since(now))
	return tag, nil
}

/*
TODO:

	Might need to read inventory before writing, so we confirm right number of tags
*/
func (r *Reader) WriteToTagsInRange(s *server, barcode string) (map[string]Tag, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	l := len(s.inventory)
	c := 0
	for id, tag := range s.inventory {
		c++
		tc := TagContent{
			SeqNum:   uint8(c),
			NumItems: uint8(l),
			Barcode:  barcode,
			Country:  "NO",       // hard coded for now
			Library:  "02030000", // hard coded for now
		}
		tag.Content = tc
		_, err := r.WriteTagContent(tag)
		if err != nil {
			// don't count these, they come always
			if err.Error() != ErrResourceTempUnavailable.Error() {
				s.Log.Debugf("ERROR READING INVENTORY: %v", err)
				return s.inventory, err
			}
		}
		s.inventory[id] = tag
	}

	s.Log.Debugf("WRITE INVENTORY TIMING: %s", time.Since(now))
	if c == l {
		return s.inventory, nil
	} else {
		return s.inventory, errors.New("Wrong count of written tags")
	}
}
