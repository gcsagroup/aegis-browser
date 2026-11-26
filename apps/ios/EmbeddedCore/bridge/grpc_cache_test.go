package embeddedcore

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
)

func grpcRelayConfig(port int) string {
	return `{
  "log": {"loglevel": "none"},
  "inbounds": [],
  "outbounds": [{
    "protocol": "vless",
    "tag": "relay",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": ` + strconv.Itoa(port) + `,
      "users": [{"id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}]}]},
    "streamSettings": {"network": "grpc", "grpcSettings": {"serviceName": "probe"}}
  }]
}`
}

// startGRPCSink accepts TCP connections and discards their bytes.
func startGRPCSink(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var served sync.WaitGroup
	served.Add(1)
	go func() {
		defer served.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { _, _ = io.Copy(io.Discard, conn); _ = conn.Close() }()
		}
	}()
	t.Cleanup(func() {
		_ = listener.Close()
		served.Wait()
	})
	return listener.Addr().(*net.TCPAddr).Port
}

func cachedGRPCClients(owner []*internet.MemoryStreamConfig) []*grpc.ClientConn {
	owned := map[*internet.MemoryStreamConfig]bool{}
	for _, settings := range owner {
		owned[settings] = true
	}
	grpcClientsMu.Lock()
	defer grpcClientsMu.Unlock()
	var clients []*grpc.ClientConn
	for key, client := range grpcClients {
		if owned[key.MemoryStreamConfig] {
			clients = append(clients, client)
		}
	}
	return clients
}

func runtimeStreamSettings(r *Runtime) []*internet.MemoryStreamConfig {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]*internet.MemoryStreamConfig(nil), r.grpcSettings...)
}

type grpcGenerationSnapshot struct {
	registered bool
	inflight   int
	retired    bool
}

func grpcGenerationState(settings *internet.MemoryStreamConfig) grpcGenerationSnapshot {
	grpcGenerationsMu.Lock()
	defer grpcGenerationsMu.Unlock()
	generation := grpcGenerations[settings]
	if generation == nil {
		return grpcGenerationSnapshot{}
	}
	return grpcGenerationSnapshot{registered: true, inflight: generation.inflight, retired: generation.retired}
}

