package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

type FileWatcher struct {
	app     *App
	watcher *fsnotify.Watcher
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	timers  map[string]*time.Timer
}

func newFileWatcher(app *App) (*FileWatcher, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(app.serviceCtx)
	return &FileWatcher{
		app: app, watcher: watcher, ctx: ctx, cancel: cancel,
		timers: make(map[string]*time.Timer),
	}, nil
}

func (f *FileWatcher) Start() error {
	for _, lib := range f.app.cfg.Libraries {
		if !lib.Enabled {
			continue
		}
		if err := f.addLibrary(lib); err != nil {
			f.app.logger.Warn("watch library", "library", lib.ID, "error", err)
		}
	}
	f.app.workerWG.Add(1)
	go f.loop()
	return nil
}

func (f *FileWatcher) Close() error {
	f.cancel()
	f.mu.Lock()
	for _, timer := range f.timers {
		timer.Stop()
	}
	f.timers = make(map[string]*time.Timer)
	f.mu.Unlock()
	return f.watcher.Close()
}

func (f *FileWatcher) addLibrary(lib Library) error {
	info, err := os.Stat(lib.Path)
	if err != nil || !info.IsDir() {
		return err
	}
	if !lib.Recursive {
		return f.watcher.Add(lib.Path)
	}
	return f.addDirectoryTree(lib.Path)
}

func (f *FileWatcher) addDirectoryTree(root string) error {
	return filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if entry.IsDir() {
			if err := f.watcher.Add(path); err != nil && !strings.Contains(strings.ToLower(err.Error()), "exists") {
				f.app.logger.Debug("watch directory", "path", path, "error", err)
			}
		}
		return nil
	})
}

func (f *FileWatcher) loop() {
	defer f.app.workerWG.Done()
	for {
		select {
		case <-f.ctx.Done():
			return
		case err, ok := <-f.watcher.Errors:
			if !ok {
				return
			}
			f.app.logger.Warn("filesystem watcher", "error", err)
		case event, ok := <-f.watcher.Events:
			if !ok {
				return
			}
			f.handleEvent(event)
		}
	}
}

func (f *FileWatcher) handleEvent(event fsnotify.Event) {
	if event.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Rename|fsnotify.Remove) == 0 {
		return
	}
	if event.Op&fsnotify.Create != 0 {
		if info, err := os.Stat(event.Name); err == nil && info.IsDir() {
			_ = f.addDirectoryTree(event.Name)
		}
	}
	f.schedule(event.Name)
}

func (f *FileWatcher) schedule(path string) {
	path = filepath.Clean(path)
	f.mu.Lock()
	if previous := f.timers[path]; previous != nil {
		previous.Stop()
	}
	f.timers[path] = time.AfterFunc(1200*time.Millisecond, func() {
		f.mu.Lock()
		delete(f.timers, path)
		f.mu.Unlock()
		f.process(path)
	})
	f.mu.Unlock()
}

func (f *FileWatcher) process(path string) {
	if f.ctx.Err() != nil {
		return
	}
	lib, ok := f.app.libraryForPath(path)
	if !ok {
		return
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := f.app.markPathMissing(f.ctx, lib, path); err != nil {
			f.app.logger.Warn("mark path missing", "path", path, "error", err)
		}
		return
	}
	if err != nil {
		f.app.logger.Debug("inspect changed path", "path", path, "error", err)
		return
	}
	if !info.IsDir() {
		if _, supported := mediaTypes[strings.ToLower(filepath.Ext(path))]; !supported {
			return
		}
		if !waitForStableFile(f.ctx, path) {
			f.schedule(path)
			return
		}
	}
	if err := f.app.upsertSinglePath(f.ctx, lib, path); err != nil {
		f.app.logger.Warn("index changed path", "path", path, "error", err)
	}
}

func (a *App) libraryForPath(path string) (Library, bool) {
	var selected Library
	bestLength := -1
	for _, lib := range a.cfg.Libraries {
		if !lib.Enabled || !within(lib.Path, path) {
			continue
		}
		if len(lib.Path) > bestLength {
			selected = lib
			bestLength = len(lib.Path)
		}
	}
	return selected, bestLength >= 0
}

func waitForStableFile(ctx context.Context, path string) bool {
	var previousSize int64 = -1
	var previousMod time.Time
	for attempt := 0; attempt < 5; attempt++ {
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			return false
		}
		if previousSize == info.Size() && previousMod.Equal(info.ModTime()) {
			return true
		}
		previousSize = info.Size()
		previousMod = info.ModTime()
		select {
		case <-ctx.Done():
			return false
		case <-time.After(650 * time.Millisecond):
		}
	}
	return false
}
