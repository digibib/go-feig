package main

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"time"
)

type EsMsg struct {
	Event string
	Data  []byte
}

var semaphore = make(chan struct{}, 1)

// request handler for event source stream
func (s *server) esHandler(w http.ResponseWriter, r *http.Request) {
	// Limit to 1 synchronous client
	defer func() { <-semaphore }()
	select {
	case semaphore <- struct{}{}:
	case <-time.After(2 * time.Second):
		http.Error(w, "Busy, only tab at a time please!", http.StatusServiceUnavailable)
		return
	}

	// Make sure that the writer supports flushing.
	f, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported!", http.StatusInternalServerError)
		return
	}

	// Create a new channel for messages
	msgChan := make(chan EsMsg)
	s.register <- msgChan

	// request context done? client disconnected, so unregister
	notify := r.Context().Done()
	go func() {
		<-notify
		s.unregister <- msgChan
		log.Println("HTTP connection just closed.")
	}()

	// EventStream headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "X-Requested-With")
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

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
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

/*
Turn off alarm on all tags in range
Uses last read inventory
*/
func (s *server) alarmOff(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	orig := s.mode
	if len(s.inventory) == 0 {
		http.Error(w, "Inventory empty", http.StatusBadRequest)
		return
	}
	s.mode = modeWriteAFI
	for id, tag := range s.inventory {
		if err := s.Reader.WriteAFIByte(tag, 0xc2); err != nil {
			http.Error(w, fmt.Sprintf("Failed activating alarm on id %s, err: %s ", id, err.Error()), http.StatusInternalServerError)
			s.mode = orig
			return
		}
	}
	s.mode = orig
	w.Write([]byte("OK"))
}

func (s *server) alarmOn(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	orig := s.mode
	if len(s.inventory) == 0 {
		http.Error(w, "Inventory empty", http.StatusBadRequest)
		s.mode = orig
		return
	}
	s.mode = modeWriteAFI
	for id, tag := range s.inventory {
		if err := s.Reader.WriteAFIByte(tag, 0x07); err != nil {
			http.Error(w, fmt.Sprintf("Failed activating alarm on id %s, err: %s ", id, err.Error()), http.StatusInternalServerError)
			s.mode = orig
			return
		}
	}
	s.mode = orig
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

func (s *server) handleSpore(w http.ResponseWriter, r *http.Request) {
	// just forward request to Spore and relay response
	proxyReq, err := http.NewRequest("POST", s.sporeURL, r.Body)

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	copyHeader(proxyReq.Header, r.Header)

	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	var body []byte
	body, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (s *server) reviewsProxy(w http.ResponseWriter, r *http.Request) {
	uri, ok := r.URL.Query()["uri"]
	if !ok || len(uri[0]) < 1 {
		s.Log.Debug("Url Param 'uri' is missing")
		return
	}
	url := fmt.Sprintf("https://anbefalinger.deichman.no/api/works?uri=%s&reviews=true", uri[0])

	proxyReq, err := http.NewRequest(r.Method, url, r.Body)

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	//proxyReq.Header.Set("Host", req.Host)
	//proxyReq.Header.Set("X-Forwarded-For", req.RemoteAddr)

	for header, values := range r.Header {
		for _, value := range values {
			proxyReq.Header.Add(header, value)
		}
	}

	client := &http.Client{}
	res, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer res.Body.Close()
	body, err := ioutil.ReadAll(res.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (s *server) esProxy(w http.ResponseWriter, r *http.Request) {
	recId, ok := r.URL.Query()["recId"]
	if !ok || len(recId[0]) < 1 {
		s.Log.Debug("Url Param 'recId' is missing")
		return
	}
	//url := fmt.Sprintf("http://zork:8005/search/publication/_search?q=recordId:%s", recId[0])
	url := fmt.Sprintf("https://sok.deichman.no/q?query=recordId:%s", recId[0])

	proxyReq, err := http.NewRequest(r.Method, url, r.Body)

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	copyHeader(proxyReq.Header, r.Header)

	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	var body []byte
	if resp.Header.Get("Content-Encoding") == "gzip" {
		gr, err := gzip.NewReader(resp.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		body, err = ioutil.ReadAll(gr)
	} else {
		body, err = ioutil.ReadAll(resp.Body)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	//w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

/* create session in koha */
func (s *server) loginKoha(w http.ResponseWriter, r *http.Request) {
	url := fmt.Sprintf("%s/auth/session", s.kohaURL)
	proxyReq, err := http.NewRequest("POST", url, r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	copyHeader(proxyReq.Header, r.Header)
	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	var body []byte
	body, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Set-Cookie", resp.Header["Set-Cookie"][0])
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

/* delete session in koha */
func (s *server) logoutKoha(w http.ResponseWriter, r *http.Request) {
	url := fmt.Sprintf("%s/auth/session", s.kohaURL)
	proxyReq, err := http.NewRequest("DELETE", url, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	copyHeader(proxyReq.Header, r.Header)
	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	expires := time.Now()
	ck := http.Cookie{Name: "koha.session", Domain: "localhost", Path: "/", Expires: expires}
	http.SetCookie(w, &ck)
	w.Header().Set("Content-Type", "application/json")
	io.Copy(w, resp.Body)
}

func (s *server) itemStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	barcode, ok := r.URL.Query()["barcode"]
	if !ok || len(barcode[0]) < 1 {
		http.Error(w, "Url Param 'barcode' is missing", http.StatusBadRequest)
		return
	}
	url := fmt.Sprintf("%s/item/status/%s", s.kohaURL, barcode[0])
	proxyReq, err := http.NewRequest("GET", url, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	copyHeader(proxyReq.Header, r.Header)
	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

/* Forward checkin request to koha */
func (s *server) itemCheckIn(w http.ResponseWriter, r *http.Request) {
	url := fmt.Sprintf("%s/item/checkin", s.kohaURL)
	proxyReq, err := http.NewRequest("POST", url, r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	copyHeader(proxyReq.Header, r.Header)

	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	w.WriteHeader(resp.StatusCode)
	w.Header().Set("Content-Type", "application/json")
	io.Copy(w, resp.Body)
}

/* Forward checkout request to koha */
func (s *server) itemCheckOut(w http.ResponseWriter, r *http.Request) {
	url := fmt.Sprintf("%s/item/checkout", s.kohaURL)
	proxyReq, err := http.NewRequest("POST", url, r.Body)

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	copyHeader(proxyReq.Header, r.Header)

	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	w.WriteHeader(resp.StatusCode)
	w.Header().Set("Content-Type", "application/json")
	io.Copy(w, resp.Body)
}

func (s *server) tagLocation(w http.ResponseWriter, r *http.Request) {
	rfid, ok := r.URL.Query()["rfid"]
	if !ok || len(rfid[0]) < 1 {
		http.Error(w, "Url Param 'rfid' is missing", http.StatusBadRequest)
		return
	}
	url := fmt.Sprintf("%s/spore/locations/tags?rfid=%s", s.kohaURL, rfid[0])
	proxyReq, err := http.NewRequest("GET", url, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	copyHeader(proxyReq.Header, r.Header)
	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func (s *server) sendIndexFile(w http.ResponseWriter, r *http.Request) {
	data, err := ioutil.ReadFile("./html/index.html")
	if err != nil {
		s.Log.Debug(err)
		http.Error(w, "Couldn't read file", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

func copyHeader(dst, src http.Header) {
	for k, vv := range src {
		for _, v := range vv {
			dst.Add(k, v)
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