func dialUntilGRPCClientCached(t *testing.T, r *Runtime) ([]*internet.MemoryStreamConfig, *grpc.ClientConn) {
	t.Helper()
	settings := runtimeStreamSettings(r)
	if len(settings) != 1 {
		t.Fatalf("runtime owns %d gRPC stream settings, want 1", len(settings))
	}
	if _, err := r.Dial("example.com", 443); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if clients := cachedGRPCClients(settings); len(clients) == 1 {
			return settings, clients[0]
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("dial did not create a cached gRPC client")
	return nil, nil
}

// waitGRPCClientsReleased waits until a retired generation's last in-flight
// dial has returned and released its cached clients.
func waitGRPCClientsReleased(t *testing.T, settings []*internet.MemoryStreamConfig, clients ...*grpc.ClientConn) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		cached := cachedGRPCClients(settings)
		registered := false
		for _, s := range settings {
			if grpcGenerationState(s).registered {
				registered = true
			}
		}
		shutdown := true
		for _, client := range clients {
			if client.GetState() != connectivity.Shutdown {
				shutdown = false
			}
		}
		if len(cached) == 0 && !registered && shutdown {
			return
		}
		if !time.Now().Before(deadline) {
			t.Fatalf("stopped generation kept %d cached gRPC clients (registered: %v, released clients shut down: %v)",
				len(cached), registered, shutdown)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestStopReleasesOnlyItsGenerationsCachedGRPCClients(t *testing.T) {
	config := grpcRelayConfig(startGRPCSink(t))

	first, concurrent := NewRuntime(), NewRuntime()
	if err := first.Start(config); err != nil {
		t.Fatal(err)
	}
	defer first.Stop()
	if err := concurrent.Start(config); err != nil {
		t.Fatal(err)
	}
	defer concurrent.Stop()
	firstSettings, firstClient := dialUntilGRPCClientCached(t, first)
	concurrentSettings, concurrentClient := dialUntilGRPCClientCached(t, concurrent)

	if err := first.Stop(); err != nil {
		t.Fatal(err)
	}
	waitGRPCClientsReleased(t, firstSettings, firstClient)
	if clients := cachedGRPCClients(concurrentSettings); len(clients) != 1 || clients[0] != concurrentClient {
		t.Fatal("stopping one runtime released another live runtime's gRPC client")
	}
	if concurrentClient.GetState() == connectivity.Shutdown {
		t.Fatal("stopping one runtime shut down another live runtime's gRPC client")
	}
	if state := grpcGenerationState(concurrentSettings[0]); !state.registered || state.retired {
		t.Fatal("stopping one runtime retired another live runtime's gRPC generation")
	}

	// Switching back to the same route starts a new generation with its own client.
	if err := first.Start(config); err != nil {
		t.Fatal(err)
	}
	switchedSettings, switchedClient := dialUntilGRPCClientCached(t, first)
	if switchedClient == firstClient {
		t.Fatal("route switch reused the retired gRPC client")
	}
	if clients := cachedGRPCClients(firstSettings); len(clients) != 0 {
		t.Fatal("route switch revived the retired generation's gRPC client")
	}

	if err := concurrent.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := first.Stop(); err != nil {
		t.Fatal(err)
	}
	waitGRPCClientsReleased(t, append(concurrentSettings, switchedSettings...), concurrentClient, switchedClient)
}

// A stopped generation's retry may be delayed arbitrarily, for example while
// iOS suspends the process during the pinned VLESS backoff. Retirement must
// hold until that dial returns, release the client it created, and reject
// every later dial without reaching the transport.
func TestRetiredGRPCGenerationOutlastsDelayedDialAndRejectsLaterDials(t *testing.T) {
	config := grpcRelayConfig(startGRPCSink(t))
	pinned := grpcTransportDial
	entered := make(chan struct{}, 8)
	release := make(chan struct{})
	created := make(chan []*grpc.ClientConn, 8)
	errUnexpectedDial := errors.New("unexpected later gRPC transport dial")
	var calls atomic.Int32
	grpcTransportDial = func(ctx context.Context, dest xnet.Destination, settings *internet.MemoryStreamConfig) (stat.Connection, error) {
		// Claim the call number before signalling, so a regressed
		// retired-generation probe can never take the held first slot. Later
		// calls are recorded and fail fast without reaching the real transport.
		call := calls.Add(1)
		select {
		case entered <- struct{}{}:
		default:
		}
		if call != 1 {
			return nil, errUnexpectedDial
		}
		<-release
		conn, err := pinned(ctx, dest, settings)
		created <- cachedGRPCClients([]*internet.MemoryStreamConfig{settings})
		return conn, err
	}
	released := false
	r := NewRuntime()
	var stopped chan error
	// Teardown runs on success and on t.Fatal: unblock the delayed dial first so
	// a regressed Stop that waits for it cannot deadlock the deferred Stop, then
	// stop the runtime and restore the process-wide transport stub.
	defer func() {
		if !released {
			released = true
			close(release)
		}
		if stopped != nil {
			select {
			case <-stopped:
			case <-time.After(10 * time.Second):
			}
		}
		_ = r.Stop()
		grpcTransportDial = pinned
	}()
	if err := r.Start(config); err != nil {
		t.Fatal(err)
	}
	settings := runtimeStreamSettings(r)
	if len(settings) != 1 {
		t.Fatalf("runtime owns %d gRPC stream settings, want 1", len(settings))
	}
	if _, err := r.Dial("example.com", 443); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("outbound did not reach the gRPC transport")
	}
	if state := grpcGenerationState(settings[0]); !state.registered || state.retired || state.inflight != 1 {
		t.Fatalf("live generation state = %+v", state)
	}

	stopResult := make(chan error, 1)
	stopped = stopResult
	go func() { stopResult <- r.Stop() }()
	select {
	case err := <-stopResult:
		stopped = nil
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Stop waited for a delayed gRPC dial")
	}
	if state := grpcGenerationState(settings[0]); !state.registered || !state.retired || state.inflight != 1 {
		t.Fatalf("retired generation with a delayed dial: state = %+v", state)
	}
	// A later retry of the stopped generation never reaches the transport.
	if _, err := dialOwnedGRPC(context.Background(), xnet.TCPDestination(xnet.LocalHostIP, 443), settings[0]); !errors.Is(err, errNotRunning) {
		t.Fatalf("retired generation dial error = %v, want errNotRunning", err)
	}
	if len(entered) != 0 {
		t.Fatal("retired generation dial reached the gRPC transport")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("gRPC transport dialled %d times, want only the delayed dial", got)
	}

	// The delayed dial resumes and the pinned transport caches a new client
	// under the retired settings; its return must release that client.
	released = true
	close(release)
	var late []*grpc.ClientConn
	select {
	case late = <-created:
	case <-time.After(10 * time.Second):
		t.Fatal("delayed dial did not return")
	}
	if len(late) != 1 {
		t.Fatalf("delayed dial cached %d gRPC clients, want 1", len(late))
	}
	waitGRPCClientsReleased(t, settings, late...)
	if _, err := dialOwnedGRPC(context.Background(), xnet.TCPDestination(xnet.LocalHostIP, 443), settings[0]); !errors.Is(err, errNotRunning) {
		t.Fatalf("released generation dial error = %v, want errNotRunning", err)
	}
}

func TestNonGRPCRuntimeRegistersNoGRPCGeneration(t *testing.T) {
	grpcGenerationsMu.Lock()
	before := len(grpcGenerations)
	grpcGenerationsMu.Unlock()
	r := NewRuntime()
	if err := r.Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	defer r.Stop()
	if settings := runtimeStreamSettings(r); len(settings) != 0 {
		t.Fatalf("non-gRPC runtime owns %d gRPC stream settings", len(settings))
	}
	grpcGenerationsMu.Lock()
	after := len(grpcGenerations)
	grpcGenerationsMu.Unlock()
	if after != before {
		t.Fatalf("non-gRPC runtime registered %d gRPC generations", after-before)
	}
}
