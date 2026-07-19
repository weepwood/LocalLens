package main

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const transcodeIdleInterval = 2 * time.Second

type PlaybackRequest struct {
	Platform        string   `json:"platform"`
	VideoCodecs     []string `json:"videoCodecs"`
	Containers      []string `json:"containers"`
	SupportsHLS     bool     `json:"supportsHls"`
	MaxWidth        int      `json:"maxWidth"`
	MaxHeight       int      `json:"maxHeight"`
	PreferredHeight int      `json:"preferredHeight"`
	ForceTranscode  bool     `json:"forceTranscode"`
}

type SubtitleManifest struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Language string `json:"language"`
	Format   string `json:"format"`
	URL      string `json:"url"`
}

type PlaybackManifest struct {
	Mode       string             `json:"mode"`
	Status     string             `json:"status"`
	URL        string             `json:"url,omitempty"`
	MIMEType   string             `json:"mimeType,omitempty"`
	Profile    string             `json:"profile,omitempty"`
	Codec      string             `json:"codec,omitempty"`
	Width      int                `json:"width"`
	Height     int                `json:"height"`
	Progress   float64            `json:"progress,omitempty"`
	RetryAfter int                `json:"retryAfter,omitempty"`
	Error      string             `json:"error,omitempty"`
	Subtitles  []SubtitleManifest `json:"subtitles"`
}

type TranscodeJob struct {
	MediaID          string
	Profile          string
	SourceModifiedAt string
	Attempts         int
}

type transcodeState struct {
	Status   string
	Progress float64
	Error    string
}

func (a *App) routesV05() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("POST /api/v1/media/{id}/playback-manifest", a.auth(http.HandlerFunc(a.playbackManifest)))
	mux.Handle("GET /api/v1/media/{id}/subtitle/{name}", a.auth(http.HandlerFunc(a.subtitleFile)))
	mux.Handle("GET /api/v1/transcodes/{mediaId}/{profile}/{file}", a.auth(http.HandlerFunc(a.transcodeFile)))
	mux.Handle("GET /api/v1/transcodes/diagnostics", a.auth(http.HandlerFunc(a.transcodeDiagnostics)))
	mux.Handle("POST /api/v1/transcodes/retry", a.auth(http.HandlerFunc(a.retryFailedTranscodes)))
	mux.Handle("/", a.routesV022())
	return a.cors(mux)
}

func (a *App) startTranscodeWorkers() error {
	if _, err := a.db.Exec(`UPDATE transcode_jobs SET status='pending',progress=0 WHERE status='running'`); err != nil {
		return err
	}
	for i := 0; i < a.cfg.TranscodeWorkers; i++ {
		a.workerWG.Add(1)
		go a.transcodeWorker(i + 1)
	}
	a.wakeTranscodeWorkers()
	return nil
}

func (a *App) wakeTranscodeWorkers() {
	select {
	case a.transcodeWake <- struct{}{}:
	default:
	}
}

func (a *App) transcodeWorker(number int) {
	defer a.workerWG.Done()
	ticker := time.NewTicker(transcodeIdleInterval)
	defer ticker.Stop()
	for {
		if a.isScanRunning() {
			if !waitForWorker(a.serviceCtx, a.transcodeWake, workerScanPause) {
				return
			}
			continue
		}
		job, ok, err := a.claimTranscodeJob(a.serviceCtx)
		if err != nil {
			if !isSQLiteBusy(err) && a.logger != nil {
				a.logger.Warn("claim transcode job", "worker", number, "error", err)
			}
			if !waitForWorker(a.serviceCtx, a.transcodeWake, workerScanPause) {
				return
			}
			continue
		}
		if ok {
			a.processTranscodeJob(a.serviceCtx, job)
			continue
		}
		select {
		case <-a.serviceCtx.Done():
			return
		case <-a.transcodeWake:
		case <-ticker.C:
		}
	}
}

