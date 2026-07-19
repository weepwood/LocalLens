package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/rwcarlsen/goexif/exif"
)

type extractedMetadata struct {
	Width            int
	Height           int
	DurationMS       int64
	Codec            string
	CapturedAt       time.Time
	CapturedAtSource string
	Latitude         *float64
	Longitude        *float64
	CameraModel      string
}

type ffprobeResult struct {
	Streams []struct {
		Width     int               `json:"width"`
		Height    int               `json:"height"`
		CodecName string            `json:"codec_name"`
		Duration  string            `json:"duration"`
		Tags      map[string]string `json:"tags"`
	} `json:"streams"`
	Format struct {
		Duration string            `json:"duration"`
		Tags     map[string]string `json:"tags"`
	} `json:"format"`
}

func (a *App) extractAndStoreMetadata(ctx context.Context, item Media) error {
	metadata := extractedMetadata{
		CapturedAt:       item.ModifiedAt,
		CapturedAtSource: "modified",
	}
	var extractionErrors []string
	if item.Type == "image" {
		if err := extractImageDimensions(item.Path(), &metadata); err != nil {
			extractionErrors = append(extractionErrors, err.Error())
		}
		if err := extractImageEXIF(item.Path(), &metadata); err != nil && !exif.IsTagNotPresentError(err) {
			extractionErrors = append(extractionErrors, err.Error())
		}
	}
	if item.Type == "video" || metadata.Width == 0 || metadata.Height == 0 {
		probe, err := a.runFFprobe(ctx, item.Path())
		if err != nil {
			extractionErrors = append(extractionErrors, err.Error())
		} else {
			applyFFprobe(probe, &metadata)
		}
	}
	if metadata.CapturedAt.IsZero() {
		metadata.CapturedAt = item.ModifiedAt
		metadata.CapturedAtSource = "modified"
	}

	_, err := a.db.ExecContext(ctx, `
UPDATE media_items SET
  width=?,height=?,duration_ms=?,codec=?,captured_at=?,captured_at_source=?,
  latitude=?,longitude=?,camera_model=?,metadata_status='done',metadata_error=''
WHERE id=?`,
		metadata.Width,
		metadata.Height,
		metadata.DurationMS,
		metadata.Codec,
		metadata.CapturedAt.UTC().Format(time.RFC3339Nano),
		metadata.CapturedAtSource,
		metadata.Latitude,
		metadata.Longitude,
		metadata.CameraModel,
		item.ID,
	)
	if err != nil {
		return err
	}
	if item.Type == "video" && metadata.Width == 0 && metadata.Height == 0 && len(extractionErrors) > 0 {
		return errors.New(strings.Join(extractionErrors, "; "))
	}
	return nil
}

func extractImageDimensions(path string, metadata *extractedMetadata) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	config, _, err := image.DecodeConfig(file)
	if err != nil {
		return fmt.Errorf("decode image dimensions: %w", err)
	}
	metadata.Width = config.Width
	metadata.Height = config.Height
	return nil
}

func extractImageEXIF(path string, metadata *extractedMetadata) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	x, err := exif.Decode(file)
	if err != nil {
		if x == nil || exif.IsCriticalError(err) {
			return fmt.Errorf("decode exif: %w", err)
		}
	}
	if captured, capturedErr := x.DateTime(); capturedErr == nil {
		metadata.CapturedAt = captured
		metadata.CapturedAtSource = "exif"
	}
	if lat, long, gpsErr := x.LatLong(); gpsErr == nil {
		metadata.Latitude = &lat
		metadata.Longitude = &long
	}
	if modelTag, modelErr := x.Get(exif.Model); modelErr == nil {
		if model, valueErr := modelTag.StringVal(); valueErr == nil {
			metadata.CameraModel = strings.TrimSpace(model)
		}
	}
	return nil
}

func (a *App) runFFprobe(ctx context.Context, path string) (ffprobeResult, error) {
	if a.cfg.FFprobePath == "" {
		return ffprobeResult{}, errors.New("ffprobe is not configured")
	}
	if _, err := os.Stat(a.cfg.FFprobePath); err != nil {
		return ffprobeResult{}, fmt.Errorf("ffprobe unavailable: %w", err)
	}
	args := []string{
		"-v", "error",
		"-select_streams", "v:0",
		"-show_entries", "stream=width,height,codec_name,duration:stream_tags=creation_time:format=duration:format_tags=creation_time",
		"-of", "json",
		path,
	}
	command := exec.CommandContext(ctx, a.cfg.FFprobePath, args...)
	hideChildProcessWindow(command)
	output, err := command.CombinedOutput()
	if err != nil {
		return ffprobeResult{}, fmt.Errorf("ffprobe: %w: %s", err, strings.TrimSpace(string(output)))
	}
	var result ffprobeResult
	if err := json.Unmarshal(output, &result); err != nil {
		return ffprobeResult{}, fmt.Errorf("parse ffprobe output: %w", err)
	}
	return result, nil
}

func applyFFprobe(result ffprobeResult, metadata *extractedMetadata) {
	if len(result.Streams) > 0 {
		stream := result.Streams[0]
		if stream.Width > 0 {
			metadata.Width = stream.Width
		}
		if stream.Height > 0 {
			metadata.Height = stream.Height
		}
		metadata.Codec = stream.CodecName
		if duration := parseSeconds(stream.Duration); duration > 0 {
			metadata.DurationMS = duration
		}
		if captured := parseMediaTime(stream.Tags["creation_time"]); !captured.IsZero() {
			metadata.CapturedAt = captured
			metadata.CapturedAtSource = "container"
		}
	}
	if duration := parseSeconds(result.Format.Duration); duration > metadata.DurationMS {
		metadata.DurationMS = duration
	}
	if metadata.CapturedAtSource == "modified" {
		if captured := parseMediaTime(result.Format.Tags["creation_time"]); !captured.IsZero() {
			metadata.CapturedAt = captured
			metadata.CapturedAtSource = "container"
		}
	}
}

func parseSeconds(value string) int64 {
	seconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || seconds <= 0 {
		return 0
	}
	return int64(seconds * 1000)
}

func parseMediaTime(value string) time.Time {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}
	}
	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05Z07:00",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed
		}
	}
	return time.Time{}
}
