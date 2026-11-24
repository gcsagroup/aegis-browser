// Package embeddedcore is the in-process Access core bridge.
//
// It exposes StartInstance / Dial / stream I/O for gomobile. The product
// config must contain only the admitted reality_vision outbound — no
// DIRECT/freedom fallback and no second HTTP inbound.
package embeddedcore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"

	xraylog "github.com/xtls/xray-core/app/log"
	clog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	xrayjson "github.com/xtls/xray-core/infra/conf/json"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet/tls"
	"google.golang.org/protobuf/proto"
)

// Runtime owns an isolated Xray instance and its streams.
// Legacy package entry points below retain their original single-runtime API.
type Runtime struct {
	mu              sync.Mutex
	instance        *core.Instance
	streams         map[int64]*streamHandle
	nextID          atomic.Int64
	instanceContext context.Context
	instanceCancel  context.CancelFunc
}

func NewRuntime() *Runtime { return &Runtime{streams: map[int64]*streamHandle{}} }

var legacy = NewRuntime()

// Xray initialization and diagnostics are process-wide even though routing
// and streams belong to individual runtimes. A rotated log sink outlives the
// runtime that opened it while any runtime is still alive.
var lifecycleMu sync.Mutex
var liveInstances int
var activeLogger *xraylog.Instance
var activeLogConfig *xraylog.Config
var activeLogGeneration int64
var logCaptureGeneration atomic.Int64
var xrayLogType = serial.GetMessageType(&xraylog.Config{})

type discardedLog struct{}

func (discardedLog) Handle(clog.Message)     {}
func (discardedLog) Severity() clog.Severity { return clog.Severity_Unknown }

// Capture order is assigned when Swift opens a FIFO, before scheduling Start.
func NewLogCaptureGeneration() int64 { return logCaptureGeneration.Add(1) }

func RetireLogCaptureGeneration(generation int64) {
	logCaptureGeneration.CompareAndSwap(generation, generation+1)
}

// ValidateRealityClientFields mirrors the pinned builder's client admission.
// Check url.Parse explicitly because the builder dereferences its result.
// Only a field name crosses the bridge on failure.
func ValidateRealityClientFields(fingerprint, spiderX string) string {
	fingerprint = strings.ToLower(fingerprint)
	if fingerprint == "unsafe" || fingerprint == "hellogolang" || tls.GetFingerprint(fingerprint) == nil {
		return "fingerprint"
	}
	if spiderX != "" {
		if !strings.HasPrefix(spiderX, "/") {
			return "spiderX"
		}
		spider, err := url.Parse(spiderX)
		if err != nil {
			return "spiderX"
		}
		query, err := url.ParseQuery(spider.RawQuery)
		if err != nil {
			return "spiderX"
		}
		// The pinned REALITY builder turns these keys into spider work:
		// padding, concurrency, request count, interval and return delay.
		// The manual profile only admits a path and ordinary query data.
		for _, key := range []string{"p", "c", "t", "i", "r"} {
			if query.Has(key) {
				return "spiderX"
			}
		}
	}
	return ""
}

func selectLiveLogger() {
	if activeLogger != nil {
		clog.RegisterHandler(activeLogger)
	} else {
		clog.RegisterHandler(discardedLog{})
	}
}

// Omit the instance logger feature. Even a quiet Xray log feature registers a
// global handler during construction and would displace the live capture.
func detachLogConfig(config *core.Config) (*xraylog.Config, error) {
	for index, app := range config.App {
		if app.Type != xrayLogType {
			continue
		}
		value, err := app.GetInstance()
		if err != nil {
			return nil, err
		}
		config.App = append(config.App[:index], config.App[index+1:]...)
		logConfig := value.(*xraylog.Config)
		if logConfig.AccessLogType != xraylog.LogType_None || logConfig.ErrorLogType != xraylog.LogType_None {
			return logConfig, nil
		}
		break
	}
	return nil, nil
}

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
// Calling Start after Stop creates a fresh instance rather than reusing it.
func (r *Runtime) Start(configJSON string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.instance != nil {
		return errAlreadyRunning
	}
	lifecycleMu.Lock()
	defer lifecycleMu.Unlock()
	var metadata struct {
		LogCaptureGeneration int64 `json:"aegisLogCaptureGeneration"`
	}
	if err := json.NewDecoder(&xrayjson.Reader{Reader: strings.NewReader(configJSON)}).Decode(&metadata); err != nil {
		return err
	}
	generation := metadata.LogCaptureGeneration
	canSelectLog := func() bool {
		if generation == 0 {
			return activeLogGeneration == 0
		}
		return generation == logCaptureGeneration.Load()
	}
	config, err := core.LoadConfig("json", bytes.NewBufferString(configJSON))
	if err != nil {
		return err
	}
	logConfig, err := detachLogConfig(config)
	if err != nil {
		return err
	}
	if liveInstances == 0 {
		selectLiveLogger()
	}
	var candidateLogger *xraylog.Instance
	if logConfig != nil && canSelectLog() &&
		(generation != activeLogGeneration || !proto.Equal(logConfig, activeLogConfig)) {
		candidateLogger, err = xraylog.New(context.Background(), logConfig)
		if err != nil {
			selectLiveLogger()
			return err
		}
	}
	rollbackLogger := func() {
		if candidateLogger != nil {
			selectLiveLogger()
			_ = candidateLogger.Close()
		}
	}
	inst, err := core.New(config)
	if err != nil {
		rollbackLogger()
		return err
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		rollbackLogger()
		return err
	}
	if candidateLogger != nil {
		if canSelectLog() {
			if activeLogger != nil {
				_ = activeLogger.Close()
			}
			activeLogger, activeLogConfig, activeLogGeneration = candidateLogger, logConfig, generation
		} else {
			rollbackLogger()
		}
	}
	r.instance = inst
	liveInstances++
	r.instanceContext, r.instanceCancel = context.WithCancel(context.Background())
	return nil
}

