package storeauth

import "testing"

func TestRetoolsAMDRejectsIncompleteOrOversizeProof(t *testing.T) {
	for _, pair := range [][2][]byte{{nil, []byte{1}}, {[]byte{1}, nil}, {make([]byte, 6145), []byte{1}}, {[]byte{1}, make([]byte, 6145)}} {
		if _, err := encodeStoreAMD(pair[0], pair[1]); err == nil {
			t.Fatal("invalid proof accepted")
		}
	}
	headers, err := encodeStoreAMD([]byte{1, 2, 3}, []byte{4, 5, 6})
	if err != nil || headers["X-Apple-AMD-M"] != "AQID" || headers["X-Apple-AMD"] != "BAUG" {
		t.Fatalf("wrong proof encoding: %v", err)
	}
}
