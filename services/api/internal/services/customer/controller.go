package customer

import (
	"crypto/subtle"
	"errors"
	"github.com/labstack/echo/v4"
	"github.com/mmtaee/ocserv-dashboard/api/internal/repository"
	"github.com/mmtaee/ocserv-dashboard/api/pkg/request"
	"github.com/mmtaee/ocserv-dashboard/common/pkg/logger"
	"net/http"
	"strconv"
	"time"
)

type Controller struct {
	request        request.CustomRequestInterface
	ocservUserRepo repository.OcservUserRepositoryInterface
	occtl          repository.OcctlRepositoryInterface
}

func New() *Controller {
	return &Controller{
		request:        request.NewCustomRequest(),
		ocservUserRepo: repository.NewtOcservUserRepository(),
		occtl:          repository.NewOcctlRepository(),
	}
}

// errInvalidCreds is the *only* user-visible authentication error this package
// returns. We deliberately do not distinguish between "user not found" and
// "password mismatch" — exposing that difference (as the previous version did)
// lets an attacker enumerate valid usernames at the rate-limit's pace.
var errInvalidCreds = errors.New("invalid username or password")

// authenticate validates a customer credential pair against the ocserv user table.
//
// Security properties:
//   - Returns the same error (errInvalidCreds) whether the user does not exist
//     or the password is wrong, eliminating username enumeration.
//   - Uses crypto/subtle.ConstantTimeCompare so request timing does not leak
//     password content. (Note: ocpasswd values are stored in plaintext as
//     required by ocserv, but we still avoid leaking partial-match timing.)
//   - Always performs a compare even when the user does not exist, against a
//     fixed dummy string of the same byte-length as the input password — so
//     "user not found" doesn't return materially faster than "wrong password".
//   - Rejects the placeholder password "Secret-Ocpasswd" used by the ocpasswd
//     bulk-sync flow, so synced-but-not-yet-set users cannot log in.
func (ctl *Controller) authenticate(c echo.Context, username, password string) (*okUser, error) {
	if password == "" || password == "Secret-Ocpasswd" {
		// Run a dummy compare for timing-uniformity, then bail.
		_ = subtle.ConstantTimeCompare([]byte("dummy-password-value"), []byte("dummy-password-value"))
		return nil, errInvalidCreds
	}

	user, err := ctl.ocservUserRepo.GetByUsername(c.Request().Context(), username)
	if err != nil || user == nil {
		// Equalize timing with the success path: do a constant-time compare
		// against a fixed string of length matching the request, then return
		// the same generic error.
		dummy := make([]byte, len(password))
		_ = subtle.ConstantTimeCompare(dummy, []byte(password))
		return nil, errInvalidCreds
	}

	if user.IsLocked {
		// Locked accounts are not allowed to use the customer endpoints.
		// Same generic error message — do not leak lock state.
		return nil, errInvalidCreds
	}

	stored := []byte(user.Password)
	provided := []byte(password)

	// ConstantTimeCompare returns 1 only if both slices are equal AND have the
	// same length. To avoid an early-out length mismatch leaking length info,
	// we pad the shorter slice up to max(len(a), len(b)) before comparing.
	maxLen := len(stored)
	if len(provided) > maxLen {
		maxLen = len(provided)
	}
	a := make([]byte, maxLen)
	b := make([]byte, maxLen)
	copy(a, stored)
	copy(b, provided)
	if subtle.ConstantTimeCompare(a, b) != 1 || len(stored) != len(provided) {
		return nil, errInvalidCreds
	}

	return &okUser{
		ID:            user.ID,
		Owner:         user.Owner,
		Username:      user.Username,
		IsLocked:      user.IsLocked,
		ExpireAt:      user.ExpireAt,
		DeactivatedAt: user.DeactivatedAt,
		TrafficType:   user.TrafficType,
		TrafficSize:   user.TrafficSize,
		Rx:            user.Rx,
		Tx:            user.Tx,
	}, nil
}

// okUser is a denormalised view of OcservUser tailored for the customer-facing
// response. Notably it does not carry the Password field.
type okUser struct {
	ID            uint
	Owner         string
	Username      string
	IsLocked      bool
	ExpireAt      *time.Time
	DeactivatedAt *time.Time
	TrafficType   string
	TrafficSize   int64
	Rx            int64
	Tx            int64
}

// Summary 	     Customer summary account
//
// @Summary      Customer summary account
// @Description  Customer summary account
// @Tags         Customers
// @Accept       json
// @Produce      json
// @Param        request body  SummaryData  true "customer username and password (same ocserv account)."
// @Failure      400 {object} request.ErrorResponse
// @Failure      429 {object} middlewares.TooManyRequests
// @Success      200  {object} SummaryResponse
// @Router       /customers/summary [post]
func (ctl *Controller) Summary(c echo.Context) error {
	var data SummaryData

	if err := ctl.request.DoValidate(c, &data); err != nil {
		return ctl.request.BadRequest(c, err)
	}

	user, err := ctl.authenticate(c, data.Username, data.Password)
	if err != nil {
		return ctl.request.BadRequest(c, err)
	}

	dateEnd := time.Now()
	firstOfThisMonth := time.Date(dateEnd.Year(), dateEnd.Month(), 1, 0, 0, 0, 0, dateEnd.Location())
	dateStart := firstOfThisMonth.AddDate(0, -1, 0)

	usage, err := ctl.ocservUserRepo.TotalBandwidthUserDateRange(
		c.Request().Context(),
		strconv.Itoa(int(user.ID)),
		&dateStart,
		&dateEnd,
	)
	if err != nil {
		logger.Warn("customer summary bandwidth lookup failed: %v", err)
		return ctl.request.BadRequest(c, errors.New("bandwidth lookup failed"))
	}

	return c.JSON(http.StatusOK, SummaryResponse{
		OcservUser: ModelCustomer{
			Owner:         user.Owner,
			Username:      user.Username,
			IsLocked:      user.IsLocked,
			ExpireAt:      user.ExpireAt,
			DeactivatedAt: user.DeactivatedAt,
			TrafficType:   user.TrafficType,
			TrafficSize:   user.TrafficSize,
			Rx:            user.Rx,
			Tx:            user.Tx,
		},
		Usage: UsageResponse{
			DateStart:  dateStart,
			DateEnd:    dateEnd,
			Bandwidths: usage,
		},
	})
}

// DisconnectSessions
//
// @Summary      Disconnect all online sessions of a customer
// @Description  disconnects all online sessions for a customer
// @Tags         Customers
// @Accept       json
// @Produce      json
// @Param        request body  SummaryData  true "customer username and password (same ocserv account)."
// @Failure      400 {object} request.ErrorResponse
// @Failure      429 {object} middlewares.TooManyRequests
// @Success      202  {object} nil
// @Router       /customers/disconnect_sessions [post]
func (ctl *Controller) DisconnectSessions(c echo.Context) error {
	var data SummaryData

	if err := ctl.request.DoValidate(c, &data); err != nil {
		return ctl.request.BadRequest(c, err)
	}

	user, err := ctl.authenticate(c, data.Username, data.Password)
	if err != nil {
		return ctl.request.BadRequest(c, err)
	}

	_, _ = ctl.occtl.Disconnect(user.Username)

	return c.JSON(http.StatusAccepted, nil)
}
