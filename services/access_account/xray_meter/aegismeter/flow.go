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
	return ok || quotaRequested()
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
	quota       *quotaGuard
	tickets     [2]int64
}

func Open(ctx context.Context, client string, inbound net.Conn) (context.Context, *Flow, error) {
	socket := os.Getenv(socketEnv)
	dir, err := recoveryDirectory(socket)
	if err != nil {
		return ctx, nil, err
	}
	startReplay(socket, dir)
	var id [16]byte
	if quotaRequested() && os.Getenv("AEGIS_XRAY_QUOTA") != "enforce" {
		return ctx, nil, errors.New("unknown quota mode")
	}
	if _, err := rand.Read(id[:]); err != nil {
		return ctx, nil, err
	}
	conn, err := net.DialTimeout("unix", socket, timeout)
	if err != nil {
		return ctx, nil, err
	}
	f := &Flow{id: hex.EncodeToString(id[:]), conn: conn, reader: bufio.NewReaderSize(conn, 4096), paths: make(map[string]int64), recoveryDir: dir}
	msg := map[string]any{"op": "open", "client": client}
	if quotaRequested() {
		msg["mode"] = "enforce"
	}
	ack, err := f.openWithReply(msg)
	if err != nil {
		conn.Close()
		return ctx, nil, err
	}
	if quotaRequested() {
		f.quota, err = startGuard(ctx, os.Getenv(socketEnv), f.id, inbound, ack.ExpiresAt)
		if err != nil {
			return ctx, nil, errors.Join(err, f.Finish())
		}
	}
	return context.WithValue(ctx, key{}, f), f, nil
}

func (f *Flow) send(msg map[string]any) error {
	ack, err := f.exchange(msg)
	if err != nil {
		return err
	}
	if !ack.OK {
		return errors.New("meter rejected request")
	}
	return nil
}

type response struct {
	OK        bool   `json:"ok"`
	Granted   int    `json:"granted"`
	ExpiresAt int64  `json:"expiresAt"`
	Reason    string `json:"reason"`
}

func (f *Flow) exchange(msg map[string]any) (response, error) {
	return exchange(f.conn, f.reader, f.id, msg, time.Now().Add(timeout))
}
func exchange(c net.Conn, reader *bufio.Reader, id string, msg map[string]any, deadline time.Time) (ack response, err error) {
	msg["v"], msg["flow"] = 1, id
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	if len(data)+1 > 4096 {
		return ack, errors.New("meter request exceeds limit")
	}
	if err = c.SetDeadline(deadline); err != nil {
		return
	}
	if _, err = c.Write(append(data, '\n')); err != nil {
		return
	}
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return
	}
	err = json.Unmarshal(line, &ack)
	return
}

func (f *Flow) Finish() error {
	if f.quota != nil {
		f.quota.stop()
	}
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
	if f.quota != nil {
		return f.quotaWrite(w, p, start, end, path)
	}
	n, err := w.Write(p)
	measuredAt := time.Now().UnixMilli()
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
		frame := map[string]any{"op": "sample", "direction": direction, "bytes": *total, "path": path, "pathBytes": f.paths[path], "measuredAt": measuredAt}
		if reportErr := f.reliableSend(frame); reportErr != nil {
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
