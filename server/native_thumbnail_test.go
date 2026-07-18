package main

import (
	"context"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestGenerateNativeImageThumbnail(t *testing.T) {
	dir := t.TempDir()
	sourcePath := filepath.Join(dir, "source.png")
	targetPath := filepath.Join(dir, "cache", "thumb.jpg")

	source := image.NewNRGBA(image.Rect(0, 0, 120, 60))
	for y := 0; y < 60; y++ {
		for x := 0; x < 120; x++ {
			source.SetNRGBA(x, y, color.NRGBA{R: uint8(x * 2), G: uint8(y * 4), B: 80, A: 255})
		}
	}
	file, err := os.Create(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(file, source); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	if err := generateNativeImageThumbnail(context.Background(), sourcePath, targetPath, 48); err != nil {
		t.Fatal(err)
	}
	thumbnail, err := os.Open(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	config, err := jpeg.DecodeConfig(thumbnail)
	_ = thumbnail.Close()
	if err != nil {
		t.Fatal(err)
	}
	if config.Width != 48 || config.Height != 24 {
		t.Fatalf("thumbnail dimensions = %dx%d, want 48x24", config.Width, config.Height)
	}
}

func TestPrepareNativeImageThumbnailQueueRecoversFailedJobs(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES('photos','Photos','C:/Photos',1,1);
INSERT INTO media_items(
  id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
  size_bytes,modified_at,captured_at,missing,last_seen_scan
) VALUES(
  '0123456789abcdef0123456789abcdef','photos','a.jpg','','a.jpg','image','image/jpeg',
  100,'2026-07-19T00:00:00Z','2026-07-19T00:00:00Z',0,'scan'
);
INSERT INTO thumbnail_jobs(
  media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at
) VALUES(
  '0123456789abcdef0123456789abcdef',480,'2026-07-19T00:00:00Z','failed',3,
  'ffmpeg unavailable','2026-07-19T00:00:00Z','2026-07-19T00:00:00Z'
);`); err != nil {
		t.Fatal(err)
	}

	app := newApp(Config{ThumbnailWorkers: 2}, db, nil)
	recovered, err := app.prepareNativeImageThumbnailQueue(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if recovered != 1 {
		t.Fatalf("recovered jobs = %d, want 1", recovered)
	}

	var status, lastError string
	var attempts int
	if err := db.QueryRowContext(ctx, `
SELECT status,attempts,last_error FROM thumbnail_jobs
WHERE media_id='0123456789abcdef0123456789abcdef' AND width=480`).
		Scan(&status, &attempts, &lastError); err != nil {
		t.Fatal(err)
	}
	if status != "native_pending" || attempts != 0 || lastError != "" {
		t.Fatalf("unexpected recovered job: status=%q attempts=%d error=%q", status, attempts, lastError)
	}

	var migrationCount int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM schema_migrations WHERE version=?`,
		nativeThumbnailMigration,
	).Scan(&migrationCount); err != nil {
		t.Fatal(err)
	}
	if migrationCount != 1 {
		t.Fatalf("native thumbnail migration count = %d, want 1", migrationCount)
	}
}

func TestEnqueuePriorityThumbnailRepairsDoneJobWithoutCache(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	modified := time.Date(2026, 7, 19, 0, 0, 0, 0, time.UTC)
	item := Media{
		ID:           "fedcba9876543210fedcba9876543210",
		LibraryID:    "photos",
		RelativePath: "a.jpg",
		FileName:     "a.jpg",
		Type:         "image",
		MIMEType:     "image/jpeg",
		ModifiedAt:   modified,
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES('photos','Photos','C:/Photos',1,1);
INSERT INTO media_items(
  id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
  size_bytes,modified_at,captured_at,missing,last_seen_scan
) VALUES(?,?,?,?,?,'image','image/jpeg',100,?,?,0,'scan');
INSERT INTO thumbnail_jobs(
  media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at
) VALUES(?,480,?,'done',1,'',?,?);`,
		item.ID, item.LibraryID, item.RelativePath, "", item.FileName,
		modified.Format(time.RFC3339Nano), modified.Format(time.RFC3339Nano),
		item.ID, modified.Format(time.RFC3339Nano), modified.Format(time.RFC3339Nano), modified.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}

	app := newApp(Config{ThumbnailWorkers: 2}, db, nil)
	if _, err := app.prepareNativeImageThumbnailQueue(ctx); err != nil {
		t.Fatal(err)
	}
	if err := app.enqueuePriorityThumbnail(ctx, item, 480); err != nil {
		t.Fatal(err)
	}

	var status, updatedAt string
	var attempts int
	if err := db.QueryRowContext(ctx, `
SELECT status,attempts,updated_at FROM thumbnail_jobs WHERE media_id=? AND width=480`, item.ID).
		Scan(&status, &attempts, &updatedAt); err != nil {
		t.Fatal(err)
	}
	if status != "native_pending" || attempts != 0 {
		t.Fatalf("priority job: status=%q attempts=%d", status, attempts)
	}
	if len(updatedAt) < 5 || updatedAt[:5] != "0000:" {
		t.Fatalf("priority timestamp = %q", updatedAt)
	}
}