// Stop closes every open dial stream and the running instance.
func (r *Runtime) Stop() error {
	r.mu.Lock()
	inst, cancel, closing := r.instance, r.instanceCancel, r.streams
	r.instance, r.instanceContext, r.instanceCancel = nil, nil, nil
	r.streams = map[int64]*streamHandle{}
	r.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	for _, handle := range closing {
		handle.cancel()
		_ = handle.conn.Close()
	}
	if inst != nil {
		lifecycleMu.Lock()
		defer lifecycleMu.Unlock()
		err := inst.Close()
		liveInstances--
		if liveInstances == 0 && activeLogger != nil {
			_ = activeLogger.Close()
			activeLogger, activeLogConfig, activeLogGeneration = nil, nil, 0
			selectLiveLogger()
		}
		return err
	}
	return nil
}

// IsRunning reports whether the embedded instance is live.
func (r *Runtime) IsRunning() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.instance != nil && r.instance.IsRunning()
}

// Dial opens one TCP path through the running instance to host:port.
// Returns a stream id used by Read / Write / CloseStream.
func (r *Runtime) Dial(host string, port int) (int64, error) {
	host = strings.TrimSpace(host)
	if host == "" || port <= 0 || port > 65535 {
		return 0, errEmptyDial
	}
	r.mu.Lock()
	inst, parent := r.instance, r.instanceContext
	r.mu.Unlock()
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
	id := r.nextID.Add(1)
	r.mu.Lock()
	if r.instance != inst {
		r.mu.Unlock()
		cancel()
		_ = conn.Close()
		return 0, errNotRunning
	}
	r.streams[id] = &streamHandle{conn: conn, cancel: cancel}
	r.mu.Unlock()
	return id, nil
}

// Read returns up to maxBytes from the stream. An empty slice with a nil
// error means EOF. A closed stream returns an error.
func (r *Runtime) Read(streamID int64, maxBytes int) ([]byte, error) {
	if maxBytes <= 0 {
		maxBytes = 16 * 1024
	}
	handle, err := r.lookup(streamID)
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
func (r *Runtime) Write(streamID int64, data []byte) error {
	handle, err := r.lookup(streamID)
	if err != nil {
		return err
	}
	_, err = handle.conn.Write(data)
	return err
}

// CloseStream closes one dial stream. Idempotent for unknown ids.
func (r *Runtime) CloseStream(streamID int64) {
	r.mu.Lock()
	handle, ok := r.streams[streamID]
	if ok {
		delete(r.streams, streamID)
	}
	r.mu.Unlock()
	if !ok {
		return
	}
	handle.cancel()
	_ = handle.conn.Close()
}

func (r *Runtime) lookup(streamID int64) (*streamHandle, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	handle, ok := r.streams[streamID]
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

func (r *Runtime) StartAsync(configJSON string, c Completion) {
	go func() { complete(c, 0, nil, r.Start(configJSON)) }()
}
func (r *Runtime) DialAsync(host string, port int, c Completion) {
	go func() { id, err := r.Dial(host, port); complete(c, id, nil, err) }()
}
func (r *Runtime) ReadAsync(streamID int64, maxBytes int, c Completion) {
	go func() { data, err := r.Read(streamID, maxBytes); complete(c, 0, data, err) }()
}

// Gomobile lends argument bytes only for this call; own them before returning.
func (r *Runtime) WriteAsync(streamID int64, data []byte, c Completion) {
	data = append([]byte(nil), data...)
	go func() { complete(c, 0, nil, r.Write(streamID, data)) }()
}
func (r *Runtime) StopAsync(c Completion) {
	go func() { complete(c, 0, nil, r.Stop()) }()
}
func (r *Runtime) CloseStreamAsync(streamID int64) {
	go r.CloseStream(streamID)
}

func Start(configJSON string) error                  { return legacy.Start(configJSON) }
func Stop() error                                    { return legacy.Stop() }
func IsRunning() bool                                { return legacy.IsRunning() }
func Dial(host string, port int) (int64, error)      { return legacy.Dial(host, port) }
func Read(id int64, maxBytes int) ([]byte, error)    { return legacy.Read(id, maxBytes) }
func Write(id int64, data []byte) error              { return legacy.Write(id, data) }
func CloseStream(id int64)                           { legacy.CloseStream(id) }
func StartAsync(configJSON string, c Completion)     { legacy.StartAsync(configJSON, c) }
func StopAsync(c Completion)                         { legacy.StopAsync(c) }
func DialAsync(host string, port int, c Completion)  { legacy.DialAsync(host, port, c) }
func ReadAsync(id int64, maxBytes int, c Completion) { legacy.ReadAsync(id, maxBytes, c) }
func WriteAsync(id int64, data []byte, c Completion) { legacy.WriteAsync(id, data, c) }
func CloseStreamAsync(id int64)                      { legacy.CloseStreamAsync(id) }
