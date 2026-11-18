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

var recoveryMu sync.Mutex
var replayOnce sync.Once
var flowRecordName = regexp.MustCompile(`^[0-9a-f]{32}\.json$`)

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
	recoveryMu.Lock()
	defer recoveryMu.Unlock()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !flowRecordName.MatchString(entry.Name()) {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		frames, err := pending(path)
		if err != nil || len(frames) == 0 {
			continue
		}
		conn, err := net.DialTimeout("unix", socket, timeout)
		if err != nil {
			return
		}
		f := &Flow{id: strings.TrimSuffix(entry.Name(), ".json"), conn: conn, reader: bufio.NewReaderSize(conn, 4096)}
		for len(frames) != 0 {
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
