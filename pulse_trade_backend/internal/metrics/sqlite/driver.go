package sqlite

import (
	"context"
	"fmt"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// init registers the driver so metrics.Open can select it by name without the
// parent package importing this one. Without that (and the reverse import it
// would create), metrics could not declare Repository in the same package that
// the memory driver implements.
func init() {
	metrics.RegisterDriver(DriverName, func(ctx context.Context, cfg metrics.Config, logger *observability.Logger) (metrics.Repository, error) {
		repo, err := Open(ctx, cfg.DSN)
		if err != nil {
			return nil, fmt.Errorf("metrics: open sqlite repository: %w", err)
		}
		return repo, nil
	})
}
