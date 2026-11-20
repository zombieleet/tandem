// p.go: a tour of Go concurrency patterns, all running at once.
//
//	go run -race p.go
package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 1. Concurrent prime sieve: a daisy chain of goroutines, one filter per prime.
func sieve(ctx context.Context, n int) []int {
	gen := func() <-chan int {
		ch := make(chan int)
		go func() {
			defer close(ch)
			for i := 2; ; i++ {
				select {
				case ch <- i:
				case <-ctx.Done():
					return
				}
			}
		}()
		return ch
	}
	filter := func(in <-chan int, p int) <-chan int {
		out := make(chan int)
		go func() {
			defer close(out)
			for v := range in {
				if v%p != 0 {
					select {
					case out <- v:
					case <-ctx.Done():
						return
					}
				}
			}
		}()
		return out
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel() // tears down the whole chain when we're done
	ch := gen()
	primes := make([]int, 0, n)
	for range n {
		p := <-ch
		primes = append(primes, p)
		ch = filter(ch, p)
	}
	return primes
}

// 2. Pipeline with fan-out / fan-in.
func pipeline(ctx context.Context, n, workers int) int {
	src := make(chan int)
	go func() {
		defer close(src)
		for i := range n {
			select {
			case src <- i:
			case <-ctx.Done():
				return
			}
		}
	}()

	// Fan out: several squarers read from the same channel.
	outs := make([]<-chan int, workers)
	for w := range workers {
		out := make(chan int)
		outs[w] = out
		go func() {
			defer close(out)
			for v := range src {
				time.Sleep(time.Duration(rand.IntN(200)) * time.Microsecond)
				select {
				case out <- v * v:
				case <-ctx.Done():
					return
				}
			}
		}()
	}

	// Fan in: merge every worker's output into one channel.
	merged := make(chan int)
	var wg sync.WaitGroup
	for _, c := range outs {
		wg.Go(func() {
			for v := range c {
				merged <- v
			}
		})
	}
	go func() { wg.Wait(); close(merged) }()

	sum := 0
	for v := range merged {
		sum += v
	}
	return sum
}

// 3. Bounded worker pool: a semaphore caps parallelism, the first error cancels the rest.
func pool(ctx context.Context, jobs, limit int) (done int64, peak int64, err error) {
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)

	sem := make(chan struct{}, limit)
	var inflight atomic.Int64
	var completed atomic.Int64
	var wg sync.WaitGroup

	for i := range jobs {
		select {
		case sem <- struct{}{}:
		case <-ctx.Done():
		}
		if ctx.Err() != nil {
			break
		}
		wg.Go(func() {
			defer func() { <-sem }()
			cur := inflight.Add(1)
			defer inflight.Add(-1)
			for {
				old := atomic.LoadInt64(&peak)
				if cur <= old || atomic.CompareAndSwapInt64(&peak, old, cur) {
					break
				}
			}
			select {
			case <-time.After(time.Duration(rand.IntN(3)+1) * time.Millisecond):
			case <-ctx.Done():
				return
			}
			if i == 37 {
				cancel(fmt.Errorf("job %d exploded", i))
				return
			}
			completed.Add(1)
		})
	}
	wg.Wait()
	return completed.Load(), atomic.LoadInt64(&peak), context.Cause(ctx)
}

// 4. Dining philosophers: always grab the lower-numbered fork first, so no deadlock.
func philosophers(n, meals int) []int {
	forks := make([]sync.Mutex, n)
	eaten := make([]int, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Go(func() {
			a, b := i, (i+1)%n
			if a > b {
				a, b = b, a
			}
			for range meals {
				forks[a].Lock()
				forks[b].Lock()
				eaten[i]++ // each philosopher owns its own slot, so no race
				time.Sleep(50 * time.Microsecond)
				forks[b].Unlock()
				forks[a].Unlock()
			}
		})
	}
	wg.Wait()
	return eaten
}

// 5. Broadcaster: fan one stream to many subscribers; slow ones drop messages instead of blocking.
type broadcaster struct {
	mu   sync.RWMutex
	subs []chan int
}

func (b *broadcaster) subscribe(buf int) <-chan int {
	ch := make(chan int, buf)
	b.mu.Lock()
	b.subs = append(b.subs, ch)
	b.mu.Unlock()
	return ch
}

