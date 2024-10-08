package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"
)

type Inventory struct {
	Status string
	Count  uint16
	Tags   map[string]Tag
}

// Tags are exactly 10 bytes
type Tag struct {
	Trtype  uint16 // transistor type (1 byte)
	Dfsid   uint16 // Data Storage Family Identifier (1 byte)
	Id      []byte // 8 bytes
	Mac     string // string formatted ID (MAC)
	Content TagContent
}

type TagContent struct {
	SeqNum   uint8
	NumItems uint8 // number in sequence and number of items
	Barcode  string
	Crc      []byte
	Country  string
	Library  string
}

/* Tag Content Following Dansk standard
[0]: version(4bit) + type(4bit)
[1]: sequence number
[2]: number of items
[3:19]: id 16 bytes (barcode)
[19:21]: CRC of bytes 0-19 and 21-32
[21:23]: country
[23:32]: library
*/

func newTagContent(bs []byte) (TagContent, error) {
	tb, err := prepareReadTagBytes(bs)
	if err != nil {
		return TagContent{}, err
	}
	tc := TagContent{
		NumItems: tb[1],
		SeqNum:   tb[2],
		Barcode:  strings.TrimRight(string(tb[3:19]), "\u0000"),
		Crc:      tb[19:21],
		Country:  string(tb[21:23]),
		Library:  strings.TrimRight(string(tb[23:32]), "\u0000"),
	}

	// Strip leading "10" if the item belongs to Deichman (e.g. books before 2016 initated with 10)
	if tc.Country == "NO" && strings.HasPrefix(tc.Barcode, "10") && len(tc.Barcode) == 16 {
		tc.Barcode = strings.TrimPrefix(tc.Barcode, "10")
	}
	return tc, nil
}

func (tc *TagContent) ToBytes() ([]byte, error) {
	bs := make([]byte, 36)
	bs[0] = 0x11 // 17 (4bit version, 4bit type)
	bs[1] = tc.NumItems
	bs[2] = tc.SeqNum
	copy(bs[3:19], []byte(tc.Barcode))
	copy(bs[21:23], []byte(tc.Country))
	copy(bs[23:32], []byte(tc.Library))
	// Add crc
	csum_bytes := make([]byte, 32)
	copy(csum_bytes[0:19], bs[0:19])
	copy(csum_bytes[19:32], bs[21:34])
	crc := crc16(csum_bytes, CRCTable)
	copy(bs[19:21], crc)
	wb, err := prepareWriteTagBytes(bs)
	if err != nil {
		return []byte{}, err
	}
	return wb, nil
}

// take presently read inventory and diff against previous state
func (inv *Inventory) Process(s *server) map[string]Tag {
	now := time.Now()
	fmt.Println("PROCESSING INVENTORY...")
	knownIDs := make(map[string]bool, 0) // placeholder for tag IDS
	for k := range inv.Tags {
		knownIDs[k] = true
		fmt.Printf("TAG ID %s\n", k)
		if _, exists := s.inventory[k]; exists {
			fmt.Printf("TAG ALREADY READ: %s\n", k)
		} else {
			// Add to inventory, and read data
			fmt.Printf("NEW TAG ADDED: %s\n", k)
			tag := inv.Tags[k]
			//s.Reader.GetSystemInformation(&tag)
			d, err := s.Reader.ReadTagContent(&tag)
			if err != nil {
				if err.Error() != ErrResourceTempUnavailable.Error() {
					fmt.Printf("ERROR READING TAG DATA: %v\n", err)
					atomic.AddUint64(&s.Reader.ReadTagFail, 1)
				}
			}
			tc, err := newTagContent(d)

			if err != nil {
				fmt.Printf("ERROR PROCESSING TAG DATA: %v\n", err)
				atomic.AddUint64(&s.Reader.ReadTagFail, 1)
			} else {
				/* manually strip last initial '10' or last two bytes
				var bc []byte
				if string(tc[3:5]) == "10" {
					bc = tc[5:19]
				} else {
					bc = tc[3:17]
				}
				*/
				tag.Content = tc
				s.mu.Lock()
				s.inventory[k] = tag
				s.mu.Unlock()
				atomic.AddUint64(&s.Reader.ReadTagSucc, 1)
			}

			s.mu.Lock()
			b, err := json.Marshal(s.inventory[k])
			s.mu.Unlock()
			if err != nil {
				fmt.Printf("ERROR encoding json: %s\n", err)
			}
			msg := EsMsg{
				Event: "addTag",
				Data:  b,
			}
			go func() {
				s.broadcast <- msg
			}()

		}
	}
	fmt.Printf("ALL INVENTORY TAG READ TIMING: %s\n", time.Since(now))

	// remove tags no longer in range
	s.mu.Lock()
	for j := range s.inventory {
		if _, exists := knownIDs[j]; !exists {
			fmt.Printf("TAG NO LONGER IN RANGE, REMOVING: %s\n", j)
			b, err := json.Marshal(s.inventory[j])
			if err != nil {
				fmt.Printf("ERROR encoding json: %s\n", err)
			}
			msg := EsMsg{
				Event: "removeTag",
				Data:  b,
			}
			go func() {
				s.broadcast <- msg
			}()
			delete(s.inventory, j)
		}
	}
	s.mu.Unlock()
	fmt.Printf("CURRENT INVENTORY: %#v\n", s.inventory)
	return s.inventory
}

