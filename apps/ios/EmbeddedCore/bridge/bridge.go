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
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	_ "unsafe"

	xraylog "github.com/xtls/xray-core/app/log"
	clog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	xrayjson "github.com/xtls/xray-core/infra/conf/json"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet"
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
)

// Runtime owns an isolated Xray instance and its streams.
// Legacy package entry points below retain their original single-runtime API.
type Runtime struct {
	mu              sync.Mutex
	stopMu          sync.Mutex
	instance        *core.Instance
	streams         map[int64]*streamHandle
	streamCloses    *sync.WaitGroup
	nextID          atomic.Int64
	instanceContext context.Context
	instanceCancel  context.CancelFunc
	grpcSettings    []*internet.MemoryStreamConfig
}

func NewRuntime() *Runtime {
	return &Runtime{streams: map[int64]*streamHandle{}, streamCloses: &sync.WaitGroup{}}
}

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

// The pinned Xray gRPC transport caches one ClientConn per destination and
// outbound stream-settings pointer in a process-wide map and never releases
// it. Every outbound handler owns its own stream settings, so the pointer
// identifies the core generation. grpcDialerKey mirrors the pinned
// transport/internet/grpc.dialerConf layout.
type grpcDialerKey struct {
	net.Destination
	*internet.MemoryStreamConfig
}

//go:linkname grpcClients github.com/xtls/xray-core/transport/internet/grpc.globalDialerMap
var grpcClients map[grpcDialerKey]*grpc.ClientConn

//go:linkname grpcClientsMu github.com/xtls/xray-core/transport/internet/grpc.globalDialerAccess
var grpcClientsMu sync.Mutex