func (a *App) claimTranscodeJob(ctx context.Context) (TranscodeJob, bool, error) {
	var job TranscodeJob
	err := retrySQLiteBusy(ctx, sqliteBusyRetryLimit, func() error {
		job = TranscodeJob{}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		return a.db.QueryRowContext(ctx, `
UPDATE transcode_jobs
SET status='running',attempts=attempts+1,progress=0,updated_at=?
WHERE rowid=(
  SELECT rowid FROM transcode_jobs
  WHERE status='pending'
  ORDER BY updated_at,media_id,profile
  LIMIT 1
)
AND status='pending'
RETURNING media_id,profile,source_modified_at,attempts`, now).
			Scan(&job.MediaID, &job.Profile, &job.SourceModifiedAt, &job.Attempts)
	})
	if errors.Is(err, sql.ErrNoRows) {
		return TranscodeJob{}, false, nil
	}
	if err != nil {
		return TranscodeJob{}, false, err
	}
	return job, true, nil
}

func (a *App) processTranscodeJob(ctx context.Context, job TranscodeJob) {
	item, err := a.findMediaByID(ctx, job.MediaID)
	if err == nil && item.Missing {
		err = errors.New("media is missing")
	}
	if err == nil && item.Type != "video" {
		err = errors.New("media is not a video")
	}
	if err == nil && item.ModifiedAt.UTC().Format(time.RFC3339Nano) != job.SourceModifiedAt {
		err = errors.New("media changed while transcode was queued")
	}
	if err == nil {
		err = a.generateHLS(ctx, item, job.Profile)
	}

	status := "done"
	message := ""
	progress := 1.0
	if err != nil {
		message = truncateError(err)
		progress = 0
		if job.Attempts < 2 && !strings.Contains(strings.ToLower(message), "not configured") {
			status = "pending"
			time.Sleep(time.Duration(job.Attempts) * time.Second)
		} else {
			status = "failed"
			if a.logger != nil {
				a.logger.Warn("transcode job failed", "media", job.MediaID, "profile", job.Profile, "error", err)
			}
		}
	}
	_, _ = a.db.ExecContext(ctx, `
UPDATE transcode_jobs SET status=?,progress=?,last_error=?,updated_at=?
WHERE media_id=? AND profile=?`, status, progress, message,
		time.Now().UTC().Format(time.RFC3339Nano), job.MediaID, job.Profile)
	if status == "pending" {
		a.wakeTranscodeWorkers()
	}
}

func (a *App) playbackManifest(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	if item.Type != "video" {
		http.Error(w, "media is not a video", http.StatusBadRequest)
		return
	}
	request := PlaybackRequest{SupportsHLS: true}
	if r.ContentLength != 0 {
		if err := decodeJSON(r, &request); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	subtitles := discoverSubtitles(item)
	if !request.ForceTranscode && supportsDirectPlayback(item, request) {
		writeJSON(w, http.StatusOK, PlaybackManifest{
			Mode: "direct", Status: "ready",
			URL: "/api/v1/media/" + url.PathEscape(item.ID) + "/stream",
			MIMEType: item.MIMEType, Codec: item.Codec,
			Width: item.Width, Height: item.Height, Subtitles: subtitles,
		})
		return
	}
	if !request.SupportsHLS {
		writeJSON(w, http.StatusUnprocessableEntity, PlaybackManifest{
			Mode: "transcode", Status: "failed", Error: "客户端不支持 HLS，且原始视频无法直接播放",
			Codec: item.Codec, Width: item.Width, Height: item.Height, Subtitles: subtitles,
		})
		return
	}
	if err := a.ensureFFmpegAvailable(); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, PlaybackManifest{
			Mode: "transcode", Status: "failed", Error: err.Error(),
			Codec: item.Codec, Width: item.Width, Height: item.Height, Subtitles: subtitles,
		})
		return
	}

	height := selectTranscodeHeight(item.Height, request.PreferredHeight, request.MaxHeight)
	profile := fmt.Sprintf("h264-%dp", height)
	state, err := a.transcodeJobState(r.Context(), item.ID, profile)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		serverError(w, err)
		return
	}
	playlist := filepath.Join(a.transcodeProfileDir(item.ID, profile), "index.m3u8")
	if state.Status == "done" {
		if _, statErr := os.Stat(playlist); statErr == nil {
			writeJSON(w, http.StatusOK, PlaybackManifest{
				Mode: "transcode", Status: "ready", Profile: profile,
				URL: fmt.Sprintf("/api/v1/transcodes/%s/%s/index.m3u8", url.PathEscape(item.ID), profile),
				MIMEType: "application/vnd.apple.mpegurl", Codec: "h264",
				Width: item.Width, Height: height, Progress: 1, Subtitles: subtitles,
			})
			return
		}
		state.Status = "pending"
	}
	if state.Status == "failed" {
		writeJSON(w, http.StatusUnprocessableEntity, PlaybackManifest{
			Mode: "transcode", Status: "failed", Profile: profile,
			Error: state.Error, Codec: "h264", Width: item.Width, Height: height,
			Subtitles: subtitles,
		})
		return
	}
	if err := a.enqueueTranscode(r.Context(), item, profile); err != nil {
		serverError(w, err)
		return
	}
	state, _ = a.transcodeJobState(r.Context(), item.ID, profile)
	w.Header().Set("Retry-After", "2")
	writeJSON(w, http.StatusAccepted, PlaybackManifest{
		Mode: "transcode", Status: "preparing", Profile: profile,
		Codec: "h264", Width: item.Width, Height: height,
		Progress: state.Progress, RetryAfter: 2, Subtitles: subtitles,
	})
}

