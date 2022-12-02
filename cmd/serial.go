package main

/*
 * Feig USBSerial client
 * baud: 38400
 * parity: none
 * data bits: 8
 * stop bits: 1

 * [0x52] baud detector sequence
 * 02  00          08          FF   52      00      4A C3
 * STX ALENGTH/MSB ALENGTH/CSB ADDR COMMAND STATUS? CRC16

 * [0x66] Get Reader Info
 * 02  00 08   FF   66      00   4A C4
 */

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/tarm/serial"
)

type rInfo struct {
	Status                    string
	Swrev, Drev, Rxbuf, Txbuf uint16
	Usb, OnePointTwoWatt      bool
}

type Serial struct {
	Port        *serial.Port
	mode        modeType
	ReadInvFail uint64
	ReadInvSucc uint64
	ReadTagFail uint64
	ReadTagSucc uint64
	sync.Mutex  // inherit Lock/Unlock from sync
}

func (s *Serial) Init() {
	c := &serial.Config{
		Name:        "/dev/ttyUSB0",
		Baud:        38400,
		ReadTimeout: time.Millisecond * 500,
		Parity:      'E',
		Size:        8,
		StopBits:    1,
	}
	sp, err := serial.OpenPort(c)

	if err != nil {
		log.Fatalf("Error opening serial port: %s", err)
	} else {
		log.Printf("Opened serial connection at %s\n", "/dev/ttyUSB0")
		defer sp.Close()
	}

	log.Println("RUNNING INITIAL COMMANDS")
	s.Dispatch(FIRST_DEVICE, []byte{CMD_BAUDRATE, 0x00})
	d, _ := s.Read()
	if !bytes.Equal(d, []byte{0x02, 0x00, 0x08, 0x00, 0x52, 0x00, 0xB9, 0x05}) {
		log.Fatal("BAUDRATE ERROR, GIVING UP!")
	}
	log.Printf("BAUDRATE OK << % 02X", d)

	s.Dispatch(BCAST, []byte{CMD_SW_VERSION})
	d, _ = s.Read()
	log.Printf("SOFTWARE VERSION OK << % 02X", d)

	s.Dispatch(BCAST, []byte{CMD_GET_READER_INFO, 0x00}) // General reader and firmware info
	d, _ = s.Read()
	log.Printf("READER FIRMWARE OK << % 02X", d)
}

/*
 * SOFTWARE VERSION / READER INFO 0x65 / 0x66
 */

// status, sw-rev(2), d-rev, hwtype, sw-type, tr-type(2), rxbuf(2), txbuf(2)
func getSerialReaderInfo(res []byte) (*rInfo, error) {
	if len(res) < 19 {
		return &rInfo{}, errors.New("SOFTWARE VERSION RESPONSE: Not enough bytes")
	}
	/* TODO: Get Reader info
	s.dispatch(BCAST, []byte{CMD_GET_READER_INFO, 0x00}) // General reader and firmware info
	d, _ := s.Read()
	ri, _ := getReaderInfo(d)
	*/
	return &rInfo{
		Status:          respStatus[res[5]],
		Swrev:           btou16(res[6:8]),
		Drev:            uint16(res[8]),
		Usb:             res[9]&1 == 0, //bit 1 = 0
		OnePointTwoWatt: res[9]&2 == 1, // bit 2 = 1
		Rxbuf:           btou16(res[10:12]),
		Txbuf:           btou16(res[12:14]),
	}, nil
}

// Full cmd is STX + LENGTH + ADDR + CMD + STATUS + CRC16
func (s *Serial) Dispatch(addr byte, cmd []byte) error {
	msglen := 6 + len(cmd) // STX + LENGTH + ADDR + CRC = 6
	tx := make([]byte, 0)
	tx = append(tx, STX)
	tx = append(tx, u16tob(uint16(msglen))...)
	tx = append(tx, addr)
	tx = append(tx, cmd...)
	crc := crc16(tx, CRCTable)
	//fmt.Printf("CRC: % 02X\n", crc)
	tx = append(tx, crc...)
	log.Printf(">> % 02X\n", tx)
	time.Sleep(10 * time.Millisecond)
	n, err := s.Port.Write(tx)
	if err != nil {
		log.Printf("Error writing to serial port: %s", err)
		return err
	}
	if n != len(tx) {
		log.Printf("Wrong number of bytes written, wanted %d, got %d\n", len(tx), n)
	}

	return nil
}

