package main

import "log"

/* basic logger with debug level */
type Logger struct {
	PrintDebug bool
}

func (l *Logger) Debug(args ...interface{}) {
	if l.PrintDebug {
		l.Print(args...)
	}
}

func (l *Logger) Debugf(format string, args ...interface{}) {
	if l.PrintDebug {
		l.Printf(format, args...)
	}
}

func (l *Logger) Print(args ...interface{}) {
	log.Print(args...)
}

func (l *Logger) Printf(format string, args ...interface{}) {
	log.Printf(format, args...)
}
