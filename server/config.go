package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func loadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, err
	}
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(data, &raw)

	if cfg.ListenAddress == "" {
		cfg.ListenAddress = "0.0.0.0:9527"
	}
	if cfg.ServerName == "" {
		cfg.ServerName = "LocalLens"
	}
	if cfg.DataDir == "" {
		cfg.DataDir = "./data"
	}
	if _, ok := raw["watch_files"]; !ok {
		cfg.WatchFiles = true
	}
	if cfg.ThumbnailWorkers <= 0 {
		cfg.ThumbnailWorkers = 2
	}
	if cfg.MetadataWorkers <= 0 {
		cfg.MetadataWorkers = 2
	}
	if cfg.ThumbnailWorkers > 8 || cfg.MetadataWorkers > 8 {
		return Config{}, errors.New("worker counts must be between 1 and 8")
	}
	if cfg.PairingTTLMinutes <= 0 {
		cfg.PairingTTLMinutes = 5
	}
	if cfg.PairingTTLMinutes > 60 {
		return Config{}, errors.New("pairing_ttl_minutes must not exceed 60")
	}
	if len(cfg.APIToken) < 16 {
		return Config{}, errors.New("api_token must contain at least 16 characters")
	}
	if len(cfg.Libraries) == 0 {
		return Config{}, errors.New("at least one library is required")
	}

	base, _ := filepath.Abs(filepath.Dir(path))
	resolve := func(value string) string {
		if value == "" || filepath.IsAbs(value) {
			return value
		}
		absolute, _ := filepath.Abs(filepath.Join(base, value))
		return absolute
	}
	cfg.DataDir = resolve(cfg.DataDir)
	cfg.FFmpegPath = resolve(cfg.FFmpegPath)
	cfg.FFprobePath = resolve(cfg.FFprobePath)
	if cfg.FFprobePath == "" && cfg.FFmpegPath != "" {
		name := "ffprobe"
		if strings.EqualFold(filepath.Ext(cfg.FFmpegPath), ".exe") {
			name += ".exe"
		}
		cfg.FFprobePath = filepath.Join(filepath.Dir(cfg.FFmpegPath), name)
	}
	cfg.PublicURL = strings.TrimRight(strings.TrimSpace(cfg.PublicURL), "/")

	seenIDs := map[string]bool{}
	seenPaths := map[string]string{}
	for i := range cfg.Libraries {
		lib := &cfg.Libraries[i]
		if lib.ID == "" || lib.Name == "" || lib.Path == "" {
			return Config{}, errors.New("library id, name and path are required")
		}
		absolute, err := filepath.Abs(resolve(lib.Path))
		if err != nil {
			return Config{}, err
		}
		lib.Path = filepath.Clean(absolute)
		idKey := strings.ToLower(lib.ID)
		if seenIDs[idKey] {
			return Config{}, fmt.Errorf("duplicate library id %q", lib.ID)
		}
		pathKey := strings.ToLower(filepath.Clean(lib.Path))
		if existing, ok := seenPaths[pathKey]; ok {
			return Config{}, fmt.Errorf("libraries %q and %q use the same path", existing, lib.ID)
		}
		seenIDs[idKey] = true
		seenPaths[pathKey] = lib.ID
	}
	return cfg, nil
}
