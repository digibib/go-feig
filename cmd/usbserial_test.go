package main

import (
	"bytes"
	"testing"

	"github.com/google/go-cmp/cmp"
)

func TestCrc16(t *testing.T) {
	wants := []struct {
		in  []byte
		out []byte
	}{
		{[]byte{STX, 0x00, 0x08, 0xFF, CMD_BAUDRATE, 0x00}, []byte{0x4A, 0xC3}},
		{[]byte{STX, 0x00, 0x07, 0xFF, CMD_SW_VERSION}, []byte{0x6E, 0x61}},
		{[]byte{STX, 0x00, 0x13, 0x00, CMD_ISO15693, ISO15693_INVENTORY, 0x00}, []byte{0x22, 0x7E}},
		{[]byte{STX, 0x00, 0x13, 0x00, CMD_ISO15693, ISO15693_READ_BYTES,
			0x01, 0xE0, 0x04, 0x01, 0x00, 0x46, 0x70, 0x7A, 0x28, 0x00, 0x0A}, []byte{0x88, 0xBF}},
	}
	for _, w := range wants {
		got := crc16(w.in, CRCTable)
		if !bytes.Equal(got, w.out) {
			t.Errorf("Incorrect CRC: %04X, want: %04X", got, w.out)
		}
	}
}

func TestGetReaderInfoResponse(t *testing.T) {
	want := struct {
		in  []byte
		out *rInfo
	}{
		[]byte{0x02, 0x00, 0x13, 0x00, 0x66, 0x00, 0x02, 0x06, 0x00, 0x0B, 0x4D, 0x00, 0x09, 0x01, 0x18, 0x02, 0x00, 0x95, 0x96},
		&rInfo{
			Status:          respStatus[STATUS_OK],
			Swrev:           0x206,
			Drev:            0,
			Rxbuf:           0x4d00,
			Txbuf:           0x901,
			Usb:             false,
			OnePointTwoWatt: false,
		},
	}
	got, _ := getSerialReaderInfo(want.in)
	if cmp.Equal(got, want.out) != true {
		t.Errorf("Wrong Reader Info Response:\ngot:  %#v\nwant: %#v\n", got, want.out)
	}
}

func TestGetInventoryResponse(t *testing.T) {
	wants := []struct {
		in  []byte
		out *Inventory
	}{
		{
			[]byte{0x02, 0x00, 0x27, 0x00, 0xB0, 0x83, 0x03,
				0x03, 0x00, 0xE0, 0x04, 0x01, 0x50, 0x33, 0x09, 0xCE, 0x74,
				0x03, 0x00, 0xE0, 0x04, 0x01, 0x00, 0x46, 0x70, 0x7A, 0x28,
				0x03, 0x00, 0xE0, 0x04, 0x01, 0x50, 0x0B, 0x21, 0x97, 0x24, 0x78, 0xC9},
			&Inventory{
				Status: respStatus[STATUS_RF_COMMUNICATION_ERROR], // TODO: this must be wrong!
				Count:  3,
				Tags: map[string]Tag{
					"E0:04:01:50:33:09:CE:74": {Trtype: 3, Dfsid: 0, Id: []byte{0xE0, 0x04, 0x01, 0x50, 0x33, 0x09, 0xCE, 0x74}, Content: TagContent{}},
					"E0:04:01:00:46:70:7A:28": {Trtype: 3, Dfsid: 0, Id: []byte{0xE0, 0x04, 0x01, 0x00, 0x46, 0x70, 0x7A, 0x28}, Content: TagContent{}},
					"E0:04:01:50:0B:21:97:24": {Trtype: 3, Dfsid: 0, Id: []byte{0xE0, 0x04, 0x01, 0x50, 0x0B, 0x21, 0x97, 0x24}, Content: TagContent{}},
				},
			},
		},
	}
	for _, w := range wants {
		got, _ := getInventory(w.in)
		if cmp.Equal(got, w.out) != true {
			t.Errorf("Wrong Inventory Response:\ngot:  %#v\nwant: %#v\n", got, w.out)
		}
	}
}

func TestIdToMac(t *testing.T) {
	wants := []struct {
		in  []byte
		out string
	}{
		{
			[]byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF},
			"01:23:45:67:89:AB:CD:EF",
		},
	}
	for _, w := range wants {
		got := tagIDtoMAC(w.in)
		if got != w.out {
			t.Errorf("Wrong Tag ID formatting:\ngot:  %#v\nwant: %#v\n", got, w.out)
		}
	}
}
