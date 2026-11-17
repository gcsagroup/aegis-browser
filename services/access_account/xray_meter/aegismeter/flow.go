// Package aegismeter records confirmed target-stream progress in the paid node profile.
package aegismeter

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"os"
	"sync"
	"time"
)

const socketEnv = "AEGIS_XRAY_METER_SOCKET"
const timeout = 3 * time.Second

func Enabled() bool {
	_, ok := os.LookupEnv(socketEnv)
	return ok
}

type key struct{}

func From(ctx context.Context) *Flow {
	f, _ := ctx.Value(key{}).(*Flow)
	return f
}

type Flow struct {
	// Finish waits for both directions' in-flight writes, and fences new ones.
	lifetime    sync.RWMutex
	finished    bool
	mu          sync.Mutex
	broken      bool
	uncertain   bool
	up, down    int64
	paths       map[string]int64
	id          string
	recoveryDir string
	conn        net.Conn
	reader      *bufio.Reader
}

func Open(ctx context.Context, client string) (context.Context, *Flow, error) {
	socket := os.Getenv(socketEnv)
	dir, err := recoveryDirectory(socket)
	if err != nil {
		return ctx, nil, err
	}
	startReplay(socket, dir)
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return ctx, nil, err
	}
	conn, err := net.DialTimeout("unix", socket, timeout)
	if err != nil {
		return ctx, nil, err
	}
	f := &Flow{id: hex.EncodeToString(id[:]), conn: conn, reader: bufio.NewReaderSize(conn, 4096), paths: make(map[string]int64), recoveryDir: dir}
	if err := f.open(map[string]any{"op": "open", "client": client}); err != nil {
		conn.Close()
		return ctx, nil, err
	}
	return context.WithValue(ctx, key{}, f), f, nil
}

func (f *Flow) send(msg map[string]any) error {
	msg["v"], msg["flow"] = 1, f.id
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	if len(data)+1 > 4096 {
		return errors.New("meter request exceeds limit")
	}
	if err = f.conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return err
	}
	if _, err = f.conn.Write(append(data, '\n')); err != nil {
		return err
	}
	line, err := f.reader.ReadSlice('\n')
	if err != nil {
		return err
	}
	var ack struct {
		OK bool `json:"ok"`
	}
	if json.Unmarshal(line, &ack) != nil || !ack.OK {
		return errors.New("meter rejected sample")
	}
	return nil
}

func (f *Flow) Finish() error {
	f.lifetime.Lock()
	defer f.lifetime.Unlock()
	f.finished = true
	defer f.conn.Close()
	return f.reliableSend(map[string]any{"op": "finish", "uploadedBytes": f.up, "downloadedBytes": f.down, "complete": !f.uncertain})
}

// Write uses a concrete writer from the pinned transport. [start,end) is the
// original target data in a Vision frame, or the whole buffer for raw TCP.
// REALITY Write returns plaintext in completed application records. A failed
// final encrypted record cannot certify additional target bytes.
func (f *Flow) Write(w io.Writer, p []byte, start, end int, path string) (int, error) {
	f.lifetime.RLock()
	defer f.lifetime.RUnlock()
	f.mu.Lock()
	stopped := f.finished || f.broken || f.uncertain
	f.mu.Unlock()
	if stopped {
		return 0, errors.New("meter flow stopped")
	}
	n, err := w.Write(p)
	f.mu.Lock()
	defer f.mu.Unlock()
	if n < 0 || n > len(p) {
		f.uncertain = true
		return 0, errors.New("invalid writer progress")
	}
	if n != len(p) && err == nil {
		err = io.ErrShortWrite
	}
	if err != nil && path != "target_tcp" && path != "vision_raw" && n < end {
		f.uncertain = true
	}
	delta := int64(max(0, min(n, end)-start))
	if delta > 0 {
		total, direction := &f.down, "down"
		if path == "target_tcp" {
			total, direction = &f.up, "up"
		}
		if delta > math.MaxInt64-*total {
			f.uncertain = true
			return n, errors.New("meter overflow")
		}
		*total += delta
		f.paths[path] += delta
		if reportErr := f.reliableSend(map[string]any{"op": "sample", "direction": direction, "bytes": *total, "path": path, "pathBytes": f.paths[path], "measuredAt": time.Now().UnixMilli()}); reportErr != nil {
			f.broken = true
			return n, reportErr
		}
	}
	return n, err
}

type TargetWriter struct {
	Flow   *Flow
	Socket io.Writer
}

func (w TargetWriter) Write(p []byte) (int, error) {
	return w.Flow.Write(w.Socket, p, 0, len(p), "target_tcp")
}
