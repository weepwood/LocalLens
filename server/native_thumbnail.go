package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"image"
	"image/color"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	nativeThumbnailIdleInterval = time.Second
	nativeThumbnailMigration    = 9
)

// prepareNativeImageThumbnailQueue routes image jobs to the native image worker.
// It also performs a one-time recovery of image jobs which became permanently
// failed in v0.2.0/v0.2.1 when FFmpeg was unavailable.
func (a *App) prepareNativeImageThumbnailQueue(ctx context.Context) (int64, error) {
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, `
DROP TRIGGER IF EXISTS route_image_thumbnail_insert_v022;
DROP TRIGGER IF EXISTS route_image_thumbnail_update_v022;
CREATE TRIGGER route_image_thumbnail_insert_v022
AFTER INSERT ON thumbnail_jobs
WHEN NEW.status='pending'
 AND EXISTS (
   SELECT 1 FROM media_items
   WHERE id=NEW.media_id AND media_type='image'
 )
BEGIN
  UPDATE thumbnail_jobs
  SET status='native_pending'
  WHERE media_id=NEW.media_id AND width=NEW.width;
END;
CREATE TRIGGER route_image_thumbnail_update_v022
AFTER UPDATE OF status,source_modified_at ON thumbnail_jobs
WHEN NEW.status='pending'
 AND EXISTS (
   SELECT 1 FROM media_items
   WHERE id=NEW.media_id AND media_type='image'
 )
BEGIN
  UPDATE thumbnail_jobs
  SET status='native_pending'
  WHERE media_id=NEW.media_id AND width=NEW.width;
END;
UPDATE thumbnail_jobs
SET status='native_pending'
WHERE status IN ('pending','native_running')
  AND media_id IN (
    SELECT id FROM media_items WHERE media_type='image' AND missing=0
  );
`); err != nil {
		return 0, err
	}

	var applied int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM schema_migrations WHERE version=?`,
		nativeThumbnailMigration,
	).Scan(&applied); err != nil {
		return 0, err
	}

	var recovered int64
	if applied == 0 {
		result, err := tx.ExecContext(ctx, `
UPDATE thumbnail_jobs
SET status='native_pending',attempts=0,last_error='',updated_at=?
WHERE status IN ('failed','done')
  AND media_id IN (
    SELECT id FROM media_items WHERE media_type='image' AND missing=0
  )`, priorityTimestamp())
		if err != nil {
			return 0, err
		}
		recovered, _ = result.RowsAffected()
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)`,
			nativeThumbnailMigration,
			time.Now().UTC().Format(time.RFC3339Nano),
		); err != nil {
			return 0, err
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return recovered, nil
}

func priorityTimestamp() string {
	return "0000:" + time.Now().UTC().Format(time.RFC3339Nano)
}

func (a *App) startNativeImageThumbnailWorkers() {
	count := a.cfg.ThumbnailWorkers
	if count < 1 {
		count = 1
	}
	for i := 0; i < count; i++ {
		a.workerWG.Add(1)
		go a.nativeImageThumbnailWorker(i + 1)
	}
}

func (a *App) nativeImageThumbnailWorker(number int) {
	defer a.workerWG.Done()
	ticker := time.NewTicker(nativeThumbnailIdleInterval)
	defer ticker.Stop()

	for {
		if a.isScanRunning() {
			if !waitForWorker(a.serviceCtx, a.thumbnailWake, workerScanPause) {
				return
			}
			continue
		}

		job, ok, err := a.claimNativeImageThumbnailJob(a.serviceCtx)
		if err != nil {
			if !isSQLiteBusy(err) {
				a.logger.Warn("claim native image thumbnail", "worker", number, "error", err)
			}
			if !waitForWorker(a.serviceCtx, a.thumbnailWake, workerScanPause) {
				return
			}
			continue
		}
		if ok {
			a.processNativeImageThumbnailJob(a.serviceCtx, job)
			continue
		}

		select {
		case <-a.serviceCtx.Done():
			return
		case <-a.thumbnailWake:
		case <-ticker.C:
		}
	}
}

