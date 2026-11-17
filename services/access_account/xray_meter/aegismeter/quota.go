package aegismeter

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"net"
	"os"
	"sync"
	"time"
)

const maxGrant = 16384
const checkInterval = 250 * time.Millisecond

var errCutoff = errors.New("quota flow closed")

func quotaRequested() bool { _, ok := os.LookupEnv("AEGIS_XRAY_QUOTA"); return ok }

// Each admitted flow has its own cutoff. Closing raw sockets also interrupts an
// idle reader or a blocked Reality writer without waiting for its TLS mutex.
type quotaGuard struct {
	mu              sync.Mutex
	writers         [2]sync.Mutex
	inbound, target net.Conn
	expires         time.Time
	stopped         bool
	closed          chan struct{}
	expiryChanged   chan struct{}
	cancel          context.CancelFunc
}

func startGuard(parent context.Context, path, id string, inbound net.Conn, expiry int64) (*quotaGuard, error) {
	ctx, cancel := context.WithCancel(parent)
	q := &quotaGuard{inbound: inbound, expires: time.UnixMilli(expiry), closed: make(chan struct{}), expiryChanged: make(chan struct{}, 1), cancel: cancel}
	if !time.Now().Before(q.expires) {
		q.stop()
		return nil, errCutoff
	}
	go q.expire(ctx)
	go q.watch(ctx, path, id)
	return q, nil
}

func (q *quotaGuard) stop() {
	q.mu.Lock()
	if q.stopped {
		q.mu.Unlock()
		return
	}
	q.stopped = true
	close(q.closed)
	in, out := q.inbound, q.target
	q.mu.Unlock()
	q.cancel()
	in.Close()
	if out != nil {
		out.Close()
	}
}

// BindTarget also fences a dial which finished after the cutoff.
func (f *Flow) BindTarget(c net.Conn) error {
	q := f.quota
	if q == nil {
		return nil
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.stopped || !time.Now().Before(q.expires) {
		return errCutoff
	}
	q.target = c
	return nil
}

func (q *quotaGuard) deadline() time.Time {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.expires
}

// Never extend an existing flow's original grant. Renewal opens a new flow.
func (q *quotaGuard) shorten(ms int64) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if e := time.UnixMilli(ms); e.Before(q.expires) {
		q.expires = e
		select {
		case q.expiryChanged <- struct{}{}:
		default:
		}
	}
}

// The deadline is independent of a blocked check exchange. In particular a
// shorter deadline returned by reserve must also close idle sockets on time.
func (q *quotaGuard) expire(ctx context.Context) {
	defer q.stop()
	for {
		wait := time.Until(q.deadline())
		if wait <= 0 {
			return
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-q.expiryChanged:
			timer.Stop()
		case <-timer.C:
			// Re-read the deadline in case a concurrent shorten won the race.
		}
	}
}

