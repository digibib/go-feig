package main

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

const VERSION = "1.2.1"

type ServerStatus struct {
	Uptime        string
	Reader        *Reader
	LastInventory map[string]Tag
	Client        net.IP
	Mode          string
	Version       string
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
		Version:       VERSION,
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
	onlyOneActive         bool
	Log                   Logger
	Reader                *Reader
	mu                    sync.Mutex
	messageChannels       map[chan EsMsg]bool
	broadcast             chan EsMsg
	library               string
}

func newServer(r *Reader, wake bool, onlyOne bool, lgr Logger, library string) *server {
	return &server{
		inventory:             make(map[string]Tag, 0),
		Reader:                r,
		keepTranspondersAwake: wake,
		onlyOneActive:         onlyOne,
		Log:                   lgr,
		startTime:             time.Now(),
		mode:                  modeIdle,
		messageChannels:       make(map[chan EsMsg]bool),
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
				// is this neccessary? a recovery channel just to be closed?
				s.mu.Lock()
				msgChan := make(chan EsMsg)
				s.messageChannels[msgChan] = true
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
		// go message on broadcast channel, attempt send to any connected clients
		case msg := <-s.broadcast:
			go func() {
				for msgChan := range s.messageChannels {
					msgChan <- msg
				}
			}()
		default:
			// no-op if no events since last tick
		}
	}
}
