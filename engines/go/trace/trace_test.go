package trace

import (
	"encoding/json"
	"testing"
)

func encode(t *testing.T, o Obj) string {
	t.Helper()
	b, err := json.Marshal(o)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestShapes pins the key set and values of every record shape.
func TestShapes(t *testing.T) {
	for _, c := range []struct {
		got  Obj
		want string
	}{
		{Record("gate", "a", "b", "distance", 1.5, 2.0, true), `{"a":"a","b":"b","limit":2,"pass":true,"stage":"gate","test":"distance","value":1.5}`},
		{Skipped("confirm", "a", "b", "course"), `{"a":"a","b":"b","limit":null,"pass":true,"skipped":true,"stage":"confirm","test":"course","value":null}`},
		{Time("s/1", 200, 1, 2), `{"a":"s/1","b":null,"limit":null,"pass":true,"stage":"filter","test":"time","value":200,"var_east":1,"var_north":2}`},
		{Restart("s/1", 3, 9.21, true), `{"a":"s/1","b":null,"limit":9.21,"pass":true,"stage":"filter","test":"restart","value":3}`},
		{Model("s/1", "quiet", "mode", 0.5), `{"a":"s/1","b":"quiet","limit":null,"pass":true,"stage":"filter","test":"mode","value":0.5}`},
		{Assign("s/1", "alone", "cost", nil, false), `{"a":"s/1","b":"alone","limit":null,"pass":false,"stage":"assign","test":"cost","value":null}`},
		{History(0, nil, "commit", 1, true), `{"a":0,"b":null,"limit":null,"pass":true,"stage":"history","test":"commit","value":1}`},
		{Rule("r", "s/1", "circle", true, 5.0, 10.0, false, true), `{"entity":"s/1","limit":10,"negated":true,"pass":false,"rule":"r","stage":"rule","test":"circle","unknown":true,"value":5}`},
		{Rule("r", "s/1", "has", false, true, nil, true, false), `{"entity":"s/1","limit":null,"negated":false,"pass":true,"rule":"r","stage":"rule","test":"has","value":true}`},
		{Forget("s/1", 5, 4, true), `{"entity":"s/1","limit":4,"pass":true,"stage":"forget","test":"age","value":5}`},
		{Kinematics(nil, "best", []any{KinematicsCandidate("s/1", 2, 3, nil)}, "s/1"), `{"candidates":[{"member":"s/1","rank":null,"time_ms":3,"var":2}],"group":null,"method":"best","stage":"kinematics","winner":"s/1"}`},
		{Intersect("g", "s/2", 0.5), `{"group":"g","member":"s/2","stage":"intersect","value":0.5}`},
		{Attribute("g", "type", "max", []any{AttributeCandidate("s/1", 3, 4, int64(0))}, nil, nil), `{"candidates":[{"member":"s/1","rank":0,"time_ms":4,"value":3}],"group":"g","key":"type","rule":"max","stage":"attribute","value":null,"winner":null}`},
		{Sample("s/1", "nis", 1.5, 1, 2), `{"entity":"s/1","inputs":[1,2],"sample":"nis","stage":"sample","value":1.5}`},
		{QualityRule("r", "s", "age", nil, 3, false, 0, true), `{"active":true,"count":0,"limit":3,"measure":"age","pass":false,"rule":"r","stage":"rule","subject":"s","value":null}`},
	} {
		if got := encode(t, c.got); got != c.want {
			t.Errorf("got  %s\nwant %s", got, c.want)
		}
	}
}

func TestTag(t *testing.T) {
	recs := Tag([]Obj{Record("assign", "a", "b", "cost", 1, nil, true)}, "h", 2, "r", 0)
	if recs[0]["h"] != 2 || recs[0]["r"] != 0 {
		t.Errorf("Tag = %v", recs)
	}
	if len(Tag(nil, "h", 1)) != 0 {
		t.Error("Tag of none")
	}
}
