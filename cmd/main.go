package main

import (
	"flag"
	"io/fs"
	"log"
	"net/http"
	"net/http/pprof"

	"embed"
)

var (
	CRCTable [256]uint16 = makeCRCTable() // CRC CCITT reversed table for fast lookup
	//go:embed html
	staticFiles embed.FS
)

func main() {
	l := Logger{}
	l.Print("Starting feiging...")
	port := flag.String("port", ":1667", "port of http API")
	wake := flag.Bool("wake", true, "Keep inventory state and keep all transponders awake, will not be able to read tag content")
	onlyOne := flag.Bool("onlyOne", true, "kick out any other client upon new connection")
	tls := flag.Bool("tls", false, "use tls, read cert.pem and key.pem from same folder")
	library := flag.String("library", "02030000", "library ISIL number")
	axeHost := flag.String("axeHost", "", "host of feiging axe (tcp)")
	axePort := flag.Int("axePort", 0, "port of feiging axe")
	bleMac := flag.String("bleMac", "", "MAC address of reader to connect to over Bluetooth LE (e.g. AA:BB:CC:DD:EE:FF)")
	comPort := flag.String("comPort", "", "serial port of reader (e.g. /dev/ttyUSB0)")
	comFrame := flag.String("comFrame", "8E1", "serial byte frame (8E1 | 8N1 | 8O1)")
	comBaud := flag.Int("comBaud", 38400, "serial baudrate")
	debug := flag.Bool("debug", false, "turn on verbose logging")
	flag.Parse()

	if *debug {
		l.PrintDebug = true
	}

	r := newReader()

	// Pick connection type: BLE > serial COM > TCP (axe) > USB (auto scan)
	var connErr error
	switch {
	case *bleMac != "":
		l.Printf("Connecting to BLE reader %s", *bleMac)
		connErr = r.ConnectBle(*bleMac)
	case *comPort != "":
		l.Printf("Connecting to reader on serial port %s", *comPort)
		connErr = r.ConnectCom(*comPort, *comFrame, *comBaud)
	case *axeHost != "" && *axePort != 0:
		l.Printf("Connecting to axe at host %s port %d", *axeHost, *axePort)
		connErr = r.ConnectTcp(*axeHost, *axePort)
	default:
		l.Print("Scanning for USB reader...")
		connErr = r.ConnectUsb()
	}
	if connErr != nil {
		l.Printf("No RFID Device found! %v", connErr)
	}
	l.Debug(r)

	s := newServer(r, *wake, *onlyOne, l, *library)
	go s.readRFID()

	/*
	 * HANDLERS
	 */
	mux := http.NewServeMux()

	// STATIC
	fsys, err := fs.Sub(staticFiles, "html")
	var staticFS = http.FS(fsys)
	if err != nil {
		log.Fatal(err)
	}
	mux.Handle("/html/", http.StripPrefix("/html/", http.FileServer(staticFS)))
	//http.HandleFunc("/index.html", s.sendIndexFile)

	// API
	mux.HandleFunc("/events/", s.esHandler)
	mux.HandleFunc("/.status", s.statusHandler)
	mux.HandleFunc("/scan", s.scanOnce)
	mux.HandleFunc("/start", s.handleStart)
	mux.HandleFunc("/stop", s.handleStop)
	mux.HandleFunc("/write", s.writeTags)
	mux.HandleFunc("/writetagbarcode", s.writeTagBarcode)

	mux.HandleFunc("/alarmOff", s.alarmOff)
	mux.HandleFunc("/alarmOn", s.alarmOn)

	// BLE discovery
	mux.HandleFunc("/ble/scan", s.bleScan)
	mux.HandleFunc("/ble/stop", s.bleStop)

	// debug pprof handlers
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	l.Printf("Starting web server at port %s\n", *port)
	if *tls == true {
		log.Fatal(http.ListenAndServeTLS(*port, "cert.pem", "key.pem", mux))
	} else {
		log.Fatal(http.ListenAndServe(*port, mux))
	}
}
