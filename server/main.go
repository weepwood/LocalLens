package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

var version = "0.4.0"

func main() {
	configPath := flag.String("config", "./config.json", "path to JSON config")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig(*configPath)
	if err != nil {
		logger.Error("load config", "error", err)
		os.Exit(1)
	}

	db, err := openDB(cfg.DataDir)
	if err != nil {
		logger.Error("open database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	app := newApp(cfg, db, logger)
	if err := app.syncLibraries(context.Background()); err != nil {
		logger.Error("sync libraries", "error", err)
		os.Exit(1)
	}

	recoveredThumbnails, err := app.prepareNativeImageThumbnailQueue(context.Background())
	if err != nil {
		logger.Error("prepare native image thumbnail queue", "error", err)
		os.Exit(1)
	}
	ffmpegAvailable := false
	if cfg.FFmpegPath != "" {
		if info, statErr := os.Stat(cfg.FFmpegPath); statErr == nil && !info.IsDir() {
			ffmpegAvailable = true
		}
	}
	logger.Info(
		"thumbnail engine ready",
		"nativeFormats", []string{"jpeg", "png", "gif"},
		"recoveredJobs", recoveredThumbnails,
		"ffmpegPath", cfg.FFmpegPath,
		"ffmpegAvailable", ffmpegAvailable,
	)

	// Mark the initial maintenance scan as running before workers start. Workers
	// then pause their write claims until the scan transaction has completed,
	// avoiding predictable SQLITE_BUSY warnings during startup.
	if cfg.AutoScan {
		app.startScan()
	}
	if err := app.startBackgroundWorkers(); err != nil {
		logger.Error("start background workers", "error", err)
		os.Exit(1)
	}
	app.startNativeImageThumbnailWorkers()

	if cfg.WatchFiles {
		watcher, watcherErr := newFileWatcher(app)
		if watcherErr != nil {
			logger.Warn("create filesystem watcher", "error", watcherErr)
		} else {
			app.watcher = watcher
			if watcherErr := watcher.Start(); watcherErr != nil {
				logger.Warn("start filesystem watcher", "error", watcherErr)
			}
		}
	}

	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           app.routesV022(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	go func() {
		logger.Info("server started", "address", cfg.ListenAddress, "version", version)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen", "error", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		logger.Warn("shutdown HTTP server", "error", err)
	}
	app.stopBackgroundServices()
}
