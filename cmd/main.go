package main

/*
#cgo CFLAGS: -I../drivers -g -Wall
#cgo linux LDFLAGS: -L. -lfeusb -lfetcp -lfeisc
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
	"flag"
	"io/fs"
	"log"
	"net/http"
	"net/http/pprof"

	"embed"

	"github.com/rs/cors"
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
	tls := flag.Bool("tls", false, "use tls, read cert.pem and key.pem from same folder")
	spore := flag.String("spore", "", "spore url to log rfid scans")
	koha := flag.String("koha", "", "koha api url")
	axeHost := flag.String("axeHost", "", "host of feiging axe")
	axePort := flag.Int("axePort", 0, "port of feiging axe")
	debug := flag.Bool("debug", false, "turn on verbose logging")
	flag.Parse()

	if *debug {
		l.PrintDebug = true
	}

	var iPortHandle C.int
	var err error
	if *axeHost != "" && *axePort != 0 {
		l.Printf("Connecting to axe at host %s port %d", *axeHost, *axePort)
		iPortHandle, err = C.FETCP_Connect(C.CString(*axeHost), C.int(*axePort))
	} else {
		iPortHandle, err = C.FEUSB_ScanAndOpen(C.FEUSB_SCAN_FIRST, nil)
	}
	if iPortHandle < 0 {
		l.Printf("No RFID Device found!")
		errBuf := make([]C.char, 56)
		C.FEUSB_GetErrorText(C.int(iPortHandle), &errBuf[0])
		l.Printf("ERROR: %d, %s\n", iPortHandle, C.GoString(&errBuf[0]))

	}

	r := newReader(iPortHandle)
	l.Debug(r)
	s := newServer(r, *wake, l, *spore, *koha)
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

	// debug pprof handlers
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	// Cors middleware
	c := cors.New(cors.Options{
		//AllowedOrigins:   []string{"http://localhost:1667", "http://localhost:8081", "http://10.172.3.80:8081"},
		AllowCredentials: true,
		AllowOriginFunc:  func(origin string) bool { return true }, // disable cors entirely
		// Enable Debugging for testing, consider disabling in production
		Debug: false,
	})
	l.Printf("Starting web server at port %s\n", *port)
	if *tls == true {
		log.Fatal(http.ListenAndServeTLS(*port, "cert.pem", "key.pem", c.Handler(mux)))
	} else {
		log.Fatal(http.ListenAndServe(*port, c.Handler(mux)))
	}
}