func supportsDirectPlayback(item Media, request PlaybackRequest) bool {
	codec := normalizeCodec(item.Codec)
	if codec != "" && len(request.VideoCodecs) > 0 && !containsFold(request.VideoCodecs, codec) {
		return false
	}
	container := containerName(item.MIMEType)
	if container != "" && len(request.Containers) > 0 && !containsFold(request.Containers, container) {
		return false
	}
	if request.MaxWidth > 0 && item.Width > request.MaxWidth {
		return false
	}
	if request.MaxHeight > 0 && item.Height > request.MaxHeight {
		return false
	}
	return true
}

func normalizeCodec(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	switch value {
	case "avc", "avc1", "h.264":
		return "h264"
	case "h265", "h.265", "hev1", "hvc1":
		return "hevc"
	case "vp09":
		return "vp9"
	case "av01":
		return "av1"
	default:
		return value
	}
}

func containerName(mime string) string {
	switch strings.ToLower(strings.TrimSpace(mime)) {
	case "video/mp4", "video/x-m4v", "video/quicktime":
		return "mp4"
	case "video/x-matroska":
		return "mkv"
	case "video/webm":
		return "webm"
	case "video/x-msvideo":
		return "avi"
	default:
		return ""
	}
}

func containsFold(values []string, target string) bool {
	for _, value := range values {
		if normalizeCodec(value) == target || strings.EqualFold(strings.TrimSpace(value), target) {
			return true
		}
	}
	return false
}

func selectTranscodeHeight(sourceHeight, preferredHeight, maxHeight int) int {
	target := preferredHeight
	if target <= 0 {
		target = 1080
	}
	if maxHeight > 0 && target > maxHeight {
		target = maxHeight
	}
	if sourceHeight > 0 && target > sourceHeight {
		target = sourceHeight
	}
	switch {
	case target <= 480:
		return 480
	case target <= 720:
		return 720
	default:
		return 1080
	}
}

