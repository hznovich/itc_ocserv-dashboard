package stats

type UserStats struct {
	Username string
	RX       int64
	TX       int64
}

type Totals struct {
	TotalRx int64
	TotalTx int64
}
