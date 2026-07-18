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

func TestLoadConfigDefaultsV02(t *testing.T) {
	dir := t.TempDir()
	media := filepath.Join(dir, "media")
	if err := os.MkdirAll(media, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "config.json")
	content := `{
  "api_token": "1234567890abcdef",
  "ffmpeg_path": "./bin/ffmpeg.exe",
  "libraries": [{"id":"main","name":"Main","path":"./media","enabled":true}]
}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.WatchFiles || cfg.ThumbnailWorkers != 2 || cfg.MetadataWorkers != 2 {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	if filepath.Base(cfg.FFprobePath) != "ffprobe.exe" {
		t.Fatalf("ffprobe path = %q", cfg.FFprobePath)
	}
}

func TestTimelineCursorRoundTrip(t *testing.T) {
	item := Media{
		ID: "media-123",
		ModifiedAt: time.Date(2026, 7, 18, 10, 0, 0, 123, time.UTC),
		CapturedAt: time.Date(2020, 5, 3, 8, 0, 0, 456, time.UTC),
	}
	value := encodeCursor(item, "timeline")
	cursor, err := decodeCursor(value)
	if err != nil {
		t.Fatal(err)
	}
	if cursor.ID != item.ID || cursor.SortAt != item.CapturedAt.Format(time.RFC3339Nano) {
		t.Fatalf("unexpected cursor: %+v", cursor)
	}
	if _, err := decodeCursor("not-a-cursor"); err == nil {
		t.Fatal("invalid cursor should fail")
	}
}

func TestOpenDBAppliesV02Migrations(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var migrationCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&migrationCount); err != nil {
		t.Fatal(err)
	}
	if migrationCount != 8 {
		t.Fatalf("migration count = %d, want 8", migrationCount)
	}

	for _, table := range []string{
		"folders", "thumbnail_jobs", "metadata_jobs", "devices",
		"playback_progress", "albums", "album_items", "tags", "media_tags",
	} {
		var count int
		if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 1 {
			t.Fatalf("table %s was not created", table)
		}
	}
}

func TestQueryTimelineFolderFavoriteAndRating(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES ('a','A','C:/Media/A',1,1),('b','B','C:/Media/B',1,1)`); err != nil {
		t.Fatal(err)
	}
	insert := `
INSERT INTO media_items(
 id,library_id,relative_path,folder_path,file_name,media_type,mime_type,size_bytes,
 modified_at,captured_at,captured_at_source,missing,last_seen_scan,favorite,rating
) VALUES(?,?,?,?,?,'image','image/jpeg',100,?,?, 'exif',0,'scan',?,?)`
	items := []struct {
		id, library, relative, folder, modified, captured string
		favorite bool
		rating int
	}{
		{"a-new", "a", "Travel/new.jpg", "Travel", "2026-07-18T12:00:00Z", "2020-01-03T12:00:00Z", true, 5},
		{"a-old", "a", "Travel/old.jpg", "Travel", "2026-07-17T12:00:00Z", "2020-01-02T12:00:00Z", false, 3},
		{"a-root", "a", "root.jpg", "", "2026-07-16T12:00:00Z", "2020-01-01T12:00:00Z", false, 0},
		{"b-item", "b", "other.jpg", "", "2026-07-19T12:00:00Z", "2019-01-01T12:00:00Z", true, 4},
	}
	for _, item := range items {
		if _, err := db.ExecContext(ctx, insert, item.id, item.library, item.relative, item.folder, filepath.Base(item.relative), item.modified, item.captured, item.favorite, item.rating); err != nil {
			t.Fatal(err)
		}
	}

	app := &App{db: db}
	first, err := app.queryMedia(ctx, MediaQuery{LibraryID: "a", FolderPath: "Travel", FolderSet: true, Limit: 1, Sort: "timeline"})
	if err != nil {
		t.Fatal(err)
	}
	if first.Total != 2 || len(first.Items) != 1 || !first.HasMore || first.Items[0].ID != "a-new" {
		t.Fatalf("unexpected first page: %+v", first)
	}
	second, err := app.queryMedia(ctx, MediaQuery{LibraryID: "a", FolderPath: "Travel", FolderSet: true, Limit: 1, Sort: "timeline", Cursor: first.NextCursor})
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Items) != 1 || second.Items[0].ID != "a-old" || second.HasMore {
		t.Fatalf("unexpected second page: %+v", second)
	}
	favorites, err := app.queryMedia(ctx, MediaQuery{FavoriteOnly: true, MinRating: 4, Limit: 10, Sort: "timeline"})
	if err != nil {
		t.Fatal(err)
	}
	if favorites.Total != 2 {
		t.Fatalf("favorite page = %+v", favorites)
	}
}

func TestPlaybackCollectionsAndDeviceToken(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if _, err := db.Exec(`INSERT INTO libraries(id,name,root_path,recursive,enabled) VALUES('a','A','C:/A',1,1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
INSERT INTO media_items(id,library_id,relative_path,folder_path,file_name,media_type,mime_type,size_bytes,modified_at,captured_at,missing,last_seen_scan)
VALUES('m','a','m.mp4','','m.mp4','video','video/mp4',10,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',0,'scan')`); err != nil {
		t.Fatal(err)
	}
	app := newApp(Config{APIToken: "1234567890abcdef", PairingTTLMinutes: 5}, db, nil)
	if err := app.savePlaybackProgress(ctx, PlaybackProgress{DeviceID: "d", MediaID: "m", PositionMS: 5000, DurationMS: 10000}); err != nil {
		t.Fatal(err)
	}
	progress, err := app.getPlaybackProgress(ctx, "d", "m")
	if err != nil || progress.PositionMS != 5000 {
		t.Fatalf("playback progress: %+v, %v", progress, err)
	}
	album, err := app.createAlbum(ctx, "Travel", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := app.setAlbumItem(ctx, album.ID, "m", true); err != nil {
		t.Fatal(err)
	}
	tag, err := app.createTag(ctx, "Favorite", "#ff0000")
	if err != nil {
		t.Fatal(err)
	}
	if err := app.setMediaTag(ctx, "m", tag.ID, true); err != nil {
		t.Fatal(err)
	}
	albums, tags, err := app.mediaCollections(ctx, "m")
	if err != nil || len(albums) != 1 || len(tags) != 1 {
		t.Fatalf("collections: %v %v %v", albums, tags, err)
	}
	if hashToken("token") == "token" || hashToken("token") != hashToken("token") {
		t.Fatal("token hashing is not stable")
	}
}
