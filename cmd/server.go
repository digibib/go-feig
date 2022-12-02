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
	sporeURL              string
	kohaURL               string
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
}

func newServer(r *Reader, wake bool, lgr Logger, spore string, koha string) *server {
	return &server{
		inventory:             make(map[string]Tag, 0),
		Reader:                r,
		keepTranspondersAwake: wake,
		Log:                   lgr,
		sporeURL:              spore,
		kohaURL:               koha,
		startTime:             time.Now(),
		mode:                  modeIdle,
		client:                make(chan EsMsg), // dummy client to safely close on register/unregister
		register:              make(chan (chan EsMsg)),
		unregister:            make(chan (chan EsMsg)),
		broadcast:             make(chan EsMsg),
	}
}

func (s *server) readRFID() {
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	defer func() {
		if err := recover(); err != nil {
			if strings.Contains(fmt.Sprintf("%v", err), "close of closed channel") {
				s.client = make(chan EsMsg)
				s.readRFID()
			}
		}
	}()
	for {
		select {
		case msg := <-s.broadcast:
			select {
			case s.client <- msg:
			case <-time.After(500 * time.Millisecond):
				// drop it
			}
		case c := <-s.register:
			// clear inventory and close client
			s.mu.Lock()
			s.inventory = make(map[string]Tag, 0)
			s.mu.Unlock()

			close(s.client)

			s.client = c
		case c := <-s.unregister:
			close(c)
			s.client = make(chan EsMsg) // dummy client we can close on register
		default:
			<-tick.C
			s.mu.Lock()
			m := s.mode
			s.mu.Unlock()
			if m == modeScan {
				s.Reader.ReadTagsInRange(s)
			}
		}
	}
}
