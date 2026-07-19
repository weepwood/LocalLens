package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	workerIdleInterval   = 10 * time.Second
	workerScanPause      = 500 * time.Millisecond
	sqliteBusyRetryLimit = 30 * time.Second
)

func (a *App) startBackgroundWorkers() error {
	if _, err := a.db.Exec(`UPDATE thumbnail_jobs SET status='pending' WHERE status='running'`); err != nil {
		return err
	}
	if _, err := a.db.Exec(`UPDATE metadata_jobs SET status='pending' WHERE status='running'`); err != nil {
		return err
	}
	for i := 0; i < a.cfg.ThumbnailWorkers; i++ {
		a.workerWG.Add(1)
		go a.thumbnailWorker(i + 1)
	}
	for i := 0; i < a.cfg.MetadataWorkers; i++ {
		a.workerWG.Add(1)
		go a.metadataWorker(i + 1)
	}
	a.wakeThumbnailWorkers()
	a.wakeMetadataWorkers()
	return nil
}

func (a *App) stopBackgroundServices() {
	a.serviceCancel()
	if a.watcher != nil {
		_ = a.watcher.Close()
	}
	a.workerWG.Wait()
}

func (a *App) wakeThumbnailWorkers() {
	select {
	case a.thumbnailWake <- struct{}{}:
	default:
	}
}

func (a *App) wakeMetadataWorkers() {
	select {
	case a.metadataWake <- struct{}{}:
	default:
	}
}

func (a *App) isScanRunning() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.scan.Running
}

func waitForWorker(ctx context.Context, wake <-chan struct{}, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-wake:
		return true
	case <-timer.C:
		return true
	}
}