func getInventory(res []byte) (*Inventory, error) {
	if len(res) < 10 {
		return &Inventory{}, ErrInventoryEmpty
	}
	// TODO: if status = 0x94 More data available - read more with mode = 0x01

	tags := getTags(res[1:])
	return &Inventory{
		Status: respStatus[0x00], // fake this for now
		Count:  uint16(res[0]),
		Tags:   tags,
	}, nil
}

func getTags(buf []byte) map[string]Tag {
	// each tag is 10 bytes exactly: two status bytes and eight uid
	lim := 10
	var chunk []byte
	ts := make(map[string]Tag, 0)
	for len(buf) >= lim {
		chunk, buf = buf[:lim], buf[lim:]
		t := Tag{
			Trtype: uint16(chunk[0]),
			Dfsid:  uint16(chunk[1]),
			Id:     chunk[2:], // tag ID bytes (used to read data)
			Mac:    tagIDtoMAC(chunk[2:]),
		}
		id := t.Mac
		ts[id] = t
	}
	return ts
}

/*
tag read content

	process blocks of 5 bytes, (except first two and last, which are zero)
	1st is security byte
	then 4 bytes reversed
*/
func prepareReadTagBytes(bs []byte) ([]byte, error) {
	if len(bs) < 5 {
		return nil, errors.New("prepareReadTagBytes: Not enough bytes")
	}
	lim := 5
	var chunk []byte
	blks := bs[2 : len(bs)-2]
	data := make([]byte, 0)
	for len(blks) >= lim {
		chunk, blks = blks[:lim], blks[lim:]
		// Skip first byte (unused security byte) and reverse block (4bytes)
		blk := reverseBytes(chunk[1:])
		data = append(data, blk...)
	}
	return data, nil
}

/*
prepare tag content for write
content of 4 byte blocks reversed
and added security byte
*/
func prepareWriteTagBytes(tc []byte) ([]byte, error) {
	if len(tc) < 4 {
		return nil, errors.New("prepareWriteBytes: Not enough bytes")
	}
	data := make([]byte, 0)
	for i := 0; i <= len(tc)-4; i += 4 {
		blk := reverseBytes(tc[i : i+4])
		//data = append(data, 0x00) // security byte
		data = append(data, blk...)
	}
	//data = append([]byte{0x00, 0x00}, data...)
	//data = append(data, []byte{0x00, 0x00}...)
	return data, nil
}

/* UTILITY FUNCTIONS */
func reverseBytes(b []byte) []byte {
	bs := make([]byte, 0)
	for i := len(b) - 1; i >= 0; i-- {
		bs = append(bs, b[i])
	}
	return bs
}

func tagIDtoMAC(b []byte) string {
	s := fmt.Sprintf("% 02X", b)
	return strings.Replace(s, " ", ":", -1)
}

// u16tob converts a uint16 into a 2-byte slice.
func u16tob(v uint16) []byte {
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, v)
	return b
}

func btou16(b []byte) uint16 {
	return binary.BigEndian.Uint16(b)
}

/*
CRC16 implementation
using CCITT reversed algorithm
ripped from github.com/howeyc/crc16 for performance
*/
func makeCRCTable() [256]uint16 {
	var tbl [256]uint16
	width := uint16(16)
	for i := uint16(0); i < 256; i++ {
		crc := i << (width - 8)
		for j := 0; j < 8; j++ {
			if crc&(1<<(width-1)) != 0 {
				crc = (crc << 1) ^ CCITT_REVERSED
			} else {
				crc <<= 1
			}
		}
		tbl[i] = crc
	}
	return tbl
}

func crc16(b []byte, tbl [256]uint16) []byte {
	crc := uint16(0xFFFF)
	for _, v := range b {
		crc = tbl[byte(crc>>8)^v] ^ (crc << 8)
	}
	msb := crc & 0x00FF
	lsb := crc >> 8
	return []byte{uint8(msb), uint8(lsb)}
}

// compare computed CRC with last two bytes of response - not used
func validateCRC(b []byte) bool {
	if len(b) < 4 {
		return false
	}
	return bytes.Equal(crc16(b[:len(b)-2], CRCTable), b[len(b)-2:])
}