func (a *App) enqueueTranscode(ctx context.Context, item Media, profile string) error {
	if !validProfile(profile) {
		return errors.New("invalid transcode profile")
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	sourceModified := item.ModifiedAt.UTC().Format(time.RFC3339Nano)
	_, err := a.db.ExecContext(ctx, `
INSERT INTO transcode_jobs(media_id,profile,source_modified_at,status,attempts,progress,last_error,created_at,updated_at)
VALUES(?,?,?,'pending',0,0,'',?,?)
ON CONFLICT(media_id,profile) DO UPDATE SET
  source_modified_at=excluded.source_modified_at,
  status=CASE
    WHEN transcode_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending'
    WHEN transcode_jobs.status='failed' AND transcode_jobs.attempts<2 THEN 'pending'
    WHEN transcode_jobs.status='done' AND transcode_jobs.source_modified_at=excluded.source_modified_at THEN transcode_jobs.status
    ELSE transcode_jobs.status END,
  attempts=CASE WHEN transcode_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE transcode_jobs.attempts END,
  progress=CASE WHEN transcode_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE transcode_jobs.progress END,
  last_error=CASE WHEN transcode_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE transcode_jobs.last_error END,
  updated_at=excluded.updated_at`, item.ID, profile, sourceModified, now, now)
	if err == nil {
		a.wakeTranscodeWorkers()
	}
	return err
}

func (a *App) transcodeJobState(ctx context.Context, mediaID, profile string) (transcodeState, error) {
	var state transcodeState
	err := a.db.QueryRowContext(ctx, `
SELECT status,progress,last_error FROM transcode_jobs WHERE media_id=? AND profile=?`, mediaID, profile).
		Scan(&state.Status, &state.Progress, &state.Error)
	return state, err
}

func validProfile(profile string) bool {
	return profile == "h264-480p" || profile == "h264-720p" || profile == "h264-1080p"
}

func profileHeight(profile string) (int, error) {
	if !validProfile(profile) {
		return 0, errors.New("invalid transcode profile")
	}
	value := strings.TrimSuffix(strings.TrimPrefix(profile, "h264-"), "p")
	return strconv.Atoi(value)
}

func (a *App) transcodeProfileDir(mediaID, profile string) string {
	return filepath.Join(a.cfg.DataDir, "transcodes", mediaID, profile)
}

func (a *App) generateHLS(ctx context.Context, item Media, profile string) error {
	if err := a.ensureFFmpegAvailable(); err != nil {
		return err
	}
	height, err := profileHeight(profile)
	if err != nil {
		return err
	}
	finalDir := a.transcodeProfileDir(item.ID, profile)
	workDir := finalDir + ".work-" + randomID()
	if err := os.RemoveAll(workDir); err != nil {
		return err
	}
	if err := os.MkdirAll(workDir, 0o755); err != nil {
		return err
	}
	defer os.RemoveAll(workDir)

	segmentPattern := filepath.Join(workDir, "segment-%05d.ts")
	playlistPath := filepath.Join(workDir, "index.m3u8")
	args := []string{
		"-hide_banner", "-loglevel", "warning", "-y",
		"-i", item.Path(),
		"-map", "0:v:0", "-map", "0:a:0?", "-sn",
		"-vf", fmt.Sprintf("scale=-2:%d:force_original_aspect_ratio=decrease", height),
	}
	args = append(args, videoEncoderArgs(a.cfg.TranscodeHardware)...)
	args = append(args,
		"-pix_fmt", "yuv420p",
		"-c:a", "aac", "-b:a", "128k", "-ac", "2",
		"-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod",
		"-hls_flags", "independent_segments",
		"-hls_segment_filename", segmentPattern,
		"-progress", "pipe:1", "-nostats",
		playlistPath,
	)

	cmd := exec.CommandContext(ctx, a.cfg.FFmpegPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}

	scanner := bufio.NewScanner(stdout)
	lastUpdate := time.Time{}
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "out_time_ms=") || item.DurationMS <= 0 {
			continue
		}
		micros, parseErr := strconv.ParseInt(strings.TrimPrefix(line, "out_time_ms="), 10, 64)
		if parseErr != nil {
			continue
		}
		progress := float64(micros/1000) / float64(item.DurationMS)
		if progress < 0 {
			progress = 0
		}
		if progress > 0.99 {
			progress = 0.99
		}
		if lastUpdate.IsZero() || time.Since(lastUpdate) >= time.Second {
			_, _ = a.db.ExecContext(ctx, `UPDATE transcode_jobs SET progress=?,updated_at=? WHERE media_id=? AND profile=?`,
				progress, time.Now().UTC().Format(time.RFC3339Nano), item.ID, profile)
			lastUpdate = time.Now()
		}
	}
	if scanErr := scanner.Err(); scanErr != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return scanErr
	}
	if err := cmd.Wait(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return fmt.Errorf("ffmpeg hls: %s", message)
	}
	if _, err := os.Stat(playlistPath); err != nil {
		return fmt.Errorf("ffmpeg did not create playlist: %w", err)
	}
	if err := os.RemoveAll(finalDir); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(finalDir), 0o755); err != nil {
		return err
	}
	if err := os.Rename(workDir, finalDir); err != nil {
		return err
	}
	_ = os.Chtimes(finalDir, time.Now(), time.Now())
	return a.pruneTranscodeCache(finalDir)
}

