package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net"
	"net/http"
)

type EsMsg struct {
	Event string
	Data  []byte
}

func enableCors(w *http.ResponseWriter) {
	(*w).Header().Set("Access-Control-Allow-Origin", "*")
	(*w).Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS, PUT, DELETE")
	(*w).Header().Set("Access-Control-Allow-Headers", "Content-Type, Access-Control-Allow-Headers, Authorization, X-Requested-With")
	(*w).Header().Set("Access-Control-Allow-Credentials", "true")
	(*w).Header().Set("Access-Control-Max-Age", "300") // 5 minutes
	(*w).Header().Set("Access-Control-Allow-Private-Network", "true")
}

// request handler for event source stream
func (s *server) esHandler(w http.ResponseWriter, r *http.Request) {
	if s.onlyOneActive {
		// Disconnect any other registered eventsource
		for mc := range s.messageChannels {
			close(mc)
			delete(s.messageChannels, mc)
		}
	}

	// Make sure that the writer supports flushing.
	f, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported!", http.StatusInternalServerError)
		return
	}

	// Create a new channel for messages
	msgChan := make(chan EsMsg)
	s.messageChannels[msgChan] = true

	// request context done? client disconnected, so unregister
	notify := r.Context().Done()
	go func() {
		<-notify
		if !s.onlyOneActive {
			close(msgChan)

		}
		delete(s.messageChannels, msgChan)
		log.Println("HTTP connection just closed.")
		return
	}()

	// EventStream headers
	enableCors(&w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	// keep pushing messages for clients from msgChan until closed
	for msg := range msgChan {
		// Write to the ResponseWriter, `w`.
		fmt.Fprintf(w, "event: %s\n", msg.Event)
		fmt.Fprintf(w, "data: %s\n\n", msg.Data)
		// Flush the response.  This is only possible if the repsonse supports streaming.
		f.Flush()
	}

	log.Println("Finished HTTP request at ", r.URL.Path)
}

