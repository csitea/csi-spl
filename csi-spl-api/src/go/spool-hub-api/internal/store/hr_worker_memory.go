package store

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"sync"
	"time"
)

// The Memory driver's rdb 0286 rows beside the store.
var (
	memHRWorkerMu    sync.Mutex
	memHRWorkerRates = map[*Memory]map[string][]HRWorkerRate{}
	memHRTaxCards    = map[*Memory]map[string]HRTaxCard{}
	memHRPayslips    = map[*Memory]map[string]HRPayslip{}
)

func hrWorkerRateKey(year int, kind string) string { return fmt.Sprintf("%04d/%s", year, kind) }

func hrTaxCardKey(personID string, year int) string { return fmt.Sprintf("%s/%04d", personID, year) }

func hrPayslipKey(personID, month, currency string) string {
	return personID + "/" + month + "/" + currency
}

// ListHRWorkerRates is HRWorkerStore on Memory.
func (s *Memory) ListHRWorkerRates(_ context.Context, year int) ([]HRWorkerRate, error) {
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	out := []HRWorkerRate{}
	for _, kind := range HRWorkerKinds {
		out = append(out, memHRWorkerRates[s][hrWorkerRateKey(year, kind)]...)
	}
	return out, nil
}

// SetHRWorkerRates is HRWorkerStore on Memory.
func (s *Memory) SetHRWorkerRates(_ context.Context, year int, kind string, bands []HRWorkerRate) ([]HRWorkerRate, error) {
	if why := CheckHRWorkerRates(year, kind, bands); why != "" {
		return nil, fmt.Errorf("hr worker rates: %s", why)
	}
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	if memHRWorkerRates[s] == nil {
		memHRWorkerRates[s] = map[string][]HRWorkerRate{}
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	out := make([]HRWorkerRate, 0, len(bands))
	for _, b := range bands {
		b.SetAt = now
		out = append(out, b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AgeFrom < out[j].AgeFrom })
	if len(out) == 0 {
		delete(memHRWorkerRates[s], hrWorkerRateKey(year, kind))
	} else {
		memHRWorkerRates[s][hrWorkerRateKey(year, kind)] = out
	}
	return slices.Clone(out), nil
}

// ListHRTaxCards is HRWorkerStore on Memory.
func (s *Memory) ListHRTaxCards(_ context.Context, year int) ([]HRTaxCard, error) {
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	out := []HRTaxCard{}
	for _, c := range memHRTaxCards[s] {
		if c.Year == year {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].PersonID < out[j].PersonID })
	return out, nil
}

// SetHRTaxCard is HRWorkerStore on Memory.
func (s *Memory) SetHRTaxCard(_ context.Context, c HRTaxCard) (HRTaxCard, error) {
	if why := CheckHRTaxCard(c); why != "" {
		return HRTaxCard{}, fmt.Errorf("hr tax card: %s", why)
	}
	if !memHRPersonExists(s, c.PersonID) {
		return HRTaxCard{}, ErrNotFound
	}
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	if memHRTaxCards[s] == nil {
		memHRTaxCards[s] = map[string]HRTaxCard{}
	}
	c.SetAt = time.Now().UTC().Truncate(time.Microsecond)
	memHRTaxCards[s][hrTaxCardKey(c.PersonID, c.Year)] = c
	return c, nil
}

// DeleteHRTaxCard is HRWorkerStore on Memory.
func (s *Memory) DeleteHRTaxCard(_ context.Context, personID string, year int) error {
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	k := hrTaxCardKey(personID, year)
	if _, ok := memHRTaxCards[s][k]; !ok {
		return ErrNotFound
	}
	delete(memHRTaxCards[s], k)
	return nil
}

// ListHRPayslips is HRWorkerStore on Memory.
func (s *Memory) ListHRPayslips(_ context.Context, month string) ([]HRPayslip, error) {
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	out := []HRPayslip{}
	for _, p := range memHRPayslips[s] {
		if p.Month == month {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].PersonID != out[j].PersonID {
			return out[i].PersonID < out[j].PersonID
		}
		return out[i].Currency < out[j].Currency
	})
	return out, nil
}

// SetHRPayslip is HRWorkerStore on Memory.
func (s *Memory) SetHRPayslip(_ context.Context, p HRPayslip) (HRPayslip, error) {
	if why := CheckHRPayslip(p); why != "" {
		return HRPayslip{}, fmt.Errorf("hr payslip: %s", why)
	}
	if !memHRPersonExists(s, p.PersonID) {
		return HRPayslip{}, ErrNotFound
	}
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	if memHRPayslips[s] == nil {
		memHRPayslips[s] = map[string]HRPayslip{}
	}
	p.SetAt = time.Now().UTC().Truncate(time.Microsecond)
	memHRPayslips[s][hrPayslipKey(p.PersonID, p.Month, p.Currency)] = p
	return p, nil
}

// DeleteHRPayslip is HRWorkerStore on Memory.
func (s *Memory) DeleteHRPayslip(_ context.Context, personID, month, currency string) error {
	memHRWorkerMu.Lock()
	defer memHRWorkerMu.Unlock()
	k := hrPayslipKey(personID, month, currency)
	if _, ok := memHRPayslips[s][k]; !ok {
		return ErrNotFound
	}
	delete(memHRPayslips[s], k)
	return nil
}

var _ HRWorkerStore = (*Memory)(nil)
