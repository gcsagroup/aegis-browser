// Package embeddedcore is the in-process Access core bridge.
//
// It exposes StartInstance / Dial / stream I/O for gomobile. The product
// config must contain only the admitted reality_vision outbound — no
// DIRECT/freedom fallback and no second HTTP inbound.
package embeddedcore

import (
	"context"
	"errors"
	"io"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu              sync.Mutex
	instance        *core.Instance
	streams         = map[int64]*streamHandle{}
	nextID          atomic.Int64
	instanceContext context.Context
	instanceCancel  context.CancelFunc
)

var (
	errNotRunning     = errors.New("embedded core is not running")
	errAlreadyRunning = errors.New("embedded core is already running")
	errBadStream      = errors.New("unknown or closed stream")
	errEmptyDial      = errors.New("dial host is empty")
)

type streamHandle struct {
	conn   net.Conn
	cancel context.CancelFunc
}

// Start boots one Xray instance from JSON config bytes (UTF-8).
// A stopped instance cannot be restarted; call Start again after Stop.
func Start(configJSON string) error {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		return errAlreadyRunning
	}
	inst, err := core.StartInstance("json", []byte(configJSON))
	if err != nil {
		return err
	}
	instance = inst
	instanceContext, instanceCancel = context.WithCancel(context.Background())
	return nil
}

// Stop closes every open dial stream and the running instance.
func Stop() error {
	mu.Lock()
	inst, cancel, closing := instance, instanceCancel, streams
	instance, instanceContext, instanceCancel = nil, nil, nil
	streams = map[int64]*streamHandle{}
	mu.Unlock()
	if cancel != nil {
		cancel()
	}
	for _, handle := range closing {
		handle.cancel()
		_ = handle.conn.Close()
	}
	if inst != nil {
		return inst.Close()
	}
	return nil
}

// IsRunning reports whether the embedded instance is live.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil && instance.IsRunning()
}

// Dial opens one TCP path through the running instance to host:port.
// Returns a stream id used by Read / Write / CloseStream.
func Dial(host string, port int) (int64, error) {
	host = strings.TrimSpace(host)
	if host == "" || port <= 0 || port > 65535 {
		return 0, errEmptyDial
	}
	mu.Lock()
	inst, parent := instance, instanceContext
	mu.Unlock()
	if inst == nil || !inst.IsRunning() {
		return 0, errNotRunning
	}
	ctx, cancel := context.WithCancel(parent)
	dest := net.TCPDestination(net.ParseAddress(host), net.Port(port))
	conn, err := core.Dial(ctx, inst, dest)
	if err != nil {
		cancel()
		return 0, err
	}
	id := nextID.Add(1)
	mu.Lock()
	if instance != inst {
		mu.Unlock()
		cancel()
		_ = conn.Close()
		return 0, errNotRunning
	}
	streams[id] = &streamHandle{conn: conn, cancel: cancel}
	mu.Unlock()
	return id, nil
}

// Read returns up to maxBytes from the stream. An empty slice with a nil
// error means EOF. A closed stream returns an error.
func Read(streamID int64, maxBytes int) ([]byte, error) {
	if maxBytes <= 0 {
		maxBytes = 16 * 1024
	}
	handle, err := lookup(streamID)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, maxBytes)
	n, readErr := handle.conn.Read(buf)
	if n > 0 {
		return buf[:n], nil
	}
	if readErr == io.EOF {
		return []byte{}, nil
	}
	if readErr != nil {
		return nil, readErr
	}
	return []byte{}, nil
}

// Write sends the whole chunk on the stream.
func Write(streamID int64, data []byte) error {
	handle, err := lookup(streamID)
	if err != nil {
		return err
	}
	_, err = handle.conn.Write(data)
	return err
}

// CloseStream closes one dial stream. Idempotent for unknown ids.
func CloseStream(streamID int64) {
	mu.Lock()
	handle, ok := streams[streamID]
	if ok {
		delete(streams, streamID)
	}
	mu.Unlock()
	if !ok {
		return
	}
	handle.cancel()
	_ = handle.conn.Close()
}

func lookup(streamID int64) (*streamHandle, error) {
	mu.Lock()
	defer mu.Unlock()
	handle, ok := streams[streamID]
	if !ok {
		return nil, errBadStream
	}
	return handle, nil
}

// Version returns the linked Xray-core version string.
func Version() string {
	return core.Version()
}

// Completion is retained by the native operation until exactly one result is
// delivered. Async entry points return immediately; socket waits park goroutines,
// never Swift cooperative workers or libdispatch worker threads.
type Completion interface {
	Complete(value int64, data []byte, failure string)
}

func complete(c Completion, value int64, data []byte, err error) {
	failure := ""
	if err != nil {
		failure = err.Error()
	}
	c.Complete(value, data, failure)
}

func StartAsync(configJSON string, c Completion) {
	go func() { complete(c, 0, nil, Start(configJSON)) }()
}
func DialAsync(host string, port int, c Completion) {
	go func() { id, err := Dial(host, port); complete(c, id, nil, err) }()
}
func ReadAsync(streamID int64, maxBytes int, c Completion) {
	go func() { data, err := Read(streamID, maxBytes); complete(c, 0, data, err) }()
}

// Gomobile lends argument bytes only for this call; own them before returning.
func WriteAsync(streamID int64, data []byte, c Completion) {
	data = append([]byte(nil), data...)
	go func() { complete(c, 0, nil, Write(streamID, data)) }()
}
func StopAsync(c Completion) {
	go func() { complete(c, 0, nil, Stop()) }()
}
func CloseStreamAsync(streamID int64) {
	go CloseStream(streamID)
}
