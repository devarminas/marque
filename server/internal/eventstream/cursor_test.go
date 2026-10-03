package eventstream

import "testing"

func TestCloseTickRetainsOfferedIntentCursor(t *testing.T) {
	ss, epoch, sender := collection(t, DefaultConfig())
	if err := ss.AppendAt(1, nil); err != nil {
		t.Fatal(err)
	}
	first, err := ss.CloseTick(7, epoch, 1, 0, sender)
	if err != nil || first.NextIntent != 1 {
		t.Fatalf("first=%+v err=%v", first, err)
	}
	if accepted, err := ss.AcceptIntent(7, epoch, 1, []byte{1}); err != nil || !accepted {
		t.Fatalf("accept=%v err=%v", accepted, err)
	}
	retry, err := ss.CloseTick(7, epoch, 1, 0, sender)
	if err != nil || retry != first {
		t.Fatalf("retry changed offered boundary first=%+v retry=%+v err=%v", first, retry, err)
	}
	if err := ss.AppendAt(2, nil); err != nil {
		t.Fatal(err)
	}
	second, err := ss.CloseTick(7, epoch, 2, 0, sender)
	if err != nil || second.NextIntent != 2 {
		t.Fatalf("second=%+v err=%v", second, err)
	}
}