func (a *App) claimNativeImageThumbnailJob(ctx context.Context) (ThumbnailJob, bool, error) {
	var job ThumbnailJob
	err := retrySQLiteBusy(ctx, sqliteBusyRetryLimit, func() error {
		job = ThumbnailJob{}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		return a.db.QueryRowContext(ctx, `
UPDATE thumbnail_jobs
SET status='native_running',attempts=attempts+1,updated_at=?
WHERE rowid=(
  SELECT tj.rowid
  FROM thumbnail_jobs tj
  JOIN media_items m ON m.id=tj.media_id
  WHERE tj.status='native_pending'
    AND m.media_type='image'
    AND m.missing=0
  ORDER BY tj.updated_at,tj.media_id,tj.width
  LIMIT 1
)
AND status='native_pending'
RETURNING media_id,width,source_modified_at,attempts`, now).
			Scan(&job.MediaID, &job.Width, &job.SourceModifiedAt, &job.Attempts)
	})
	if errors.Is(err, sql.ErrNoRows) {
		return ThumbnailJob{}, false, nil
	}
	if err != nil {
		return ThumbnailJob{}, false, err
	}
	return job, true, nil
}

func (a *App) processNativeImageThumbnailJob(ctx context.Context, job ThumbnailJob) {
	item, err := a.findMediaByID(ctx, job.MediaID)
	if err == nil && item.Missing {
		err = errors.New("media is missing")
	}
	if err == nil && item.Type != "image" {
		err = errors.New("media is not an image")
	}
	if err == nil && item.ModifiedAt.UTC().Format(time.RFC3339Nano) != job.SourceModifiedAt {
		err = errors.New("media changed while thumbnail was queued")
	}
	if err == nil {
		err = a.generateNativeOrFFmpegImageThumbnail(ctx, item, job.Width)
	}

	status := "done"
	message := ""
	if err != nil {
		message = truncateError(err)
		if job.Attempts < 3 && !strings.Contains(strings.ToLower(message), "unsupported") {
			status = "native_pending"
			time.Sleep(time.Duration(job.Attempts) * 250 * time.Millisecond)
		} else {
			status = "failed"
			a.logger.Warn("image thumbnail failed", "media", job.MediaID, "width", job.Width, "attempts", job.Attempts, "error", err)
		}
	}
	_, _ = a.db.ExecContext(ctx, `
UPDATE thumbnail_jobs SET status=?,last_error=?,updated_at=?
WHERE media_id=? AND width=?`,
		status, message, time.Now().UTC().Format(time.RFC3339Nano), job.MediaID, job.Width)
	if status == "native_pending" {
		a.wakeThumbnailWorkers()
	}
}

func (a *App) generateNativeOrFFmpegImageThumbnail(ctx context.Context, item Media, width int) error {
	path := a.thumbnailPath(item, width)
	if _, err := os.Stat(path); err == nil {
		return nil
	}

	nativeErr := generateNativeImageThumbnail(ctx, item.Path(), path, width)
	if nativeErr == nil {
		return nil
	}

	// HEIC, TIFF, WEBP and unusual JPEG variants may not be supported by the
	// standard-library decoder. Keep FFmpeg as a compatibility fallback.
	ffmpegErr := a.generateThumbnail(ctx, item, width)
	if ffmpegErr == nil {
		return nil
	}
	return fmt.Errorf("native decoder: %v; ffmpeg fallback: %w", nativeErr, ffmpegErr)
}

