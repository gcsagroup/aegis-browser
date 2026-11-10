package embeddedcore

import (
	"testing"
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
