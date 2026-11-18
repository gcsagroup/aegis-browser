// Confirmed writer records stay durable until the collector acknowledges them.
package aegismeter

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

func init() {
	if Enabled() {
		socket := os.Getenv(socketEnv)
		if dir, err := recoveryDirectory(socket); err == nil {
			startReplay(socket, dir)
		}
	}
}

var busyRecords sync.Map // outbox record path -> channel closed when its owner releases it
var replayOnce sync.Once
var flowRecordName = regexp.MustCompile(`^[0-9a-f]{32}\.json$`)

// Both the live writer and replay own the record from its read through its
// acknowledgement and removal. Other flows use different records.
func lockRecord(path string) func() {
	done := make(chan struct{})
	for {
		owner, busy := busyRecords.LoadOrStore(path, done)
		if !busy {
			return func() {
				busyRecords.Delete(path)
				close(done)
			}
		}
		<-owner.(chan struct{})
	}
}

func recoveryDirectory(socket string) (string, error) {
	parent, err := os.Stat(filepath.Dir(socket))
	if err != nil || !parent.IsDir() || parent.Mode().Perm() != 0700 {
		return "", errors.New("meter socket requires private directory")
	}
	dir := socket + ".outbox"
	if err := os.Mkdir(dir, 0700); err != nil && !os.IsExist(err) {
		return "", err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		return "", errors.New("meter outbox requires private directory")
	}
	return dir, nil
}

func pending(path string) ([]map[string]any, error) {
	name := filepath.Base(path)
	if !flowRecordName.MatchString(name) {
		return nil, errors.New("invalid meter record name")
	}
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer root.Close()
	info, err := root.Lstat(name)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("meter record must be a regular file")
	}
	data, err := root.ReadFile(name)
	if err != nil {
		return nil, err
	}
	var frames []map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&frames); err != nil {
		return nil, err
	}
	var extra json.RawMessage
	if len(frames) == 0 || decoder.Decode(&extra) != io.EOF {
		return nil, errors.New("invalid meter record contents")
	}
	id := strings.TrimSuffix(name, ".json")
	for _, frame := range frames {
		if frame["flow"] != id {
			return nil, errors.New("meter record flow differs from filename")
		}
	}
	return frames, nil
}

func save(path string, frames []map[string]any) error {
	name := filepath.Base(path)
	if !flowRecordName.MatchString(name) {
		return errors.New("invalid meter record name")
	}
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer root.Close()
	if len(frames) == 0 {
		if err := root.Remove(name); err != nil && !os.IsNotExist(err) {
			return err
		}
	} else {
		data, err := json.Marshal(frames)
		if err != nil {
			return err
		}
		file, err := os.CreateTemp(root.Name(), ".pending-")
		if err != nil {
			return err
		}
		temp := filepath.Base(file.Name())
		defer root.Remove(temp)
		if _, err = file.Write(data); err == nil {
			err = file.Sync()
		}
		if closeErr := file.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return err
		}
		if err := root.Rename(temp, name); err != nil {
			return err
		}
	}
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (f *Flow) retainLocked(frame map[string]any) error {
	frame["v"], frame["flow"] = 1, f.id
	path := filepath.Join(f.recoveryDir, f.id+".json")
	frames, err := pending(path)
	if err != nil {
		return err
	}
	return save(path, append(frames, frame))
}

// A terminal record cannot overtake an unacknowledged sample from the same flow.
func (f *Flow) reliableSend(frame map[string]any) error {
	if f.recoveryDir == "" { // In-memory unit-test collectors.
		return f.send(frame)
	}
	path := filepath.Join(f.recoveryDir, f.id+".json")
	unlock := lockRecord(path)
	defer unlock()
	previous, err := pending(path)
	if err != nil {
		return err
	}
	frame["v"], frame["flow"] = 1, f.id
	if err := save(path, append(previous, frame)); err != nil {
		return err
	}
	if f.broken || len(previous) != 0 {
		return errors.New("meter recovery pending")
	}
	if err := f.send(frame); err != nil {
		return err
	}
	return save(path, nil)
}

func startReplay(socket, dir string) {
	replayOnce.Do(func() {
		go func() {
			for {
				replay(socket, dir)
				time.Sleep(time.Second)
			}
		}()
	})
}

func replay(socket, dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !flowRecordName.MatchString(entry.Name()) {
			continue
		}
		if err := replayRecord(socket, filepath.Join(dir, entry.Name())); err != nil {
			// The collector is offline. Retry the directory on the next pass.
			return
		}
	}
}

func replayRecord(socket, path string) error {
	unlock := lockRecord(path)
	defer unlock()
	frames, err := pending(path)
	if err != nil || len(frames) == 0 {
		return nil
	}
	conn, err := net.DialTimeout("unix", socket, timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	f := &Flow{id: strings.TrimSuffix(filepath.Base(path), ".json"), conn: conn, reader: bufio.NewReaderSize(conn, 4096)}
	for i, frame := range frames {
		if err := f.send(frame); err != nil {
			break
		}
		if err := save(path, frames[i+1:]); err != nil {
			break
		}
	}
	return nil
}

// An opening has no target bytes until this returns. Its recovery record only
// closes a possible zero-byte row and is harmless if open never reached SQLite.
func (f *Flow) open(frame map[string]any) error {
	_, err := f.openWithReply(frame)
	return err
}

// Quota admission also consumes the expiry bound in the successful reply.
func (f *Flow) openWithReply(frame map[string]any) (response, error) {
	path := filepath.Join(f.recoveryDir, f.id+".json")
	unlock := lockRecord(path)
	defer unlock()
	if err := f.retainLocked(map[string]any{"op": "abort"}); err != nil {
		return response{}, err
	}
	ack, err := f.exchange(frame)
	if err != nil {
		return ack, err
	}
	if !ack.OK {
		return ack, errors.New("meter open rejected")
	}
	return ack, save(path, nil)
}

// reserveWithRecovery persists a promise of no target write before asking for
// bytes. Lost ACKs replay that promise before Finish. Replay holds the same
// lock, so it cannot cancel a reservation while its caller accepts the grant.
func (f *Flow) reserveWithRecovery(frame map[string]any, clear func(string, []map[string]any) error) (response, error) {
	if f.recoveryDir == "" {
		return f.exchange(frame)
	}
	path := filepath.Join(f.recoveryDir, f.id+".json")
	unlock := lockRecord(path)
	defer unlock()
	previous, err := pending(path)
	if err != nil {
		return response{}, err
	}
	if len(previous) != 0 {
		return response{}, errors.New("meter recovery pending")
	}
	cancel := map[string]any{"op": "cancel", "ticket": frame["ticket"],
		"direction": frame["direction"], "path": frame["path"], "bytes": frame["bytes"]}
	if err := f.retainLocked(cancel); err != nil {
		return response{}, err
	}
	ack, err := f.exchange(frame)
	if err != nil {
		return ack, err
	}
	requested, ok := frame["bytes"].(int)
	if ack.OK && (!ok || ack.Granted <= 0 || ack.Granted > requested) {
		return ack, errors.New("invalid quota grant")
	}
	// A valid grant or definite rejection resolves the cancellation before the
	// caller is permitted to write.
	if err := clear(path, nil); err != nil {
		// Removal can succeed before the following directory sync fails.
		// Requeue the no-write promise before the caller abandons its grant.
		return ack, errors.Join(err, f.retainLocked(cancel))
	}
	return ack, nil
}
