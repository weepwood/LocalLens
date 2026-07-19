package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSupportsDirectPlayback(t *testing.T) {
	item := Media{
		MIMEType: "video/mp4",
		Codec:    "h264",
		Width:    1920,
		Height:   1080,
	}
	compatible := PlaybackRequest{
		VideoCodecs: []string{"h264", "hevc"},
		Containers:  []string{"mp4"},
		MaxWidth:    3840,
		MaxHeight:   2160,
	}
	if !supportsDirectPlayback(item, compatible) {
		t.Fatal("compatible H.264 MP4 should use direct playback")
	}
	incompatibleCodec := compatible
	incompatibleCodec.VideoCodecs = []string{"vp9"}
	if supportsDirectPlayback(item, incompatibleCodec) {
		t.Fatal("unsupported codec should require transcoding")
	}
	limitedDisplay := compatible
	limitedDisplay.MaxHeight = 720
	if supportsDirectPlayback(item, limitedDisplay) {
		t.Fatal("video above the client height limit should require transcoding")
	}
}

func TestPlaybackProfileSelection(t *testing.T) {
	cases := []struct {
		source, preferred, maximum, want int
	}{
		{2160, 1080, 2160, 1080},
		{1080, 720, 1080, 720},
		{720, 1080, 720, 720},
		{480, 480, 480, 480},
	}
	for _, test := range cases {
		if got := selectTranscodeHeight(test.source, test.preferred, test.maximum); got != test.want {
			t.Fatalf("selectTranscodeHeight(%d,%d,%d)=%d, want %d", test.source, test.preferred, test.maximum, got, test.want)
		}
	}
	if height, err := profileHeight("h264-720p"); err != nil || height != 720 {
		t.Fatalf("profileHeight returned %d, %v", height, err)
	}
	if _, err := profileHeight("unsafe-profile"); err == nil {
		t.Fatal("invalid profile must fail")
	}
}

func TestTranscodeQueuePersistsAndClaimsAtomically(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES('main','Main','C:/Media',1,1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO media_items(
  id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
  size_bytes,modified_at,captured_at,missing,last_seen_scan,codec,width,height
) VALUES('video','main','video.mp4','','video.mp4','video','video/mp4',100,
  '2026-07-19T00:00:00Z','2026-07-19T00:00:00Z',0,'scan','hevc',3840,2160)`); err != nil {
		t.Fatal(err)
	}
	app := newApp(Config{TranscodeWorkers: 1}, db, nil)
	item, err := app.findMediaByID(ctx, "video")
	if err != nil {
		t.Fatal(err)
	}
	if err := app.enqueueTranscode(ctx, item, "h264-720p"); err != nil {
		t.Fatal(err)
	}
	job, ok, err := app.claimTranscodeJob(ctx)
	if err != nil || !ok {
		t.Fatalf("claim transcode job: ok=%v err=%v", ok, err)
	}
	if job.MediaID != "video" || job.Profile != "h264-720p" || job.Attempts != 1 {
		t.Fatalf("unexpected job: %+v", job)
	}
	if _, ok, err := app.claimTranscodeJob(ctx); err != nil || ok {
		t.Fatalf("second claim should be empty: ok=%v err=%v", ok, err)
	}
}

func TestDiscoverExternalSubtitles(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{
		"movie.mp4", "movie.srt", "movie.zh-CN.ass", "movie.en.vtt",
		"another.srt", "movie.txt",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("test"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	item := Media{ID: "video", RootPath: dir, RelativePath: "movie.mp4"}
	tracks := discoverSubtitles(item)
	if len(tracks) != 3 {
		t.Fatalf("subtitle tracks = %+v", tracks)
	}
	if tracks[0].Name != "movie.en.vtt" || tracks[0].Language != "en" {
		t.Fatalf("unexpected sorted subtitle track: %+v", tracks[0])
	}
}

func TestTranscodeRunningJobsRecoverAfterRestart(t *testing.T) {
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES('main','Main','C:/Media',1,1);
INSERT INTO media_items(
  id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
  size_bytes,modified_at,captured_at,missing,last_seen_scan
) VALUES('video','main','video.mp4','','video.mp4','video','video/mp4',100,
  '2026-07-19T00:00:00Z','2026-07-19T00:00:00Z',0,'scan');
INSERT INTO transcode_jobs(
  media_id,profile,source_modified_at,status,attempts,progress,last_error,created_at,updated_at
) VALUES('video','h264-480p','2026-07-19T00:00:00Z','running',1,0.4,'',?,?)`,
		time.Now().UTC().Format(time.RFC3339Nano), time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	app := newApp(Config{TranscodeWorkers: 1}, db, nil)
	if err := app.startTranscodeWorkers(); err != nil {
		t.Fatal(err)
	}
	app.serviceCancel()
	app.workerWG.Wait()
	var status string
	var progress float64
	if err := db.QueryRowContext(ctx, `SELECT status,progress FROM transcode_jobs WHERE media_id='video'`).Scan(&status, &progress); err != nil {
		t.Fatal(err)
	}
	if status != "pending" || progress != 0 {
		t.Fatalf("recovered state = %s %.2f", status, progress)
	}
}
