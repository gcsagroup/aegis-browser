package aegismeter

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type scriptedQuota struct {
	reply func(map[string]any) map[string]any
}

type quotaWriter struct {
	write       writeFunc
	deadlineErr error
}

func (w quotaWriter) Write(p []byte) (int, error)      { return w.write(p) }
func (w quotaWriter) SetWriteDeadline(time.Time) error { return w.deadlineErr }

func quotaFixture(t *testing.T, reply func(map[string]any) map[string]any) *Flow {
	t.Helper()
	socket, server := net.Pipe()
	inbound, remote := net.Pipe()
	_, cancel := context.WithCancel(context.Background())
	q := &quotaGuard{inbound: inbound, expires: time.Now().Add(time.Minute), closed: make(chan struct{}), cancel: cancel}
	f := &Flow{id: "0123456789abcdef0123456789abcdef", conn: socket, reader: bufio.NewReader(socket), quota: q}
	t.Cleanup(func() { q.stop(); socket.Close(); server.Close(); remote.Close() })
	go scriptedQuota{reply: reply}.accept(t, server)
	return f
}

func TestQuotaConfirmedPrefixes(t *testing.T) {
	for _, test := range []struct {
		name, path          string
		n, start, end, size int
		actual              int
		complete            bool
		deadlineErr         error
	}{
		{"target short write", "target_tcp", 3, 0, 8, 8, 3, true, nil},
		{"raw short write", "vision_raw", 2, 0, 8, 8, 2, true, nil},
		{"partial framed payload", "vision_padded", 8, 5, 10, 12, 3, false, nil},
		{"payload before failed padding", "vision_padded", 10, 5, 10, 12, 5, true, nil},
		{"partial plain TLS payload", "vision_plain", 4, 0, 8, 8, 4, false, nil},
		{"deadline before write", "vision_plain", 0, 0, 8, 8, 0, true, os.ErrDeadlineExceeded},
		{"invalid writer progress", "vision_raw", 9, 0, 8, 8, 0, false, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			seen := make(chan map[string]any, 3)
			f := quotaFixture(t, func(m map[string]any) map[string]any {
				seen <- m
				return map[string]any{"ok": true, "granted": test.end - test.start, "expiresAt": time.Now().Add(time.Minute).UnixMilli()}
			})
			w := quotaWriter{write: func([]byte) (int, error) {
				if test.deadlineErr != nil {
					t.Fatal("writer called after SetWriteDeadline failed")
				}
				return test.n, io.ErrUnexpectedEOF
			}, deadlineErr: test.deadlineErr}
			before := time.Now().UnixMilli()
			n, err := f.Write(w, make([]byte, test.size), test.start, test.end, test.path)
			wantN := test.n
			if wantN > test.size {
				wantN = 0
			}
			if err == nil || n != wantN {
				t.Fatal(n, err)
			}
			if err := f.Finish(); err != nil {
				t.Fatal(err)
			}
			<-seen // reservation
			commit, finish := <-seen, <-seen
			direction, total := "down", "downloadedBytes"
			if test.path == "target_tcp" {
				direction, total = "up", "uploadedBytes"
			}
			stamp, ok := commit["measuredAt"].(float64)
			if commit["op"] != "commit" || commit["direction"] != direction || commit["ticket"] != float64(1) ||
				commit["bytes"] != float64(test.actual) || commit["complete"] != test.complete ||
				finish[total] != float64(test.actual) || finish["complete"] != test.complete ||
				!ok || stamp < float64(before) || stamp > float64(time.Now().UnixMilli()) {
				t.Fatal(commit, finish)
			}
		})
	}
}