func (q *quotaGuard) watch(ctx context.Context, path, id string) {
	defer q.stop()
	// A single polling connection per flow, independent of reserve and commit.
	deadline := minTime(q.deadline(), time.Now().Add(checkInterval))
	d := net.Dialer{Deadline: deadline}
	c, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return
	}
	defer c.Close()
	r := bufio.NewReaderSize(c, 4096)
	for {
		if ctx.Err() != nil {
			return
		}
		expiry := q.deadline()
		if !time.Now().Before(expiry) {
			return
		}
		ack, err := exchange(c, r, id, map[string]any{"op": "check"}, minTime(expiry, time.Now().Add(checkInterval)))
		if err != nil || !ack.OK {
			return
		}
		q.shorten(ack.ExpiresAt)
		wait := time.Until(minTime(q.deadline(), time.Now().Add(checkInterval)))
		if wait <= 0 {
			return
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func (f *Flow) reserve(direction, path string, size int) (ticket int64, granted int, err error) {
	i := 0
	if direction == "down" {
		i = 1
	}
	f.mu.Lock()
	if f.tickets[i] == math.MaxInt64 {
		f.mu.Unlock()
		return 0, 0, errCutoff
	}
	f.tickets[i]++
	ticket = f.tickets[i]
	f.mu.Unlock()
	for {
		select {
		case <-f.quota.closed:
			return 0, 0, errCutoff
		default:
		}
		f.mu.Lock()
		if f.broken || f.uncertain {
			f.mu.Unlock()
			return 0, 0, errCutoff
		}
		ack, e := f.reserveWithRecovery(map[string]any{"op": "reserve", "ticket": ticket, "direction": direction, "path": path, "bytes": size}, save)
		f.mu.Unlock()
		if e != nil {
			return 0, 0, e
		}
		if ack.OK && ack.Granted > 0 && ack.Granted <= size {
			f.quota.shorten(ack.ExpiresAt)
			return ticket, ack.Granted, nil
		}
		if ack.OK {
			return 0, 0, errors.New("invalid quota grant")
		}
		if ack.Reason != "pending" {
			return 0, 0, errCutoff
		}
		select {
		case <-f.quota.closed:
			return 0, 0, errCutoff
		case <-time.After(25 * time.Millisecond):
		}
	}
}

// compactFrame preserves a whole Vision frame, including its command, UUID
// and padding. Only the granted prefix of the target payload survives.
func compactFrame(p []byte, start, end, grant int, path string) []byte {
	if path != "vision_padded" {
		return p[:grant]
	}
	padding := p[end:]
	binary.BigEndian.PutUint16(p[start-4:start-2], uint16(grant))
	copy(p[start+grant:], padding)
	return p[:start+grant+len(padding)]
}

func (f *Flow) quotaWrite(w io.Writer, p []byte, start, end int, path string) (int, error) {
	q := f.quota
	direction := "down"
	writer := 1
	if path == "target_tcp" {
		direction = "up"
		writer = 0
	}
	// Each direction has one outstanding ticket. Preserve its reservation,
	// confirmed write, and commit order even if a caller overlaps writes.
	q.writers[writer].Lock()
	defer q.writers[writer].Unlock()
	select {
	case <-q.closed:
		return 0, errCutoff
	default:
	}
	requested := end - start
	if start < 0 || end < start || end > len(p) || requested > maxGrant ||
		(path == "vision_padded" && start < 5) ||
		(path != "vision_padded" && (start != 0 || end != len(p))) {
		q.stop()
		return 0, errCutoff
	}
	if !time.Now().Before(q.deadline()) {
		q.stop()
		return 0, errCutoff
	}
	// A frame with zero target bytes needs no reservation. Its writer is still
	// interrupted by the connection's expiry/check watcher.
	if requested == 0 {
		return w.Write(p)
	}
	ticket, grant, err := f.reserve(direction, path, requested)
	if err != nil {
		if !errors.Is(err, errCutoff) {
			f.mu.Lock()
			f.broken = true
			// The collector may have issued this grant before the ACK was lost.
			f.uncertain = true
			f.mu.Unlock()
		}
		q.stop()
		return 0, err
	}
	if grant < requested {
		p = compactFrame(p, start, end, grant, path)
		end = start + grant
	}
	deadline := minTime(q.deadline(), time.Now().Add(time.Second))
	dw, ok := w.(interface{ SetWriteDeadline(time.Time) error })
	n := 0
	attempted := false
	if !ok || !time.Now().Before(deadline) {
		err = errCutoff
	} else if err = dw.SetWriteDeadline(deadline); err == nil {
		attempted = true
		n, err = w.Write(p)
		if err == nil && n != len(p) {
			err = io.ErrShortWrite
		}
	}
	measuredAt := time.Now().UnixMilli()
	valid := n >= 0 && n <= len(p)
	if !valid {
		n = 0
		err = errors.New("invalid writer progress")
	}
	actual := max(0, min(n, end)-start)
	known := valid && (err == nil || path == "target_tcp" || path == "vision_raw" || n >= end)
	// A deadline failure before calling Write has an exact progress of zero.
	if !attempted {
		known = true
	}
	f.mu.Lock()
	// The writer already confirmed this prefix. Count it locally even when the
	// collector's ACK is lost so the queued terminal watermark matches replay.
	if !known {
		f.uncertain = true
	}
	if direction == "up" {
		f.up += int64(actual)
	} else {
		f.down += int64(actual)
	}
	frame := map[string]any{"op": "commit", "direction": direction, "ticket": ticket, "bytes": actual, "complete": known, "measuredAt": measuredAt}
	ackErr := f.reliableSend(frame)
	if ackErr != nil {
		f.broken = true
	}
	f.mu.Unlock()
	if ackErr != nil {
		q.stop()
		return n, ackErr
	}
	if err != nil {
		q.stop()
		return n, err
	}
	if grant < requested {
		// The other direction may already own a final ticket. Keep the
		// current copy task alive until the collector fences the flow.
		timer := time.NewTimer(time.Second)
		select {
		case <-q.closed:
			timer.Stop()
		case <-timer.C:
			q.stop()
		}
		return n, errCutoff
	}
	return n, nil
}