func videoEncoderArgs(hardware string) []string {
	switch strings.ToLower(strings.TrimSpace(hardware)) {
	case "nvenc":
		return []string{"-c:v", "h264_nvenc", "-preset", "p4", "-cq", "23"}
	case "qsv":
		return []string{"-c:v", "h264_qsv", "-global_quality", "24"}
	case "amf":
		return []string{"-c:v", "h264_amf", "-quality", "speed"}
	default:
		return []string{"-c:v", "libx264", "-preset", "veryfast", "-crf", "23"}
	}
}

func (a *App) ensureFFmpegAvailable() error {
	if strings.TrimSpace(a.cfg.FFmpegPath) == "" {
		return errors.New("ffmpeg is not configured")
	}
	info, err := os.Stat(a.cfg.FFmpegPath)
	if err != nil || info.IsDir() {
		if err == nil {
			err = errors.New("path is a directory")
		}
		return fmt.Errorf("ffmpeg unavailable: %w", err)
	}
	return nil
}

func (a *App) transcodeFile(w http.ResponseWriter, r *http.Request) {
	mediaID := r.PathValue("mediaId")
	profile := r.PathValue("profile")
	name := r.PathValue("file")
	if !validProfile(profile) || !validTranscodeFile(name) {
		http.Error(w, "invalid transcode path", http.StatusBadRequest)
		return
	}
	item, err := a.findMediaByID(r.Context(), mediaID)
	if errors.Is(err, sql.ErrNoRows) || item.Missing {
		http.Error(w, "media not found", http.StatusNotFound)
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	state, err := a.transcodeJobState(r.Context(), mediaID, profile)
	if err != nil || state.Status != "done" {
		http.Error(w, "transcode is not ready", http.StatusNotFound)
		return
	}
	contentType := "video/mp2t"
	if name == "index.m3u8" {
		contentType = "application/vnd.apple.mpegurl"
	}
	serveFile(w, r, filepath.Join(a.transcodeProfileDir(mediaID, profile), name), contentType)
}

func validTranscodeFile(name string) bool {
	if name == "index.m3u8" {
		return true
	}
	if !strings.HasPrefix(name, "segment-") || !strings.HasSuffix(name, ".ts") {
		return false
	}
	middle := strings.TrimSuffix(strings.TrimPrefix(name, "segment-"), ".ts")
	if len(middle) != 5 {
		return false
	}
	_, err := strconv.Atoi(middle)
	return err == nil
}

func discoverSubtitles(item Media) []SubtitleManifest {
	directory := filepath.Dir(item.Path())
	base := strings.TrimSuffix(filepath.Base(item.Path()), filepath.Ext(item.Path()))
	entries, err := os.ReadDir(directory)
	if err != nil {
		return []SubtitleManifest{}
	}
	items := make([]SubtitleManifest, 0)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		ext := strings.ToLower(filepath.Ext(name))
		if ext != ".srt" && ext != ".ass" && ext != ".ssa" && ext != ".vtt" {
			continue
		}
		stem := strings.TrimSuffix(name, filepath.Ext(name))
		if stem != base && !strings.HasPrefix(stem, base+".") {
			continue
		}
		language := "und"
		if stem != base {
			language = strings.TrimPrefix(stem, base+".")
		}
		items = append(items, SubtitleManifest{
			ID: name, Name: name, Language: language,
			Format: strings.TrimPrefix(ext, "."),
			URL: fmt.Sprintf("/api/v1/media/%s/subtitle/%s", url.PathEscape(item.ID), url.PathEscape(name)),
		})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
	return items
}

func (a *App) subtitleFile(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	name := filepath.Base(r.PathValue("name"))
	if name == "." || name == "" || name != r.PathValue("name") {
		http.Error(w, "invalid subtitle path", http.StatusBadRequest)
		return
	}
	allowed := false
	for _, track := range discoverSubtitles(item) {
		if track.ID == name {
			allowed = true
			break
		}
	}
	if !allowed {
		http.Error(w, "subtitle not found", http.StatusNotFound)
		return
	}
	contentType := "text/plain; charset=utf-8"
	if strings.EqualFold(filepath.Ext(name), ".vtt") {
		contentType = "text/vtt; charset=utf-8"
	}
	serveFile(w, r, filepath.Join(filepath.Dir(item.Path()), name), contentType)
}

func (a *App) transcodeDiagnostics(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	rows, err := a.db.QueryContext(r.Context(), `SELECT status,COUNT(*) FROM transcode_jobs GROUP BY status ORDER BY status`)
	if err != nil {
		serverError(w, err)
		return
	}
	counts := map[string]int64{}
	for rows.Next() {
		var status string
		var count int64
		if err := rows.Scan(&status, &count); err != nil {
			_ = rows.Close()
			serverError(w, err)
			return
		}
		counts[status] = count
	}
	_ = rows.Close()

	failureRows, err := a.db.QueryContext(r.Context(), `
SELECT tj.media_id,m.file_name,tj.profile,tj.attempts,tj.last_error,tj.updated_at
FROM transcode_jobs tj JOIN media_items m ON m.id=tj.media_id
WHERE tj.status='failed' ORDER BY tj.updated_at DESC LIMIT 20`)
	if err != nil {
		serverError(w, err)
		return
	}
	failures := []map[string]any{}
	for failureRows.Next() {
		var mediaID, fileName, profile, lastError, updatedAt string
		var attempts int
		if err := failureRows.Scan(&mediaID, &fileName, &profile, &attempts, &lastError, &updatedAt); err != nil {
			_ = failureRows.Close()
			serverError(w, err)
			return
		}
		failures = append(failures, map[string]any{
			"mediaId": mediaID, "fileName": fileName, "profile": profile,
			"attempts": attempts, "error": lastError, "updatedAt": updatedAt,
		})
	}
	_ = failureRows.Close()
	cacheBytes, _ := directorySize(filepath.Join(a.cfg.DataDir, "transcodes"))
	ffmpegAvailable := a.ensureFFmpegAvailable() == nil
	writeJSON(w, http.StatusOK, map[string]any{
		"counts": counts, "failures": failures,
		"ffmpegPath": a.cfg.FFmpegPath, "ffmpegAvailable": ffmpegAvailable,
		"hardware": a.cfg.TranscodeHardware, "workers": a.cfg.TranscodeWorkers,
		"cacheDirectory": filepath.Join(a.cfg.DataDir, "transcodes"),
		"cacheBytes": cacheBytes, "cacheLimitBytes": int64(a.cfg.TranscodeCacheGB) * 1024 * 1024 * 1024,
	})
}

func (a *App) retryFailedTranscodes(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	result, err := a.db.ExecContext(r.Context(), `
UPDATE transcode_jobs SET status='pending',attempts=0,progress=0,last_error='',updated_at=?
WHERE status='failed'`, time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		serverError(w, err)
		return
	}
	count, _ := result.RowsAffected()
	a.wakeTranscodeWorkers()
	writeJSON(w, http.StatusAccepted, map[string]any{"status": "queued", "count": count})
}

type cacheEntry struct {
	path    string
	size    int64
	modTime time.Time
}

func (a *App) pruneTranscodeCache(current string) error {
	root := filepath.Join(a.cfg.DataDir, "transcodes")
	mediaDirs, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	entries := make([]cacheEntry, 0)
	var total int64
	for _, mediaDir := range mediaDirs {
		if !mediaDir.IsDir() {
			continue
		}
		profiles, readErr := os.ReadDir(filepath.Join(root, mediaDir.Name()))
		if readErr != nil {
			continue
		}
		for _, profile := range profiles {
			if !profile.IsDir() || strings.Contains(profile.Name(), ".work-") {
				continue
			}
			path := filepath.Join(root, mediaDir.Name(), profile.Name())
			size, _ := directorySize(path)
			info, statErr := profile.Info()
			if statErr != nil {
				continue
			}
			total += size
			entries = append(entries, cacheEntry{path: path, size: size, modTime: info.ModTime()})
		}
	}
	limit := int64(a.cfg.TranscodeCacheGB) * 1024 * 1024 * 1024
	if total <= limit {
		return nil
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].modTime.Before(entries[j].modTime) })
	for _, entry := range entries {
		if total <= limit {
			break
		}
		if filepath.Clean(entry.path) == filepath.Clean(current) {
			continue
		}
		if err := os.RemoveAll(entry.path); err == nil {
			total -= entry.size
		}
	}
	return nil
}

func directorySize(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		total += info.Size()
		return nil
	})
	return total, err
}
