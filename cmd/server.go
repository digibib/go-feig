package main

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

type ServerStatus struct {
	Uptime        string
	Reader        *Reader
	LastInventory map[string]Tag
	Client        net.IP
	Mode          string
}

func (s *server) ServerStatus() *ServerStatus {
	now := time.Now()
	uptime := now.Sub(s.startTime)

	return &ServerStatus{
		Uptime:        uptime.String(),
		Reader:        s.Reader,
		LastInventory: s.inventory,
		Client:        getMyIP(),
		Mode:          s.mode.String(),
	}
}

// Keep reader state for sanity
type modeType int

const (
	modeIdle modeType = iota
	modeRead
	modeReadOnce
	modeWrite
	modeWriteAFI
	modeScan
)

func (m modeType) String() string {
	return [...]string{"IDLE", "READ", "READONCE", "WRITE", "WRITEAFI", "SCAN"}[m]
}

type server struct {
	inventory             map[string]Tag
	startTime             time.Time
	mode                  modeType
	keepTranspondersAwake bool
	Log                   Logger
	Reader                *Reader
	mu                    sync.Mutex
	client                chan EsMsg
	register              chan (chan EsMsg)
	unregister            chan (chan EsMsg)
	broadcast             chan EsMsg
	library               string
}

func newServer(r *Reader, wake bool, lgr Logger, library string) *server {
	return &server{
		inventory:             make(map[string]Tag, 0),
		Reader:                r,
		keepTranspondersAwake: wake,
		Log:                   lgr,
		startTime:             time.Now(),
		mode:                  modeIdle,
		client:                make(chan EsMsg), // dummy client to safely close on register/unregister
		register:              make(chan (chan EsMsg)),
		unregister:            make(chan (chan EsMsg)),
		broadcast:             make(chan EsMsg),
		library:               library,
	}
}

// Ticker to periodically scan for tags
func (s *server) readRFID() {
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	defer func() {
		if err := recover(); err != nil {
			if strings.Contains(fmt.Sprintf("%v", err), "close of closed channel") {
				s.mu.Lock()
				s.client = make(chan EsMsg)
				s.mu.Unlock()
				s.readRFID()
			}
		}
	}()

	// Periodically check for updates to msg channel
	for {
		select {
		case _ = <-tick.C:
			s.mu.Lock()
			m := s.mode
			s.mu.Unlock()
			if m == modeScan {
				// for each tick, real all tags in range if put in READ mode
				s.Reader.ReadTagsInRange(s)
			}
		case msg := <-s.broadcast:
			select {
			case s.client <- msg:
			case <-time.After(300 * time.Millisecond):
				// drop it if noone respons after 1 sec
			}
		case c := <-s.register:
			// clear inventory and close client
			s.mu.Lock()
			s.inventory = make(map[string]Tag, 0)
			s.mu.Unlock()

			close(s.client)

			s.mu.Lock()
			s.client = c
			s.mu.Unlock()
		case c := <-s.unregister:
			close(c)
			s.mu.Lock()
			s.client = make(chan EsMsg) // dummy client we can close on register
			s.mu.Unlock()
		default:
			// no-op if no events since last tick
		}
	}
}
