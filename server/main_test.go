package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStableID(t *testing.T) {
	first := stableID("photos", "2026/IMG_0001.JPG")
	second := stableID("photos", "2026/img_0001.jpg")
	if first != second {
		t.Fatalf("stableID should be case-insensitive for Windows paths: %q != %q", first, second)
	}
	if len(first) != 32 {
		t.Fatalf("unexpected id length: got %d", len(first))
	}
}

func TestWithin(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Media")
	cases := []struct {
		name   string
		target string
		want   bool
	}{
		{name: "same directory", target: root, want: true},
		{name: "direct child", target: filepath.Join(root, "photo.jpg"), want: true},
		{name: "nested child", target: filepath.Join(root, "2026", "photo.jpg"), want: true},
		{name: "parent escape", target: filepath.Join(root, "..", "secret.txt"), want: false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if got := within(root, test.target); got != test.want {
				t.Fatalf("within(%q, %q) = %v, want %v", root, test.target, got, test.want)
			}
		})
	}
}

func TestLoadConfigRejectsShortToken(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	content := `{
  "api_token": "short",
  "libraries": [{"id":"main","name":"Main","path":"./media","enabled":true}]
}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadConfig(path); err == nil {
		t.Fatal("loadConfig should reject a token shorter than 16 characters")
	}
}