func generateNativeImageThumbnail(ctx context.Context, sourcePath, targetPath string, width int) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("image decoder panic: %v", recovered)
		}
	}()

	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	decoded, format, err := image.Decode(source)
	closeErr := source.Close()
	if err != nil {
		return fmt.Errorf("unsupported or corrupt image: %w", err)
	}
	if closeErr != nil {
		return closeErr
	}

	bounds := decoded.Bounds()
	sourceWidth, sourceHeight := bounds.Dx(), bounds.Dy()
	if sourceWidth <= 0 || sourceHeight <= 0 {
		return errors.New("image has invalid dimensions")
	}
	if width < 1 {
		width = 480
	}
	targetWidth := width
	if targetWidth > sourceWidth {
		targetWidth = sourceWidth
	}
	targetHeight := max(1, int((int64(sourceHeight)*int64(targetWidth))/int64(sourceWidth)))

	thumbnail := image.NewNRGBA(image.Rect(0, 0, targetWidth, targetHeight))
	for y := 0; y < targetHeight; y++ {
		if y%32 == 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
			}
		}
		sourceY := bounds.Min.Y + (y*sourceHeight)/targetHeight
		for x := 0; x < targetWidth; x++ {
			sourceX := bounds.Min.X + (x*sourceWidth)/targetWidth
			pixel := color.NRGBAModel.Convert(decoded.At(sourceX, sourceY)).(color.NRGBA)
			if pixel.A < 255 {
				alpha := int(pixel.A)
				pixel.R = uint8((int(pixel.R)*alpha + 255*(255-alpha)) / 255)
				pixel.G = uint8((int(pixel.G)*alpha + 255*(255-alpha)) / 255)
				pixel.B = uint8((int(pixel.B)*alpha + 255*(255-alpha)) / 255)
				pixel.A = 255
			}
			thumbnail.SetNRGBA(x, y, pixel)
		}
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return err
	}
	tempPath := targetPath + "." + randomID() + ".jpg"
	defer os.Remove(tempPath)
	output, err := os.OpenFile(tempPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	encodeErr := jpeg.Encode(output, thumbnail, &jpeg.Options{Quality: 82})
	closeErr = output.Close()
	if encodeErr != nil {
		return fmt.Errorf("encode %s thumbnail: %w", format, encodeErr)
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(tempPath, targetPath); err != nil {
		if removeErr := os.Remove(targetPath); removeErr == nil {
			return os.Rename(tempPath, targetPath)
		}
		return err
	}
	return nil
}

func (a *App) enqueuePriorityThumbnail(ctx context.Context, item Media, width int) error {
	width = clampInt(width, 64, 1920)
	status := "pending"
	if item.Type == "image" {
		status = "native_pending"
	}
	now := priorityTimestamp()
	_, err := a.db.ExecContext(ctx, `
INSERT INTO thumbnail_jobs(media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,?,?,0,'',?,?)
ON CONFLICT(media_id,width) DO UPDATE SET
  source_modified_at=excluded.source_modified_at,
  status=CASE
    WHEN thumbnail_jobs.status IN ('running','native_running') THEN thumbnail_jobs.status
    ELSE excluded.status END,
  attempts=CASE
    WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at
      OR thumbnail_jobs.status IN ('done','failed') THEN 0
    ELSE thumbnail_jobs.attempts END,
  last_error=CASE
    WHEN thumbnail_jobs.status IN ('running','native_running') THEN thumbnail_jobs.last_error
    ELSE '' END,
  updated_at=excluded.updated_at`,
		item.ID, width, item.ModifiedAt.UTC().Format(time.RFC3339Nano), status, now, now)
	if err == nil {
		a.wakeThumbnailWorkers()
	}
	return err
}

func (a *App) thumbnailV022(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	width := clampInt(queryInt(r, "width", 480), 64, 1920)
	path := a.thumbnailPath(item, width)
	if _, err := os.Stat(path); err == nil {
		serveFile(w, r, path, "image/jpeg")
		return
	}
	if err := a.enqueuePriorityThumbnail(r.Context(), item, width); err != nil {
		serverError(w, err)
		return
	}
	if waitForFile(r.Context(), path, 12*time.Second) {
		serveFile(w, r, path, "image/jpeg")
		return
	}

	var status, lastError string
	_ = a.db.QueryRowContext(r.Context(), `
SELECT status,last_error FROM thumbnail_jobs WHERE media_id=? AND width=?`,
		item.ID, width).Scan(&status, &lastError)
	if status == "failed" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"status": "failed", "error": lastError, "mediaId": item.ID,
		})
		return
	}
	w.Header().Set("Retry-After", "2")
	writeJSON(w, http.StatusAccepted, map[string]any{"status": status, "retryAfter": 2})
}

