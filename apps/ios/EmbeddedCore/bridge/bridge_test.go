package embeddedcore

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	clog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/infra/conf"
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

func TestStopAwaitsStreamCloseAlreadyRemovedFromRuntime(t *testing.T) {
	runtime := NewRuntime()
	if err := runtime.Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	local, peer := net.Pipe()
	defer peer.Close()
	entered, release := make(chan struct{}), make(chan struct{})
	unblock := sync.OnceFunc(func() { close(release) })
	defer unblock()
	runtime.mu.Lock()
	runtime.streams[1] = &streamHandle{conn: delayedCloseConn{local, entered, release}, cancel: func() {}}
	runtime.mu.Unlock()
	runtime.CloseStreamAsync(1)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("independent stream close did not start")
	}
	stopped := make(chan asyncResult, 1)
	runtime.StopAsync(resultReceiver{stopped})
	select {
	case <-stopped:
		t.Fatal("stop acknowledged before the detached stream finished closing")
	case <-time.After(50 * time.Millisecond):
	}
	unblock()
	if result := awaitResult(t, stopped); result.failure != "" {
		t.Fatal(result.failure)
	}
}

type delayedCloseConn struct {
	net.Conn
	entered chan<- struct{}
	release <-chan struct{}
}

func (c delayedCloseConn) Close() error {
	close(c.entered)
	<-c.release
	return c.Conn.Close()
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
		id := legacy.nextID.Add(1)
		legacy.mu.Lock()
		legacy.streams[id] = &streamHandle{conn: observedReadConn{a, entered}, cancel: func() {}}
		legacy.mu.Unlock()
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
	id := legacy.nextID.Add(1)
	legacy.mu.Lock()
	legacy.streams[id] = &streamHandle{conn: a, cancel: func() {}}
	legacy.mu.Unlock()
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

func TestRuntimeOwnershipSeparatesStreamsAndStop(t *testing.T) {
	first, second := NewRuntime(), NewRuntime()
	if err := first.Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	if err := second.Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	defer first.Stop()
	defer second.Stop()
	a, b := net.Pipe()
	defer b.Close()
	first.streams[1] = &streamHandle{conn: a, cancel: func() {}}
	if _, err := second.Read(1, 1); err == nil {
		t.Fatal("another runtime must not read an owned stream")
	}
	second.CloseStream(1)
	if _, err := first.lookup(1); err != nil {
		t.Fatal("another runtime closed an owned stream")
	}
	if err := second.Stop(); err != nil {
		t.Fatal(err)
	}
	if !first.IsRunning() {
		t.Fatal("another runtime stopped first runtime")
	}
}

func TestConcurrentRuntimeInitialization(t *testing.T) {
	const count = 12
	gate := make(chan struct{})
	results := make(chan error, count)
	runtimes := make([]*Runtime, count)
	for i := range runtimes {
		runtimes[i] = NewRuntime()
		go func(runtime *Runtime) {
			<-gate
			results <- runtime.Start(freedomConfig)
		}(runtimes[i])
	}
	close(gate)
	for range count {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	var stopped sync.WaitGroup
	for _, runtime := range runtimes {
		stopped.Go(func() { _ = runtime.Stop() })
	}
	stopped.Wait()
}

func diagnosticConfig(t *testing.T, path, mask string, generation int64) string {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal([]byte(freedomConfig), &value); err != nil {
		t.Fatal(err)
	}
	value["log"] = map[string]any{"loglevel": "info", "access": "none", "error": path, "maskAddress": mask}
	if generation != 0 {
		value["aegisLogCaptureGeneration"] = generation
	}
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func requireNativeLog(t *testing.T, path, marker string) {
	t.Helper()
	clog.Record(&clog.GeneralMessage{Severity: clog.Severity_Info, Content: marker})
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(path)
		if strings.Contains(string(data), marker) {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("active native logger lost %q", marker)
}

func TestRotatedCaptureOutlivesRuntimeThatOpenedIt(t *testing.T) {
	directory := t.TempDir()
	oldPath, resumedPath := filepath.Join(directory, "old.log"), filepath.Join(directory, "resumed.log")
	first, second := NewRuntime(), NewRuntime()
	if err := first.Start(diagnosticConfig(t, oldPath, "", 0)); err != nil {
		t.Fatal(err)
	}
	defer first.Stop()
	requireNativeLog(t, oldPath, "old-capture-only")
	if err := second.Start(diagnosticConfig(t, resumedPath, "", 0)); err != nil {
		t.Fatal(err)
	}
	defer second.Stop()
	if err := second.Stop(); err != nil {
		t.Fatal(err)
	}
	if !first.IsRunning() || clog.GetSeverity() != clog.Severity_Info {
		t.Fatal("expected surviving runtime and info logger")
	}
	requireNativeLog(t, resumedPath, "surviving-runtime-marker")
	if data, err := os.ReadFile(resumedPath); err != nil || strings.Contains(string(data), "old-capture-only") {
		t.Fatalf("old capture record reached the resumed sink: %v", err)
	}
}

func TestQuietStartAndLoggerFailureKeepTheActiveNativeSink(t *testing.T) {
	path := filepath.Join(t.TempDir(), "active.log")
	first, quiet := NewRuntime(), NewRuntime()
	if err := first.Start(diagnosticConfig(t, path, "", 0)); err != nil {
		t.Fatal(err)
	}
	defer first.Stop()
	if err := quiet.Start(diagnosticConfig(t, path, "invalid-mask", 0)); err == nil {
		t.Fatal("expected a failed logging startup")
	}
	requireNativeLog(t, path, "after-failed-logging-start")
	if err := quiet.Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	defer quiet.Stop()
	requireNativeLog(t, path, "while-quiet-runtime-is-live")
	if err := quiet.Stop(); err != nil {
		t.Fatal(err)
	}
	requireNativeLog(t, path, "after-quiet-runtime-stop")
}

func TestLateStartCannotRestoreRetiredCapture(t *testing.T) {
	directory := t.TempDir()
	oldPath := filepath.Join(directory, "retired.log")
	newPath := filepath.Join(directory, "resumed.log")
	oldGeneration := NewLogCaptureGeneration()
	oldConfig := diagnosticConfig(t, oldPath, "", oldGeneration)
	RetireLogCaptureGeneration(oldGeneration)
	late, resumed := NewRuntime(), NewRuntime()
	defer late.Stop()
	defer resumed.Stop()
	if err := late.Start(oldConfig); err != nil || !late.IsRunning() {
		t.Fatalf("retired capture prevented runtime startup: %v", err)
	}
	if severity := clog.GetSeverity(); severity != clog.Severity_Unknown {
		t.Fatalf("retired capture installed a logger while off: %v", severity)
	}
	if err := late.Stop(); err != nil {
		t.Fatal(err)
	}
	newGeneration := NewLogCaptureGeneration()
	RetireLogCaptureGeneration(oldGeneration) // old owner must not retire the new capture
	if err := resumed.Start(diagnosticConfig(t, newPath, "", newGeneration)); err != nil {
		t.Fatal(err)
	}
	if err := late.Start(oldConfig); err != nil || !late.IsRunning() {
		t.Fatalf("late runtime did not start: %v", err)
	}
	requireNativeLog(t, newPath, "after-late-start")
	if err := resumed.Stop(); err != nil {
		t.Fatal(err)
	}
	requireNativeLog(t, newPath, "after-new-runtime-stop")
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("retired capture reopened: %v", err)
	}
}

func TestQuietRuntimeAdvertisesDisabledSeverity(t *testing.T) {
	runtime := NewRuntime()
	if err := runtime.Start(freedomConfig); err != nil {
		t.Fatal(err)
	}
	defer runtime.Stop()
	if severity := clog.GetSeverity(); severity != clog.Severity_Unknown {
		t.Fatalf("quiet runtime advertises %v instead of disabled", severity)
	}
}

func TestRealityClientFieldAdmissionMatchesPinnedBuilder(t *testing.T) {
	for _, test := range []struct{ fingerprint, spider, invalidField string }{
		{"Chrome", "", ""}, {"random", "/", ""}, {"helloios_14", "/path%20name?q=1", ""},
		{"unsafe", "", "fingerprint"}, {"HelloGolang", "", "fingerprint"}, {"unknown-hello", "", "fingerprint"},
		{"chrome", "relative", "spiderX"}, {"chrome", "/bad%ZZ", "spiderX"}, {"chrome", "/bad\x00", "spiderX"},
	} {
		if field := ValidateRealityClientFields(test.fingerprint, test.spider); field != test.invalidField {
			t.Errorf("fingerprint %q, spider %q: got %q, want %q", test.fingerprint, test.spider, field, test.invalidField)
		}
		// The pinned builder dereferences a nil URL for these malformed paths.
		if test.spider == "/bad%ZZ" || test.spider == "/bad\x00" {
			continue
		}
		config := conf.REALITYConfig{Fingerprint: test.fingerprint, SpiderX: test.spider,
			PublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", ServerName: "example.invalid"}
		if _, err := config.Build(); (err != nil) != (test.invalidField != "") {
			t.Errorf("pinned builder diverged for %q, %q: %v", test.fingerprint, test.spider, err)
		}
	}
}

func TestManualRealityRejectsSpiderWorkControls(t *testing.T) {
	for _, spider := range []string{
		"/?p=1000000000", "/?c=1000000000", "/?t=1-1000000000", "/?i=1000000000", "/?r=1000000000",
		"/?q=ordinary&%63=1", "/?c=&c=1000000000", "/?r", "/?q=%ZZ&c=1000000000",
	} {
		if got := ValidateRealityClientFields("chrome", spider); got != "spiderX" {
			t.Errorf("manual spider %q: got %q, want spiderX", spider, got)
		}
	}
	for _, spider := range []string{"", "/", "/path%20name?color=red&color=blue", "/?q=p%3D1%26c%3D2"} {
		if got := ValidateRealityClientFields("chrome", spider); got != "" {
			t.Errorf("manual spider %q: unexpected rejection %q", spider, got)
		}
	}
}
