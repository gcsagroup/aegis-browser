// Confirmed writer records stay durable until the collector acknowledges them.
package aegismeter

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
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

var recoveryMu sync.Mutex
var replayOnce sync.Once

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
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	var frames []map[string]any
	if err == nil {
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		err = decoder.Decode(&frames)
	}
	return frames, err
}

func save(path string, frames []map[string]any) error {
	if len(frames) == 0 {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		dir, err := os.Open(filepath.Dir(path))
		if err != nil {
			return err
		}
		defer dir.Close()
		return dir.Sync()
	}
	data, err := json.Marshal(frames)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".pending-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(file.Name(), path)
	}
	if err == nil {
		var dir *os.File
		dir, err = os.Open(filepath.Dir(path))
		if err == nil {
			err = dir.Sync()
			dir.Close()
		}
	}
	return err
}

func (f *Flow) retainLocked(frame map[string]any) error {
	frame["v"], frame["flow"] = 1, f.id
	frames, err := pending(filepath.Join(f.recoveryDir, f.id+".json"))
	if err != nil {
		return err
	}
	return save(filepath.Join(f.recoveryDir, f.id+".json"), append(frames, frame))
}

func (f *Flow) retain(frame map[string]any) error {
	if f.recoveryDir == "" {
		return errors.New("meter outbox unavailable")
	}
	recoveryMu.Lock()
	defer recoveryMu.Unlock()
	return f.retainLocked(frame)
}

// reliableSend holds the same lock as background replay. A terminal record can
// never overtake a failed prefix from the same flow.
func (f *Flow) reliableSend(frame map[string]any) error {
	if f.recoveryDir == "" { // In-memory unit-test collectors.
		return f.send(frame)
	}
	recoveryMu.Lock()
	defer recoveryMu.Unlock()
	path := filepath.Join(f.recoveryDir, f.id+".json")
	previous, err := pending(path)
	if err != nil {
		return err
	}
	if err := f.retainLocked(frame); err != nil {
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
	recoveryMu.Lock()
	defer recoveryMu.Unlock()
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return
	}
	for _, path := range paths {
		frames, err := pending(path)
		if err != nil || len(frames) == 0 {
			continue
		}
		conn, err := net.DialTimeout("unix", socket, timeout)
		if err != nil {
			return
		}
		f := &Flow{conn: conn, reader: bufio.NewReaderSize(conn, 4096)}
		for len(frames) != 0 {
			id, ok := frames[0]["flow"].(string)
			if !ok {
				err = fmt.Errorf("invalid persisted flow")
				break
			}
			f.id = id
			if err = f.send(frames[0]); err != nil {
				break
			}
			frames = frames[1:]
			if err = save(path, frames); err != nil {
				break
			}
		}
		conn.Close()
	}
}

// An opening has no target bytes until this returns. Its recovery record only
// closes a possible zero-byte row and is harmless if open never reached SQLite.
func (f *Flow) open(frame map[string]any) error {
	recoveryMu.Lock()
	defer recoveryMu.Unlock()
	if err := f.retainLocked(map[string]any{"op": "abort"}); err != nil {
		return err
	}
	if err := f.send(frame); err != nil {
		return err
	}
	return save(filepath.Join(f.recoveryDir, f.id+".json"), nil)
}