func (a *App) thumbnailDiagnostics(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.QueryContext(r.Context(), `
SELECT status,COUNT(*) FROM thumbnail_jobs GROUP BY status ORDER BY status`)
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
SELECT tj.media_id,m.file_name,tj.width,tj.attempts,tj.last_error
FROM thumbnail_jobs tj
JOIN media_items m ON m.id=tj.media_id
WHERE tj.status='failed'
ORDER BY tj.updated_at DESC
LIMIT 20`)
	if err != nil {
		serverError(w, err)
		return
	}
	failures := []map[string]any{}
	for failureRows.Next() {
		var mediaID, fileName, lastError string
		var width, attempts int
		if err := failureRows.Scan(&mediaID, &fileName, &width, &attempts, &lastError); err != nil {
			_ = failureRows.Close()
			serverError(w, err)
			return
		}
		failures = append(failures, map[string]any{
			"mediaId": mediaID, "fileName": fileName, "width": width,
			"attempts": attempts, "error": lastError,
		})
	}
	_ = failureRows.Close()

	ffmpegAvailable := false
	if a.cfg.FFmpegPath != "" {
		if info, statErr := os.Stat(a.cfg.FFmpegPath); statErr == nil && !info.IsDir() {
			ffmpegAvailable = true
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"counts": counts,
		"failures": failures,
		"nativeImageFormats": []string{"jpeg", "png", "gif"},
		"ffmpegPath": a.cfg.FFmpegPath,
		"ffmpegAvailable": ffmpegAvailable,
		"cacheDirectory": filepath.Join(a.cfg.DataDir, "thumbnails"),
	})
}

func (a *App) retryFailedThumbnails(w http.ResponseWriter, r *http.Request) {
	identity := identityFromRequest(r)
	if !identity.Admin {
		http.Error(w, "administrator token required", http.StatusForbidden)
		return
	}

	now := priorityTimestamp()
	imageResult, err := a.db.ExecContext(r.Context(), `
UPDATE thumbnail_jobs
SET status='native_pending',attempts=0,last_error='',updated_at=?
WHERE status='failed'
  AND media_id IN (SELECT id FROM media_items WHERE media_type='image' AND missing=0)`, now)
	if err != nil {
		serverError(w, err)
		return
	}
	videoResult, err := a.db.ExecContext(r.Context(), `
UPDATE thumbnail_jobs
SET status='pending',attempts=0,last_error='',updated_at=?
WHERE status='failed'
  AND media_id IN (SELECT id FROM media_items WHERE media_type='video' AND missing=0)`, now)
	if err != nil {
		serverError(w, err)
		return
	}
	images, _ := imageResult.RowsAffected()
	videos, _ := videoResult.RowsAffected()
	a.wakeThumbnailWorkers()
	writeJSON(w, http.StatusAccepted, map[string]any{
		"status": "queued", "images": images, "videos": videos,
	})
}

func (a *App) routesV022() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /api/v1/media/{id}/thumbnail", a.auth(http.HandlerFunc(a.thumbnailV022)))
	mux.Handle("GET /api/v1/thumbnails/diagnostics", a.auth(http.HandlerFunc(a.thumbnailDiagnostics)))
	mux.Handle("POST /api/v1/thumbnails/retry", a.auth(http.HandlerFunc(a.retryFailedThumbnails)))
	mux.Handle("/", a.routes())
	return a.cors(mux)
}
