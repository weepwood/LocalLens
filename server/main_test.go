package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
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

func TestCursorRoundTrip(t *testing.T) {
	item := Media{ID: "media-123", ModifiedAt: time.Date(2026, 7, 18, 10, 0, 0, 123, time.UTC)}
	value := encodeCursor(item)
	cursor, err := decodeCursor(value)
	if err != nil {
		t.Fatal(err)
	}
	if cursor.ID != item.ID {
		t.Fatalf("cursor id = %q, want %q", cursor.ID, item.ID)
	}
	if cursor.ModifiedAt != item.ModifiedAt.Format(time.RFC3339Nano) {
		t.Fatalf("cursor time = %q", cursor.ModifiedAt)
	}
	if _, err := decodeCursor("not-a-cursor"); err == nil {
		t.Fatal("invalid cursor should fail")
	}
}

func TestOpenDBAppliesMigrations(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var migrationCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&migrationCount); err != nil {
		t.Fatal(err)
	}
	if migrationCount != 2 {
		t.Fatalf("migration count = %d, want 2", migrationCount)
	}

	rows, err := db.Query(`PRAGMA table_info(media_items)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	hasFavorite := false
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull, primaryKey int
		var defaultValue any
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			t.Fatal(err)
		}
		if name == "favorite" {
			hasFavorite = true
		}
	}
	if !hasFavorite {
		t.Fatal("favorite column was not created")
	}
}

func TestQueryMediaCursorLibraryAndFavorite(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES
 ('a','A','C:/Media/A',1,1),
 ('b','B','C:/Media/B',1,1)`); err != nil {
		t.Fatal(err)
	}
	insert := `
INSERT INTO media_items(
 id,library_id,relative_path,file_name,media_type,mime_type,size_bytes,
 modified_at,missing,last_seen_scan,favorite
) VALUES(?,?,?,?,?,?,?,?,0,'scan',?)`
	items := []struct {
		id, library, relative, name, modified string
		favorite bool
	}{
		{"a-new", "a", "new.jpg", "new.jpg", "2026-07-18T12:00:00Z", true},
		{"a-old", "a", "old.jpg", "old.jpg", "2026-07-17T12:00:00Z", false},
		{"b-item", "b", "other.jpg", "other.jpg", "2026-07-16T12:00:00Z", true},
	}
	for _, item := range items {
		if _, err := db.ExecContext(
			ctx,
			insert,
			item.id,
			item.library,
			item.relative,
			item.name,
			"image",
			"image/jpeg",
			100,
			item.modified,
			item.favorite,
		); err != nil {
			t.Fatal(err)
		}
	}

	app := &App{db: db}
	first, err := app.queryMedia(ctx, "", "", "a", false, 1, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if first.Total != 2 || len(first.Items) != 1 || !first.HasMore || first.NextCursor == "" {
		t.Fatalf("unexpected first page: %+v", first)
	}
	if first.Items[0].ID != "a-new" {
		t.Fatalf("first item = %q", first.Items[0].ID)
	}

	second, err := app.queryMedia(ctx, "", "", "a", false, 1, 0, first.NextCursor)
	if err != nil {
		t.Fatal(err)
	}
	if second.Total != 2 || len(second.Items) != 1 || second.HasMore {
		t.Fatalf("unexpected second page: %+v", second)
	}
	if second.Items[0].ID != "a-old" {
		t.Fatalf("second item = %q", second.Items[0].ID)
	}

	favorites, err := app.queryMedia(ctx, "", "", "", true, 10, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if favorites.Total != 2 || len(favorites.Items) != 2 {
		t.Fatalf("favorite page = %+v", favorites)
	}

	if err := app.setFavorite(ctx, "a-old", true); err != nil {
		t.Fatal(err)
	}
	updated, err := app.findMediaByID(ctx, "a-old")
	if err != nil {
		t.Fatal(err)
	}
	if !updated.Favorite {
		t.Fatal("favorite update was not persisted")
	}
}