func (b *broadcaster) publish(v int) (dropped int) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for _, s := range b.subs {
		select {
		case s <- v:
		default:
			dropped++
		}
	}
	return dropped
}

func (b *broadcaster) close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, s := range b.subs {
		close(s)
	}
}

func broadcast(msgs int) (fast, slow, dropped int) {
	b := &broadcaster{}
	fastCh, slowCh := b.subscribe(msgs), b.subscribe(2)
	var wg sync.WaitGroup
	wg.Go(func() {
		for range fastCh {
			fast++
		}
	})
	wg.Go(func() {
		for range slowCh {
			slow++
			time.Sleep(time.Millisecond)
		}
	})
	for i := range msgs {
		dropped += b.publish(i)
	}
	b.close()
	wg.Wait()
	return
}

// 6. Hedged requests: ask several replicas, take the first answer, cancel the losers.
func hedged(ctx context.Context, replicas int) (string, int32) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	res := make(chan string, replicas) // buffered so losers never block
	var cancelled atomic.Int32
	var wg sync.WaitGroup
	for r := range replicas {
		wg.Go(func() {
			select {
			case <-time.After(time.Duration(rand.IntN(20)+1) * time.Millisecond):
				res <- fmt.Sprintf("replica-%d", r)
			case <-ctx.Done():
				cancelled.Add(1)
			}
		})
	}
	winner := <-res
	cancel()
	wg.Wait()
	return winner, cancelled.Load()
}

// 7. Reusable barrier built on sync.Cond: nobody starts phase k+1 until everyone has finished phase k.
type barrier struct {
	mu    sync.Mutex
	cond  *sync.Cond
	n     int
	count int
	gen   int
}

func newBarrier(n int) *barrier {
	b := &barrier{n: n}
	b.cond = sync.NewCond(&b.mu)
	return b
}

func (b *barrier) await() {
	b.mu.Lock()
	defer b.mu.Unlock()
	gen := b.gen
	b.count++
	if b.count == b.n {
		b.count = 0
		b.gen++
		b.cond.Broadcast()
		return
	}
	for gen == b.gen {
		b.cond.Wait()
	}
}

func phases(workers, rounds int) string {
	b := newBarrier(workers)
	var mu sync.Mutex
	var log strings.Builder
	var wg sync.WaitGroup
	for range workers {
		wg.Go(func() {
			for r := range rounds {
				time.Sleep(time.Duration(rand.IntN(500)) * time.Microsecond)
				mu.Lock()
				fmt.Fprintf(&log, "%d", r) // every digit r appears before any r+1
				mu.Unlock()
				b.await()
			}
		})
	}
	wg.Wait()
	return log.String()
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()

	// Run every demo at the same time, because why not.
	type result struct {
		name string
		out  string
	}
	results := make(chan result)
	demos := map[string]func() string{
		"sieve": func() string {
			return fmt.Sprint(sieve(ctx, 25))
		},
		"pipeline": func() string {
			got, want := pipeline(ctx, 1000, 8), 0
			for i := range 1000 {
				want += i * i
			}
			return fmt.Sprintf("sum of squares 0..999 = %d (correct: %v)", got, got == want)
		},
		"pool": func() string {
			done, peak, err := pool(ctx, 100, 6)
			return fmt.Sprintf("completed=%d peak_parallel=%d err=%v is_cancel=%v",
				done, peak, err, errors.Is(err, context.Canceled))
		},
		"philosophers": func() string {
			return fmt.Sprintf("meals eaten %v, no deadlock", philosophers(5, 100))
		},
		"broadcast": func() string {
			f, s, d := broadcast(200)
			return fmt.Sprintf("fast got %d, slow got %d, dropped %d", f, s, d)
		},
		"hedged": func() string {
			w, c := hedged(ctx, 10)
			return fmt.Sprintf("winner=%s, losers cancelled=%d", w, c)
		},
		"barrier": func() string {
			return phases(4, 5)
		},
	}
	for name, fn := range demos {
		go func() { results <- result{name, fn()} }()
	}
	for range len(demos) {
		r := <-results
		fmt.Printf("%-13s %s\n", r.name+":", r.out)
	}
	fmt.Printf("\nall done in %v\n", time.Since(start).Round(time.Millisecond))
}