func TestQuotaLostCommitAckReplaysBeforeTerminal(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "quota-replay-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	socket := filepath.Join(root, "m.sock")
	dir, err := recoveryDirectory(socket)
	if err != nil {
		t.Fatal(err)
	}
	var f *Flow
	committed := make(chan map[string]any, 1)
	f = quotaFixture(t, func(m map[string]any) map[string]any {
		if m["op"] == "commit" {
			committed <- m
			f.conn.Close() // Collector stored the commit, but its ACK was lost.
			return nil
		}
		return map[string]any{"ok": true, "granted": 3, "expiresAt": time.Now().Add(time.Minute).UnixMilli()}
	})
	f.recoveryDir = dir
	w := quotaWriter{write: func(p []byte) (int, error) { return len(p), nil }}
	if n, err := f.Write(w, []byte{1, 2, 3}, 0, 3, "target_tcp"); n != 3 || err == nil {
		t.Fatal(n, err)
	}
	commit := <-committed
	if err := f.Finish(); err == nil {
		t.Fatal("lost ACK was acknowledged")
	}
	frames, err := pending(filepath.Join(dir, f.id+".json"))
	if err != nil || len(frames) != 2 || frames[0]["op"] != "commit" || frames[1]["op"] != "finish" {
		t.Fatal(frames, err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	seen := make(chan []observed, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var messages []observed
		scanner := bufio.NewScanner(conn)
		for scanner.Scan() {
			var frame observed
			if json.Unmarshal(scanner.Bytes(), &frame) != nil {
				return
			}
			messages = append(messages, frame)
			io.WriteString(conn, "{\"ok\":true}\n")
			if frame["op"] == "finish" {
				break
			}
		}
		seen <- messages
	}()
	replay(socket, dir)
	select {
	case messages := <-seen:
		if len(messages) != 2 || messages[0]["op"] != "commit" || messages[0]["bytes"] != float64(3) ||
			messages[0]["ticket"] != float64(1) || messages[0]["complete"] != true ||
			messages[0]["measuredAt"] != commit["measuredAt"] || messages[1]["uploadedBytes"] != float64(3) || messages[1]["complete"] != true {
			t.Fatal(messages)
		}
	case <-time.After(time.Second):
		t.Fatal("quota replay did not finish")
	}
	if frames, err = pending(filepath.Join(dir, f.id+".json")); err != nil || len(frames) != 0 {
		t.Fatal(frames, err)
	}
}

func TestQuotaTicketsStayOrderedInBothDirections(t *testing.T) {
	tickets := map[string]float64{"up": 0, "down": 0}
	pending := map[string]bool{}
	f := quotaFixture(t, func(m map[string]any) map[string]any {
		direction, _ := m["direction"].(string)
		switch m["op"] {
		case "reserve":
			if pending[direction] || m["ticket"] != tickets[direction]+1 {
				t.Error("reservation overtook its previous ticket", m)
			}
			tickets[direction] = m["ticket"].(float64)
			pending[direction] = true
		case "commit":
			if !pending[direction] || m["ticket"] != tickets[direction] {
				t.Error("confirmation out of ticket order", m)
			}
			pending[direction] = false
		case "finish":
			if m["uploadedBytes"] != float64(8) || m["downloadedBytes"] != float64(8) || pending["up"] || pending["down"] {
				t.Error("unfinished direction", m)
			}
		}
		return map[string]any{"ok": true, "granted": 1, "expiresAt": time.Now().Add(time.Minute).UnixMilli()}
	})
	var wg sync.WaitGroup
	for range 8 {
		for _, path := range []string{"target_tcp", "vision_raw"} {
			wg.Go(func() {
				w := quotaWriter{write: func(p []byte) (int, error) { return len(p), nil }}
				if n, err := f.Write(w, []byte{1}, 0, 1, path); n != 1 || err != nil {
					t.Error(n, err)
				}
			})
		}
	}
	wg.Wait()
	if err := f.Finish(); err != nil {
		t.Fatal(err)
	}
}

func (s scriptedQuota) accept(t *testing.T, c net.Conn) {
	defer c.Close()
	scan := bufio.NewScanner(c)
	for scan.Scan() {
		var msg map[string]any
		if err := json.Unmarshal(scan.Bytes(), &msg); err != nil {
			t.Error(err)
			return
		}
		if err := json.NewEncoder(c).Encode(s.reply(msg)); err != nil {
			return
		}
	}
}

func TestQuotaTailFrameAndTicketCommit(t *testing.T) {
	socket, server := net.Pipe()
	device, remote := net.Pipe()
	defer remote.Close()
	sink, receiver := net.Pipe()
	defer receiver.Close()
	_, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := &Flow{id: "0123456789abcdef0123456789abcdef", conn: socket, reader: bufio.NewReader(socket), quota: &quotaGuard{inbound: device, target: sink, expires: time.Now().Add(time.Minute), cancel: cancel, closed: make(chan struct{})}}
	observed := make(chan map[string]any, 4)
	go scriptedQuota{reply: func(m map[string]any) map[string]any {
		observed <- m
		return map[string]any{"ok": true, "granted": 3, "expiresAt": time.Now().Add(time.Minute).UnixMilli()}
	}}.accept(t, server)
	frame := []byte{2, 0, 5, 0, 2, 11, 12, 13, 14, 15, 0, 0}
	out := make(chan []byte, 1)
	go func() { b, _ := io.ReadAll(receiver); out <- b }()
	n, err := f.Write(sink, frame, 5, 10, "vision_padded")
	if !errors.Is(err, errCutoff) || n != 10 {
		t.Fatal(n, err)
	}
	// A valid final frame carries the original command + three payload bytes + two padding bytes.
	if b := <-out; string(b) != string([]byte{2, 0, 3, 0, 2, 11, 12, 13, 0, 0}) {
		t.Fatal(b)
	}
	reserve := <-observed
	commit := <-observed
	if reserve["op"] != "reserve" || reserve["bytes"] != float64(5) || reserve["ticket"] != float64(1) || reserve["direction"] != "down" ||
		commit["op"] != "commit" || commit["bytes"] != float64(3) || commit["ticket"] != reserve["ticket"] || commit["complete"] != true {
		t.Fatal(reserve, commit)
	}
	if err := f.Finish(); err != nil {
		t.Fatal(err)
	}
	last := <-observed
	if last["downloadedBytes"] != float64(3) || last["complete"] != true {
		t.Fatal(last)
	}
}

func TestIdleExpiryClosesBothSockets(t *testing.T) {
	// Use a short pathname even on hosts with deeply nested TMPDIR.
	dir, err := os.MkdirTemp("", "q")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "q")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	expiry := time.Now().Add(150 * time.Millisecond)
	go func() {
		c, err := listener.Accept()
		if err == nil {
			scriptedQuota{reply: func(msg map[string]any) map[string]any {
				if msg["op"] != "check" {
					t.Error(msg)
				}
				return map[string]any{"ok": true, "expiresAt": expiry.UnixMilli()}
			}}.accept(t, c)
		}
	}()
	client, peer := net.Pipe()
	target, origin := net.Pipe()
	defer peer.Close()
	defer origin.Close()
	q, err := startGuard(context.Background(), path, "flow", client, expiry.UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	f := Flow{quota: q}
	if err := f.BindTarget(target); err != nil {
		t.Fatal(err)
	}
	for _, conn := range []net.Conn{peer, origin} {
		conn.SetReadDeadline(expiry.Add(200 * time.Millisecond))
		if _, err := conn.Read(make([]byte, 1)); err != io.EOF {
			t.Fatal(err)
		}
	}
	if time.Now().Before(time.UnixMilli(expiry.UnixMilli())) {
		t.Fatal("cut off before expiry")
	}
}

func TestShortenedExpiryHasIndependentDeadline(t *testing.T) {
	client, peer := net.Pipe()
	target, origin := net.Pipe()
	defer peer.Close()
	defer origin.Close()
	ctx, cancel := context.WithCancel(context.Background())
	q := &quotaGuard{inbound: client, target: target, expires: time.Now().Add(time.Minute), closed: make(chan struct{}), expiryChanged: make(chan struct{}, 1), cancel: cancel}
	defer q.stop()
	go q.expire(ctx)
	expiry := time.Now().Add(30 * time.Millisecond)
	q.shorten(expiry.UnixMilli())
	for _, conn := range []net.Conn{peer, origin} {
		conn.SetReadDeadline(expiry.Add(100 * time.Millisecond))
		if _, err := conn.Read(make([]byte, 1)); err != io.EOF {
			t.Fatal("shortened expiry did not close socket", err)
		}
	}
	if time.Now().Before(time.UnixMilli(expiry.UnixMilli())) {
		t.Fatal("socket closed before shortened expiry")
	}
}

func TestQuotaInvalidSpanNeverWrites(t *testing.T) {
	for _, test := range []struct {
		start, end int
		path       string
	}{
		{-1, 1, "target_tcp"},
		{0, 5, "target_tcp"},
		{2, 1, "vision_plain"},
		{1, 3, "vision_raw"},
		{0, 3, "vision_padded"},
	} {
		client, peer := net.Pipe()
		_, cancel := context.WithCancel(context.Background())
		q := &quotaGuard{inbound: client, expires: time.Now().Add(time.Minute), closed: make(chan struct{}), cancel: cancel}
		f := &Flow{quota: q}
		w := writeFunc(func([]byte) (int, error) {
			t.Fatal("invalid target span reached writer")
			return 0, nil
		})
		if n, err := f.Write(w, make([]byte, 4), test.start, test.end, test.path); n != 0 || !errors.Is(err, errCutoff) {
			t.Fatal(n, err)
		}
		peer.Close()
	}
}

func TestQuotaOpenReplyAndLostAcknowledgement(t *testing.T) {
	for _, lost := range []bool{false, true} {
		t.Run(map[bool]string{false: "expiry reply", true: "lost ACK"}[lost], func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			f := &Flow{id: "0123456789abcdef0123456789abcdef", conn: client, reader: bufio.NewReader(client), recoveryDir: t.TempDir()}
			expiry := time.Now().Add(time.Minute).UnixMilli()
			seen := make(chan map[string]any, 1)
			go func() {
				defer server.Close()
				var frame map[string]any
				if err := json.NewDecoder(server).Decode(&frame); err != nil {
					return
				}
				seen <- frame
				if !lost {
					json.NewEncoder(server).Encode(map[string]any{"ok": true, "expiresAt": expiry})
				}
			}()
			ack, err := f.openWithReply(map[string]any{"op": "open", "client": "bound-client", "mode": "enforce"})
			if (err != nil) != lost || !lost && ack.ExpiresAt != expiry {
				t.Fatal(ack, err)
			}
			frame := <-seen
			if frame["op"] != "open" || frame["mode"] != "enforce" {
				t.Fatal(frame)
			}
			frames, err := pending(filepath.Join(f.recoveryDir, f.id+".json"))
			if err != nil || !lost && len(frames) != 0 || lost && (len(frames) != 1 || len(frames[0]) != 3 || frames[0]["op"] != "abort") {
				t.Fatal(frames, err)
			}
		})
	}
}

func TestExpiredQuotaOpenFinishesZeroByteFlow(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "quota-open-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	socket := filepath.Join(root, "m.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv(socketEnv, socket)
	t.Setenv("AEGIS_XRAY_QUOTA", "enforce")
	seen := make(chan []map[string]any, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		scanner := bufio.NewScanner(conn)
		var frames []map[string]any
		for scanner.Scan() {
			var frame map[string]any
			if json.Unmarshal(scanner.Bytes(), &frame) != nil {
				return
			}
			frames = append(frames, frame)
			json.NewEncoder(conn).Encode(map[string]any{"ok": true, "expiresAt": time.Now().Add(-time.Second).UnixMilli()})
			if frame["op"] == "finish" {
				break
			}
		}
		seen <- frames
	}()
	inbound, peer := net.Pipe()
	defer peer.Close()
	defer inbound.Close()
	if _, f, err := Open(context.Background(), "bound-client", inbound); f != nil || !errors.Is(err, errCutoff) {
		t.Fatal(f, err)
	}
	select {
	case frames := <-seen:
		if len(frames) != 2 || frames[0]["op"] != "open" || frames[0]["mode"] != "enforce" ||
			frames[1]["op"] != "finish" || frames[1]["uploadedBytes"] != float64(0) || frames[1]["downloadedBytes"] != float64(0) || frames[1]["complete"] != true {
			t.Fatal(frames)
		}
	case <-time.After(time.Second):
		t.Fatal("guard failure did not finish zero-byte flow")
	}
}

func TestLostReservationAckRetainsNoWriteCancellation(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "quota-reserve-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	socket := filepath.Join(root, "m.sock")
	dir, err := recoveryDirectory(socket)
	if err != nil {
		t.Fatal(err)
	}
	var f *Flow
	sawReserve := make(chan struct{}, 1)
	f = quotaFixture(t, func(frame map[string]any) map[string]any {
		frames, readErr := pending(filepath.Join(dir, f.id+".json"))
		if readErr != nil || len(frames) != 1 || frames[0]["op"] != "cancel" ||
			frames[0]["ticket"] != json.Number("1") || frames[0]["bytes"] != json.Number("3") {
			t.Error("reserve sent before durable cancellation", frames, readErr)
		}
		sawReserve <- struct{}{}
		f.conn.Close() // The collector may have committed, but the ACK cannot arrive.
		return nil
	})
	f.recoveryDir = dir
	calls := 0
	writer := quotaWriter{write: func(data []byte) (int, error) {
		calls++
		return len(data), nil
	}}
	if n, err := f.Write(writer, []byte{1, 2, 3}, 0, 3, "target_tcp"); n != 0 || err == nil || calls != 0 {
		t.Fatal(n, err, calls)
	}
	<-sawReserve
	if err := f.Finish(); err == nil {
		t.Fatal("unacknowledged cancellation reported success")
	}
	frames, err := pending(filepath.Join(dir, f.id+".json"))
	if err != nil || len(frames) != 2 || frames[0]["op"] != "cancel" ||
		frames[0]["direction"] != "up" || frames[0]["path"] != "target_tcp" ||
		frames[1]["op"] != "finish" || frames[1]["uploadedBytes"] != json.Number("0") {
		t.Fatal(frames, err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	seen := make(chan []observed, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var messages []observed
		scanner := bufio.NewScanner(conn)
		for scanner.Scan() {
			var message observed
			if json.Unmarshal(scanner.Bytes(), &message) != nil {
				return
			}
			messages = append(messages, message)
			io.WriteString(conn, "{\"ok\":true}\n")
			if message["op"] == "finish" {
				break
			}
		}
		seen <- messages
	}()
	replay(socket, dir)
	select {
	case messages := <-seen:
		if len(messages) != 2 || messages[0]["op"] != "cancel" || messages[1]["op"] != "finish" {
			t.Fatal(messages)
		}
	case <-time.After(time.Second):
		t.Fatal("no-write cancellation was not replayed")
	}
	if frames, err = pending(filepath.Join(dir, f.id+".json")); err != nil || len(frames) != 0 {
		t.Fatal(frames, err)
	}
}

func TestReservationClearFailureRequeuesCancellation(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "quota-clear-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	socket := filepath.Join(root, "m.sock")
	dir, err := recoveryDirectory(socket)
	if err != nil {
		t.Fatal(err)
	}
	f := quotaFixture(t, func(frame map[string]any) map[string]any {
		return map[string]any{"ok": true, "granted": 3,
			"expiresAt": time.Now().Add(time.Minute).UnixMilli()}
	})
	f.recoveryDir = dir
	failedSync := errors.New("injected parent directory sync failure")
	clear := func(path string, frames []map[string]any) error {
		if len(frames) != 0 {
			t.Fatal("unexpected retained frames", frames)
		}
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		return failedSync
	}
	_, err = f.reserveWithRecovery(map[string]any{"op": "reserve", "ticket": int64(1),
		"direction": "up", "path": "target_tcp", "bytes": 3}, clear)
	if !errors.Is(err, failedSync) {
		t.Fatal("clear failure not returned", err)
	}
	frames, err := pending(filepath.Join(dir, f.id+".json"))
	if err != nil || len(frames) != 1 || frames[0]["op"] != "cancel" ||
		frames[0]["bytes"] != json.Number("3") || frames[0]["ticket"] != json.Number("1") {
		t.Fatal("lost no-write cancellation after unlink", frames, err)
	}
}