func (s *server) statusHandler(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	b, err := json.Marshal(s.ServerStatus())
	s.mu.Unlock()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	printHeaders(r)
	enableCors(&w)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

func (s *server) scanOnce(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	orig := s.mode
	s.mode = modeReadOnce
	s.mu.Unlock()
	t := s.Reader.ReadTagsInRange(s)
	b, err := json.Marshal(t)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	s.mode = orig
	s.mu.Unlock()
	enableCors(&w)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

/*
   Write single tag in range
   Uses tag from last inventory
   input param: tagId, barcode
*/

func (s *server) writeTagBarcode(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	orig := s.mode
	s.mu.Unlock()
	tagid, ok := r.URL.Query()["tagid"]
	barcode, ok := r.URL.Query()["barcode"]
	if !ok || len(tagid[0]) < 1 {
		http.Error(w, "Url Param 'tagid' is missing", http.StatusBadRequest)
		return
	}
	if !ok || len(barcode[0]) < 1 {
		http.Error(w, "Url Param 'barcode' is missing", http.StatusBadRequest)
		return
	}
	if len(s.inventory) == 0 {
		http.Error(w, "Inventory empty", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	s.mode = modeWrite
	s.mu.Unlock()
	tag, err := s.Reader.WriteTagBarcode(s, tagid[0], barcode[0])
	if err != nil {
		http.Error(w, "Error writing tag: "+err.Error(), http.StatusBadRequest)
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		return
	}
	b, err := json.Marshal(tag)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	s.mode = orig
	s.mu.Unlock()
	enableCors(&w)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

/*
Write barcode to all tags in range
Will also write sequence number and total number to tags
Uses last read inventory
input param: barcode
*/
func (s *server) writeTags(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	orig := s.mode
	s.mu.Unlock()
	barcode, ok := r.URL.Query()["barcode"]
	if !ok || len(barcode[0]) < 1 {
		http.Error(w, "Url Param 'barcode' is missing", http.StatusBadRequest)
		return
	}
	if len(s.inventory) == 0 {
		http.Error(w, "Inventory empty", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	s.mode = modeWrite
	s.mu.Unlock()
	inv, err := s.Reader.WriteToTagsInRange(s, barcode[0])
	if err != nil {
		http.Error(w, "Error writing inventory: "+err.Error(), http.StatusBadRequest)
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		return
	}
	b, err := json.Marshal(inv)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	s.mode = orig
	s.mu.Unlock()
	enableCors(&w)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

/*
Turn off alarm on all tags in range (single non-addressed broadcast write)
*/
func (s *server) alarmOff(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	empty := len(s.inventory) == 0
	s.mu.Unlock()
	if empty {
		http.Error(w, "Inventory empty", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	orig := s.mode
	s.mode = modeWriteAFI
	s.mu.Unlock()
	// Note: don't hold s.mu here, reader ops take reader lock first
	if err := s.Reader.WriteAFI(0xc2); err != nil {
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		http.Error(w, fmt.Sprintf("Failed turning off alarm, err: %s ", err.Error()), http.StatusInternalServerError)
		return
	}
	s.mu.Lock()
	s.mode = orig
	s.mu.Unlock()
	enableCors(&w)
	w.Write([]byte("OK"))
}

/*
Turn on alarm on all tags in range (single non-addressed broadcast write)
*/
func (s *server) alarmOn(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	empty := len(s.inventory) == 0
	s.mu.Unlock()
	if empty {
		http.Error(w, "Inventory empty", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	orig := s.mode
	s.mode = modeWriteAFI
	s.mu.Unlock()
	// Note: don't hold s.mu here, reader ops take reader lock first
	if err := s.Reader.WriteAFI(0x07); err != nil {
		s.mu.Lock()
		s.mode = orig
		s.mu.Unlock()
		http.Error(w, fmt.Sprintf("Failed activating alarm, err: %s ", err.Error()), http.StatusInternalServerError)
		return
	}
	s.mu.Lock()
	s.mode = orig
	s.mu.Unlock()
	enableCors(&w)
	w.Write([]byte("OK"))
}

/*
Start (or continue) Bluetooth LE discovery and return the readers found so far.
The discovery keeps running until stopped with /ble/stop.
To connect to a discovered reader, start the app with -bleMac <mac>.
*/
func (s *server) bleScan(w http.ResponseWriter, r *http.Request) {
	if err := s.Reader.BleStartDiscover(); err != nil {
		s.Log.Debugf("BLE scan: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	items := s.Reader.BleList()
	b, err := json.Marshal(items)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	enableCors(&w)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

/*
Stop Bluetooth LE discovery
*/
func (s *server) bleStop(w http.ResponseWriter, r *http.Request) {
	if err := s.Reader.BleStopDiscover(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	enableCors(&w)
	w.Write([]byte("OK"))
}

func (s *server) handleStart(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.mode = modeScan
	s.mu.Unlock()
}

func (s *server) handleStop(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.mode = modeIdle
	s.mu.Unlock()
}

func (s *server) sendIndexFile(w http.ResponseWriter, r *http.Request) {
	data, err := ioutil.ReadFile("./html/index.html")
	if err != nil {
		s.Log.Debug(err)
		http.Error(w, "Couldn't read file", http.StatusInternalServerError)
		return
	}
	enableCors(&w)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

// No longer in use
func copyHeader(dst, src http.Header) {
	for k, vv := range src {
		for _, v := range vv {
			dst.Add(k, v)
		}
	}
}

func printHeaders(r *http.Request) {
	log.Println("HTTP request headers.")
	// Loop over header names
	for name, values := range r.Header {
		// Loop over all values for the name (as a header can have multiple values)
		for _, value := range values {
			log.Printf("%s: %s\n", name, value)
		}
	}
}

/* dummy udp connection to get outbound IP */
func getMyIP() net.IP {
	conn, err := net.Dial("udp", "1.1.1.1:0")
	if err != nil {
		return net.IP{}
	}
	defer conn.Close()
	localAddr := conn.LocalAddr().(*net.UDPAddr)
	return localAddr.IP
}