// grpcDialFunc mirrors the pinned transport/internet.dialFunc signature.
type grpcDialFunc func(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (stat.Connection, error)

//go:linkname transportDialers github.com/xtls/xray-core/transport/internet.transportDialerCache
var transportDialers map[string]grpcDialFunc

// grpcTransportDial is the pinned gRPC transport dialer that dialOwnedGRPC
// wraps. Tests replace it only while no dial is running.
var grpcTransportDial grpcDialFunc

func init() {
	grpcTransportDial = transportDialers["grpc"]
	if grpcTransportDial == nil {
		panic("pinned Xray gRPC transport dialer is not registered")
	}
	transportDialers["grpc"] = dialOwnedGRPC
}

// A gRPC generation is the stream settings of one gRPC outbound handler of
// one runtime. The pinned VLESS retry loop ignores cancellation, so a stopped
// generation may dial again after Stop. Retirement therefore rejects every
// later dial and releases the generation's cached clients once its in-flight
// dials have returned, however long they are delayed.
type grpcGeneration struct {
	inflight int
	retired  bool
}

// Lock order: grpcGenerationsMu before grpcClientsMu.
var grpcGenerationsMu sync.Mutex
var grpcGenerations = map[*internet.MemoryStreamConfig]*grpcGeneration{}

func dialOwnedGRPC(ctx context.Context, dest net.Destination, settings *internet.MemoryStreamConfig) (stat.Connection, error) {
	grpcGenerationsMu.Lock()
	generation := grpcGenerations[settings]
	if generation == nil || generation.retired {
		grpcGenerationsMu.Unlock()
		return nil, errNotRunning
	}
	generation.inflight++
	grpcGenerationsMu.Unlock()
	defer finishGRPCDial(settings, generation)
	return grpcTransportDial(ctx, dest, settings)
}

func finishGRPCDial(settings *internet.MemoryStreamConfig, generation *grpcGeneration) {
	grpcGenerationsMu.Lock()
	generation.inflight--
	var released []*grpc.ClientConn
	if generation.retired && generation.inflight == 0 {
		released = releaseGRPCGeneration(settings)
	}
	grpcGenerationsMu.Unlock()
	closeGRPCClients(released)
}

func registerGRPCGenerations(settings []*internet.MemoryStreamConfig) {
	grpcGenerationsMu.Lock()
	defer grpcGenerationsMu.Unlock()
	for _, s := range settings {
		grpcGenerations[s] = &grpcGeneration{}
	}
}

// retireGRPCGenerations rejects later dials and returns the cached clients of
// generations with no dial in flight. The last in-flight dial of any other
// generation releases it.
func retireGRPCGenerations(settings []*internet.MemoryStreamConfig) []*grpc.ClientConn {
	grpcGenerationsMu.Lock()
	defer grpcGenerationsMu.Unlock()
	var released []*grpc.ClientConn
	for _, s := range settings {
		generation := grpcGenerations[s]
		if generation == nil {
			continue
		}
		generation.retired = true
		if generation.inflight == 0 {
			released = append(released, releaseGRPCGeneration(s)...)
		}
	}
	return released
}

// releaseGRPCGeneration forgets a retired generation and removes its cached
// clients. The caller holds grpcGenerationsMu and closes the result.
func releaseGRPCGeneration(settings *internet.MemoryStreamConfig) []*grpc.ClientConn {
	delete(grpcGenerations, settings)
	grpcClientsMu.Lock()
	defer grpcClientsMu.Unlock()
	var released []*grpc.ClientConn
	for key, client := range grpcClients {
		if key.MemoryStreamConfig != settings {
			continue
		}
		delete(grpcClients, key)
		if client != nil {
			released = append(released, client)
		}
	}
	return released
}

var memoryStreamConfigType = reflect.TypeFor[*internet.MemoryStreamConfig]()

// grpcStreamSettings returns the stream settings of the instance's gRPC
// outbound handlers. Other transports never reach the gRPC client cache.
func grpcStreamSettings(inst *core.Instance) []*internet.MemoryStreamConfig {
	manager, ok := inst.GetFeature(outbound.ManagerType()).(outbound.Manager)
	if !ok {
		return nil
	}
	var settings []*internet.MemoryStreamConfig
	for _, handler := range manager.ListHandlers(context.Background()) {
		value := reflect.ValueOf(handler)
		if value.Kind() != reflect.Pointer || value.IsNil() || value.Elem().Kind() != reflect.Struct {
			continue
		}
		field := value.Elem().FieldByName("streamSettings")
		if !field.IsValid() || field.Type() != memoryStreamConfigType || field.IsNil() {
			continue
		}
		if s := (*internet.MemoryStreamConfig)(field.UnsafePointer()); s.ProtocolName == "grpc" {
			settings = append(settings, s)
		}
	}
	return settings
}

func closeGRPCClients(clients []*grpc.ClientConn) {
	for _, client := range clients {
		_ = client.Close()
	}
}

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
	r.grpcSettings = grpcStreamSettings(inst)
	registerGRPCGenerations(r.grpcSettings)
	r.instanceContext, r.instanceCancel = context.WithCancel(context.Background())
	return nil
}

// Stop closes every open dial stream and the running instance.
func (r *Runtime) Stop() error {
	r.stopMu.Lock()
	defer r.stopMu.Unlock()
	r.mu.Lock()
	inst, cancel, closing := r.instance, r.instanceCancel, r.streams
	pendingCloses := r.streamCloses
	ownedSettings := r.grpcSettings
	r.instance, r.instanceContext, r.instanceCancel = nil, nil, nil
	r.grpcSettings = nil
	r.streams = map[int64]*streamHandle{}
	r.streamCloses = &sync.WaitGroup{}
	r.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	for _, handle := range closing {
		handle.cancel()
		_ = handle.conn.Close()
	}
	closeGRPCClients(retireGRPCGenerations(ownedSettings))
	var stopErr error
	if inst != nil {
		lifecycleMu.Lock()
		stopErr = inst.Close()
		liveInstances--
		if liveInstances == 0 && activeLogger != nil {
			_ = activeLogger.Close()
			activeLogger, activeLogConfig, activeLogGeneration = nil, nil, 0
			selectLiveLogger()
		}
		lifecycleMu.Unlock()
	}
	// A separately closed stream may already be absent from the map. Swapping the
	// generation under mu excludes new Adds to this group before waiting.
	if pendingCloses != nil {
		pendingCloses.Wait()
	}
	return stopErr
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
	if !ok {
		r.mu.Unlock()
		return
	}
	group := r.streamCloses
	group.Add(1)
	delete(r.streams, streamID)
	r.mu.Unlock()
	defer group.Done()
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