// sync reader
func (s *Serial) Read() ([]byte, error) {
	// Receive reply, should have STX, LENGTH, CSUM
	// Need to verify length of read as bytes come in various chunks
	time.Sleep(10 * time.Millisecond)

	buf := make([]byte, 128)
	data := make([]byte, 0, 1024) // 1k should suffice

	for {
		n, _ := s.Port.Read(buf)
		data = append(data, buf[:n]...)
		if len(data) > 3 && len(data) == int(btou16(data[1:3])) {
			break
		}
	}

	//log.Printf("FULL DATA: << % 02X\n", data)
	return data, nil
}

// sync read tags, need to get inventory then read one tag at a time
func (s *Serial) startReadTagsLoop(srv *server) {
	// inventory check, TODO: if resp status = 0x94 More data available - read more with mode = 0x01
	t := time.Tick(500 * time.Millisecond)
	for _ = range t {
		s.ReadTagsInRange(srv)
	}
}

func (s *Serial) stopReadTagsLoop() {
}

func (s *Serial) ReadTagsInRange(srv *server) map[string]Tag {
	now := time.Now()
	b, err := s.ReadInventory()
	if err != nil {
		// don't count these, they come always
		if err.Error() != ErrResourceTempUnavailable.Error() {
			fmt.Printf("ERROR READING INVENTORY: %v", err)
			atomic.AddUint64(&s.ReadInvFail, 1)
		}
	}
	fmt.Printf("INVENTORY TIMING: %s", time.Since(now))

	if len(b) == 0 {
		return nil
	}
	inv, err := s.GetInventory(b)
	if err != nil {
		fmt.Printf("ERROR GETTING INVENTORY: %v", err)
		atomic.AddUint64(&s.ReadInvFail, 1)
	}
	atomic.AddUint64(&s.ReadInvSucc, 1)
	/*
		if s.keepTranspondersAwake {
			_ = r.ResetToReady()
		}
	*/
	return inv.Process(srv)
}

/*
 * INVENTORY 0xB001
 * Might need Reader / Inventory interface, as bytes are slightly different
   ReadInventory()
   ReadTagData()
   GetInventory()
   GetTagData()
*/

func (s *Serial) ReadInventory() ([]byte, error) {
	s.Dispatch(FIRST_DEVICE, []byte{CMD_ISO15693, ISO15693_INVENTORY, 0x01}) // Inventory
	d, err := s.Read()
	if err != nil {
		return []byte{}, err
	}
	return d, nil
}

// status, sw-rev(2), d-rev, hwtype, sw-type, tr-type(2), rxbuf(2), txbuf(2)
func (s *Serial) GetInventory(res []byte) (*Inventory, error) {
	if len(res) < 8 {
		return &Inventory{}, errors.New("INVENTORY RESPONSE: Not enough bytes")
	}
	// TODO: if status = 0x94 More data available - read more with mode = 0x01

	tags := getTags(res[7:])
	return &Inventory{
		Status: respStatus[res[5]],
		Count:  uint16(res[6]),
		Tags:   tags,
	}, nil
}

func (s *Serial) ReadTagData(t *Tag) ([]byte, error) {
	cmd := []byte{CMD_ISO15693, ISO15693_READ_BYTES, 0x01} // 0x23, 0x01: Read Multiple blocks
	cmd = append(cmd, t.Id...)
	cmd = append(cmd, []byte{0x00, 0x0A}...) // Read 10 blocks from 0x00
	s.Dispatch(FIRST_DEVICE, cmd)
	d, _ := s.Read()
	return d, nil
}

// tag content
func (s *Serial) GetTagData(res []byte) ([]byte, error) {
	if len(res) < 22 {
		return nil, errors.New("TAG READ DATA: Not enough bytes")
	}
	lim := 5
	var chunk []byte
	blks := res[8 : len(res)-2]
	data := make([]byte, 0)
	for len(blks) >= lim {
		chunk, blks = blks[:lim], blks[lim:]
		// Skip first byte = unused security byte and reverse block (4bytes)
		blk := reverseBytes(chunk[1:])
		//fmt.Printf("CHUNK: % 02X\n", blk)
		data = append(data, blk...)
	}
	return data, nil
}
