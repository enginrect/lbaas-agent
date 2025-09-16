package executor

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"time"
)

type Executor interface {
	Run(ctx context.Context, argv []string) (string, error)
}

type SubprocessExecutor struct{}

func (SubprocessExecutor) Run(ctx context.Context, argv []string) (string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", errors.New(errb.String())
	}
	return out.String(), nil
}

// Helper to create a timeout context
func WithTimeout(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}
