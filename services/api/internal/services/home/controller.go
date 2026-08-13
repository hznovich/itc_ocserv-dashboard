package home

import (
	"github.com/labstack/echo/v4"
	"github.com/mmtaee/ocserv-dashboard/api/internal/repository"
	"github.com/mmtaee/ocserv-dashboard/api/pkg/request"
	"github.com/mmtaee/ocserv-dashboard/common/models"
	"github.com/mmtaee/ocserv-dashboard/common/pkg/logger"
	"golang.org/x/sync/errgroup"
	"net/http"
)

type Controller struct {
	request        request.CustomRequestInterface
	occtlRepo      repository.OcctlRepositoryInterface
	ocservUserRepo repository.OcservUserRepositoryInterface
	reportRepo     repository.ReportRepositoryInterface
}

func New() *Controller {
	return &Controller{
		request:        request.NewCustomRequest(),
		occtlRepo:      repository.NewOcctlRepository(),
		ocservUserRepo: repository.NewtOcservUserRepository(),
		reportRepo:     repository.NewtReportRepository(),
	}
}

// Home 	     Content of home
//
// @Summary      Content of home
// @Description  Content of home
// @Tags         Home
// @Accept       json
// @Produce      json
// @Param        Authorization header string true "Bearer TOKEN"
// @Failure      400 {object} request.ErrorResponse
// @Failure      401 {object} middlewares.Unauthorized
// @Success      200  {object} GetHomeResponse
// @Router       /home [get]
//
// Implementation note:
// The previous version used a buffered error channel of size 4 with 7 goroutines —
// if more than 4 of them returned an error simultaneously, the extra senders blocked
// on `errs <- err` forever and the request never completed. We now use errgroup,
// which is the idiomatic Go pattern for "fan out N tasks, collect first error, wait
// for all". errgroup also propagates ctx cancellation if the request is aborted.
func (ctl *Controller) Home(c echo.Context) error {
	ctx := c.Request().Context()

	var (
		status           ServerStatusResponse
		statistics       *[]models.DailyTraffic
		onlineUsers      *[]models.OnlineUserSession
		totalUsers       int64
		ipBans           *[]models.IPBanPoints
		topBandwidthUser repository.TopBandwidthUsers
		totalBandwidth   repository.TotalBandwidths
	)

	g, gctx := errgroup.WithContext(ctx)

	g.Go(func() error {
		serverStatus, err := ctl.occtlRepo.Status()
		if err != nil {
			return err
		}
		if m, ok := serverStatus.(map[string]interface{}); ok {
			status = ParseServerStatus(m)
		}
		return nil
	})

	g.Go(func() error {
		data, err := ctl.reportRepo.TenDaysStats(gctx)
		if err != nil {
			return err
		}
		statistics = &data
		return nil
	})

	g.Go(func() error {
		users, err := ctl.occtlRepo.OnlineUsersInfo()
		if err != nil {
			return err
		}
		onlineUsers = users
		return nil
	})

	g.Go(func() error {
		ips, err := ctl.occtlRepo.IPBans()
		if err != nil {
			return err
		}
		ipBans = ips
		return nil
	})

	g.Go(func() error {
		users, err := ctl.reportRepo.TotalUsers(gctx)
		if err != nil {
			return err
		}
		totalUsers = users
		return nil
	})

	g.Go(func() error {
		topUser, err := ctl.reportRepo.TopBandwidthUser(gctx)
		if err != nil {
			return err
		}
		topBandwidthUser = topUser
		return nil
	})

	g.Go(func() error {
		bandwidth, err := ctl.reportRepo.TotalBandwidth(gctx)
		if err != nil {
			return err
		}
		totalBandwidth = bandwidth
		return nil
	})

	if err := g.Wait(); err != nil {
		logger.Warn("error in Home handler: %v", err)
		return ctl.request.BadRequest(c, err)
	}

	resp := GetHomeResponse{
		ServerStatus: status,
		Statistics:   statistics,
		IPBans:       ipBans,
		Users: GetHomeUser{
			Total:  totalUsers,
			Online: onlineUsers,
		},
		TopBandwidthUser: topBandwidthUser,
		TotalBandwidth:   totalBandwidth,
	}

	return c.JSON(http.StatusOK, resp)
}
