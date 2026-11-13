package embeddedcore

import (
	"net"
	"testing"
	"time"
)

const freedomConfig = `{
  "log": {"loglevel": "none"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}`

func TestStartStopAndRejectDuplicate(t *testing.T) {
	_ = Stop()
	if IsRunning() {
		t.Fatal("expected stopped")
	}
	if err := Start(freedomConfig); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	if !IsRunning() {
		t.Fatal("expected running")
	}
	if err := Start(freedomConfig); err == nil {
		t.Fatal("duplicate start must fail")
	}
	if err := Stop(); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if IsRunning() {
		t.Fatal("expected stopped after stop")
	}
}

func TestDialRequiresRunningInstance(t *testing.T) {
	_ = Stop()
	if _, err := Dial("example.invalid", 443); err == nil {
		t.Fatal("dial without start must fail")
	}
}

// Thousands of reads exceed the practical dispatch-worker limit, but must not
// prevent async write, another dial, close or stop callbacks from completing.
func TestAsyncIOBeyondDispatchCapacity(t *testing.T) {
	_ = Stop()
	if err := Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = Stop() })
	const count = 2048
	reads := make(chan asyncResult, count)
	entered := make(chan struct{}, count)
	peers := make([]net.Conn, 0, count)
	ids := make([]int64, 0, count)
	for i := 0; i < count; i++ {
		a, b := net.Pipe()
		id := nextID.Add(1)
		mu.Lock()
		streams[id] = &streamHandle{conn: observedReadConn{a, entered}, cancel: func() {}}
		mu.Unlock()
		peers = append(peers, b)
		ids = append(ids, id)
		ReadAsync(id, 1, resultReceiver{reads})
	}
	t.Cleanup(func() {
		for _, peer := range peers {
			_ = peer.Close()
		}
	})
	for i := 0; i < count; i++ {
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			t.Fatal("reads not parked")
		}
	}
	// Duplex write on a stream whose read is pending.
	written := make(chan asyncResult, 1)
	go func() { buf := make([]byte, 1); _, _ = peers[0].Read(buf) }()
	WriteAsync(ids[0], []byte("x"), resultReceiver{written})
	if r := awaitResult(t, written); r.failure != "" {
		t.Fatal(r.failure)
	}
	// A new real local dial succeeds while all synthetic reads remain pending.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			defer conn.Close()
			_, _ = conn.Read(make([]byte, 1))
		}
	}()
	dialed := make(chan asyncResult, 1)
	DialAsync("127.0.0.1", listener.Addr().(*net.TCPAddr).Port, resultReceiver{dialed})
	dial := awaitResult(t, dialed)
	if dial.failure != "" || dial.value == 0 {
		t.Fatalf("dial: %+v", dial)
	}
	CloseStreamAsync(dial.value)
	CloseStreamAsync(ids[0])
	_ = awaitResult(t, reads)
	stopped := make(chan asyncResult, 1)
	StopAsync(resultReceiver{stopped})
	if r := awaitResult(t, stopped); r.failure != "" {
		t.Fatal(r.failure)
	}
	for i := 1; i < count; i++ {
		_ = awaitResult(t, reads)
	}
	select {
	case r := <-reads:
		t.Fatalf("duplicate completion: %+v", r)
	default:
	}
	if IsRunning() {
		t.Fatal("still running")
	}
}

type asyncResult struct {
	value   int64
	data    []byte
	failure string
}
type resultReceiver struct{ results chan asyncResult }

func (r resultReceiver) Complete(value int64, data []byte, failure string) {
	r.results <- asyncResult{value, data, failure}
}
func awaitResult(t *testing.T, ch <-chan asyncResult) asyncResult {
	t.Helper()
	select {
	case result := <-ch:
		return result
	case <-time.After(5 * time.Second):
		t.Fatal("native callback did not progress")
		return asyncResult{}
	}
}

type observedReadConn struct {
	net.Conn
	entered chan struct{}
}

func (c observedReadConn) Read(b []byte) (int, error) { c.entered <- struct{}{}; return c.Conn.Read(b) }

// The caller may reuse its argument immediately after the async entry returns.
func TestAsyncWriteOwnsBorrowedArgument(t *testing.T) {
	_ = Stop()
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	id := nextID.Add(1)
	mu.Lock()
	streams[id] = &streamHandle{conn: a, cancel: func() {}}
	mu.Unlock()
	defer CloseStream(id)
	written := make(chan asyncResult, 1)
	input := []byte("original")
	WriteAsync(id, input, resultReceiver{written})
	copy(input, "mutated!")
	_ = b.SetReadDeadline(time.Now().Add(5 * time.Second))
	got := make([]byte, len(input))
	if _, err := b.Read(got); err != nil {
		t.Fatal(err)
	}
	if string(got) != "original" {
		t.Fatalf("borrowed bytes escaped: %q", got)
	}
	if r := awaitResult(t, written); r.failure != "" {
		t.Fatal(r.failure)
	}
}
