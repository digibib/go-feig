package main

/*
  simple mock server to fake EventSource messages for rfid integration in Koha
  example:
    curl localhost:1667/sendmessage -d '{"event":"addTag","data":{"Mac":"E0:12:23:34:45:56","Content":{"Barcode":"03011339851014","NumItems":1}}}'
  will send the event to any connected client on localhost:1667/events/
*/
import (
  "embed"
  "encoding/json"
  "flag"
  "fmt"
  "io/fs"
  "log"
  "net/http"
)

type EsMsg struct {
  Event string          `json:"event"`
  Data  json.RawMessage `json:"data"`
}

type ServerStatus struct {
  Client, Mode string
}

var messageChannels = make(map[chan EsMsg]bool)

func handleSSE(w http.ResponseWriter, r *http.Request) {

  log.Printf("Get handshake from client")

  // prepare the header
  w.Header().Set("Access-Control-Allow-Origin", "*")
  w.Header().Set("Access-Control-Allow-Headers", "X-Requested-With")
  w.Header().Set("Content-Type", "text/event-stream")
  w.Header().Set("Cache-Control", "no-cache")
  w.Header().Set("Connection", "keep-alive")

  // instantiate the channel
  msgChan := make(chan EsMsg)
  messageChannels[msgChan] = true
  // loop over message channel
  for {
    select {
    case msg := <-msgChan:
      fmt.Fprintf(w, "event: %s\n", msg.Event)
      fmt.Fprintf(w, "data: %s\n\n", msg.Data)
      w.(http.Flusher).Flush()
    case <-r.Context().Done():
      delete(messageChannels, msgChan)
      return
    }
  }
}

func sendMessage(w http.ResponseWriter, r *http.Request) {
  defer r.Body.Close()
  var msg EsMsg
  err := json.NewDecoder(r.Body).Decode(&msg)

  if err != nil {
    http.Error(w, err.Error(), http.StatusInternalServerError)
    return
  }

  go func() {
    for msgChan := range messageChannels {
      log.Println("print message to client")
      msgChan <- msg
    }
  }()
  w.Write([]byte("OK"))
}

func mockStatus(w http.ResponseWriter, r *http.Request) {
  s := &ServerStatus{Mode: "IDLE", Client: "TEST"}
  b, _ := json.Marshal(s)
  enableCors(&w)
  w.Write(b)
}

func enableCors(w *http.ResponseWriter) {
  (*w).Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, PUT, DELETE")
  (*w).Header().Set("Access-Control-Allow-Headers", "Accept, Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization")
  (*w).Header().Set("Access-Control-Allow-Origin", "*")
  (*w).Header().Set("Access-Control-Allow-Headers", "X-Requested-With")
}

//go:embed cmd/html
var public embed.FS

func main() {
  port := flag.String("port", ":1667", "port of mock API")
  flag.Parse()
  sub, err := fs.Sub(public, "cmd")
  if err != nil {
    log.Fatal(err)
  }

  fs := http.FileServer(http.FS(sub))

  mux := http.NewServeMux()
  mux.HandleFunc("/events/", handleSSE)
  mux.HandleFunc("/.status", mockStatus)
  mux.HandleFunc("/sendmessage", sendMessage)
  mux.Handle("/", fs) // Serve static files
  fmt.Printf("Listening on %s\n", *port)
  log.Fatal("HTTP server error: ", http.ListenAndServe(*port, mux))
}