func (a *App) thumbnailWorker(number int) {
	defer a.workerWG.Done()
	ticker := time.NewTicker(workerIdleInterval)
	defer ticker.Stop()
	for {
		if a.isScanRunning() {
			if !waitForWorker(a.serviceCtx, a.thumbnailWake, workerScanPause) {
				return
			}
			continue
		}

		job, ok, err := a.claimThumbnailJob(a.serviceCtx)
		if err != nil {
			if isSQLiteBusy(err) {
				a.logger.Debug("thumbnail queue busy", "worker", number, "error", err)
				if !waitForWorker(a.serviceCtx, a.thumbnailWake, workerScanPause) {
					return
				}
				continue
			}
			a.logger.Warn("claim thumbnail job", "worker", number, "error", err)
		}
		if ok {
			a.processThumbnailJob(a.serviceCtx, job)
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

func (a *App) metadataWorker(number int) {
	defer a.workerWG.Done()
	ticker := time.NewTicker(workerIdleInterval)
	defer ticker.Stop()
	for {
		if a.isScanRunning() {
			if !waitForWorker(a.serviceCtx, a.metadataWake, workerScanPause) {
				return
			}
			continue
		}

		job, ok, err := a.claimMetadataJob(a.serviceCtx)
		if err != nil {
			if isSQLiteBusy(err) {
				a.logger.Debug("metadata queue busy", "worker", number, "error", err)
				if !waitForWorker(a.serviceCtx, a.metadataWake, workerScanPause) {
					return
				}
				continue
			}
			a.logger.Warn("claim metadata job", "worker", number, "error", err)
		}
		if ok {
			a.processMetadataJob(a.serviceCtx, job)
			continue
		}
		select {
		case <-a.serviceCtx.Done():
			return
		case <-a.metadataWake:
		case <-ticker.C:
		}
	}
}

func (a *App) claimThumbnailJob(ctx context.Context) (ThumbnailJob, bool, error) {
	var job ThumbnailJob
	err := retrySQLiteBusy(ctx, sqliteBusyRetryLimit, func() error {
		job = ThumbnailJob{}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		return a.db.QueryRowContext(ctx, `
UPDATE thumbnail_jobs
SET status='running',attempts=attempts+1,updated_at=?
WHERE rowid=(
  SELECT rowid
  FROM thumbnail_jobs
  WHERE status='pending'
  ORDER BY updated_at,media_id,width
  LIMIT 1
)
AND status='pending'
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

func (a *App) claimMetadataJob(ctx context.Context) (MetadataJob, bool, error) {
	var job MetadataJob
	err := retrySQLiteBusy(ctx, sqliteBusyRetryLimit, func() error {
		job = MetadataJob{}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		return a.db.QueryRowContext(ctx, `
UPDATE metadata_jobs
SET status='running',attempts=attempts+1,updated_at=?
WHERE rowid=(
  SELECT rowid
  FROM metadata_jobs
  WHERE status='pending'
  ORDER BY updated_at,media_id
  LIMIT 1
)
AND status='pending'
RETURNING media_id,source_modified_at,attempts`, now).
			Scan(&job.MediaID, &job.SourceModifiedAt, &job.Attempts)
	})
	if errors.Is(err, sql.ErrNoRows) {
		return MetadataJob{}, false, nil
	}
	if err != nil {
		return MetadataJob{}, false, err
	}
	return job, true, nil
}

func retrySQLiteBusy(ctx context.Context, limit time.Duration, operation func() error) error {
	started := time.Now()
	delay := 25 * time.Millisecond
	for {
		err := operation()
		if err == nil || !isSQLiteBusy(err) {
			return err
		}
		if time.Since(started) >= limit {
			return err
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
		if delay < 500*time.Millisecond {
			delay *= 2
			if delay > 500*time.Millisecond {
				delay = 500 * time.Millisecond
			}
		}
	}
}

func isSQLiteBusy(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "sqlite_busy") ||
		strings.Contains(message, "database is locked") ||
		strings.Contains(message, "database table is locked")
}

func (a *App) enqueueThumbnail(ctx context.Context, mediaID string, width int, sourceModifiedAt string) error {
	width = clampInt(width, 64, 1920)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := a.db.ExecContext(ctx, `
INSERT INTO thumbnail_jobs(media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,?,'pending',0,'',?,?)
ON CONFLICT(media_id,width) DO UPDATE SET
  source_modified_at=excluded.source_modified_at,
  status=CASE
    WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending'
    WHEN thumbnail_jobs.status='failed' AND thumbnail_jobs.attempts<3 THEN 'pending'
    ELSE thumbnail_jobs.status END,
  attempts=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE thumbnail_jobs.attempts END,
  last_error=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE thumbnail_jobs.last_error END,
  updated_at=excluded.updated_at`, mediaID, width, sourceModifiedAt, now, now)
	if err == nil {
		a.wakeThumbnailWorkers()
	}
	return err
}

func (a *App) enqueueMetadata(ctx context.Context, mediaID, sourceModifiedAt string) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := a.db.ExecContext(ctx, `
INSERT INTO metadata_jobs(media_id,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,'pending',0,'',?,?)
ON CONFLICT(media_id) DO UPDATE SET
  source_modified_at=excluded.source_modified_at,
  status=CASE
    WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending'
    WHEN metadata_jobs.status='failed' AND metadata_jobs.attempts<3 THEN 'pending'
    ELSE metadata_jobs.status END,
  attempts=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE metadata_jobs.attempts END,
  last_error=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE metadata_jobs.last_error END,
  updated_at=excluded.updated_at`, mediaID, sourceModifiedAt, now, now)
	if err == nil {
		a.wakeMetadataWorkers()
	}
	return err
}

func (a *App) processThumbnailJob(ctx context.Context, job ThumbnailJob) {
	item, err := a.findMediaByID(ctx, job.MediaID)
	if err == nil && item.Missing {
		err = errors.New("media is missing")
	}
	if err == nil && item.ModifiedAt.UTC().Format(time.RFC3339Nano) != job.SourceModifiedAt {
		err = errors.New("media changed while job was queued")
	}
	if err == nil {
		err = a.generateThumbnail(ctx, item, job.Width)
	}
	status := "done"
	message := ""
	if err != nil {
		status = "failed"
		message = truncateError(err)
		a.logger.Warn("thumbnail job", "media", job.MediaID, "width", job.Width, "error", err)
	}
	_, _ = a.db.ExecContext(ctx, `
UPDATE thumbnail_jobs SET status=?,last_error=?,updated_at=? WHERE media_id=? AND width=?`,
		status, message, time.Now().UTC().Format(time.RFC3339Nano), job.MediaID, job.Width)
}

func (a *App) processMetadataJob(ctx context.Context, job MetadataJob) {
	item, err := a.findMediaByID(ctx, job.MediaID)
	if err == nil && item.Missing {
		err = errors.New("media is missing")
	}
	if err == nil && item.ModifiedAt.UTC().Format(time.RFC3339Nano) != job.SourceModifiedAt {
		err = errors.New("media changed while job was queued")
	}
	if err == nil {
		err = a.extractAndStoreMetadata(ctx, item)
	}
	status := "done"
	message := ""
	if err != nil {
		status = "failed"
		message = truncateError(err)
		_, _ = a.db.ExecContext(ctx, `UPDATE media_items SET metadata_status='failed',metadata_error=? WHERE id=?`, message, job.MediaID)
		a.logger.Debug("metadata job", "media", job.MediaID, "error", err)
	}
	_, _ = a.db.ExecContext(ctx, `
UPDATE metadata_jobs SET status=?,last_error=?,updated_at=? WHERE media_id=?`,
		status, message, time.Now().UTC().Format(time.RFC3339Nano), job.MediaID)
}

func (a *App) generateThumbnail(ctx context.Context, item Media, width int) error {
	path := a.thumbnailPath(item, width)
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if a.cfg.FFmpegPath == "" {
		return errors.New("ffmpeg is not configured")
	}
	if _, err := os.Stat(a.cfg.FFmpegPath); err != nil {
		return fmt.Errorf("ffmpeg unavailable: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tempPath := path + "." + randomID() + ".jpg"
	defer os.Remove(tempPath)
	args := []string{"-hide_banner", "-loglevel", "error"}
	if item.Type == "video" {
		position := "2"
		if item.DurationMS > 0 && item.DurationMS < 6000 {
			position = "0.2"
		}
		args = append(args, "-ss", position)
	}
	args = append(args, "-i", item.Path(), "-frames:v", "1", "-vf", "scale="+strconv.Itoa(width)+":-2", "-q:v", "4", "-y", tempPath)
	command := exec.CommandContext(ctx, a.cfg.FFmpegPath, args...)
	hideChildProcessWindow(command)
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if err := os.Rename(tempPath, path); err != nil {
		if removeErr := os.Remove(path); removeErr == nil {
			return os.Rename(tempPath, path)
		}
		return err
	}
	return nil
}

func (a *App) thumbnailPath(item Media, width int) string {
	return filepath.Join(a.cfg.DataDir, "thumbnails", item.ID[:2], fmt.Sprintf("%s-%d-%d.jpg", item.ID, item.ModifiedAt.Unix(), width))
}

func truncateError(err error) string {
	if err == nil {
		return ""
	}
	value := strings.TrimSpace(err.Error())
	if len(value) > 1000 {
		return value[:1000]
	}
	return value
}
