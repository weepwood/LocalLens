package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
	if cfg.ListenAddress == "" {
		cfg.ListenAddress = "0.0.0.0:9527"
	}
	if cfg.ServerName == "" {
		cfg.ServerName = "LocalLens"
	}
	if cfg.DataDir == "" {
		cfg.DataDir = "./data"
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
		if seenIDs[lib.ID] {
			return Config{}, fmt.Errorf("duplicate library id %q", lib.ID)
		}
		pathKey := filepath.Clean(lib.Path)
		if existing, ok := seenPaths[pathKey]; ok {
			return Config{}, fmt.Errorf("libraries %q and %q use the same path", existing, lib.ID)
		}
		seenIDs[lib.ID] = true
		seenPaths[pathKey] = lib.ID
	}
	return cfg, nil
}
