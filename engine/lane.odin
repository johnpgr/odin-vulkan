package engine

import "core:sync"
import "core:thread"

MAX_LANES :: 4

@(thread_local)
lane_idx: int

@(private)
num_lanes: int

@(private)
lane_barrier: sync.Barrier

Lane_Range :: struct {
	min, max: int,
}

lane_idx :: #force_inline proc() -> int {
	return lane_idx
}

lane_count :: proc() -> int {
	return num_lanes
}

lane_range :: proc(total: int) -> Lane_Range {
	n := num_lanes
	idx := lane_idx
	chunk := total / n
	rem := total % n
	lo := idx * chunk + min(idx, rem)
	hi := lo + chunk + (1 if idx < rem else 0)
	return Lane_Range{min = lo, max = hi}
}

lane_sync :: proc() {
	sync.barrier_wait(&lane_barrier)
}

lane_init :: proc(n: int) {
	num_lanes = n
	sync.barrier_init(&lane_barrier, n)
}

@(private)
engine_thread_proc :: proc(t: ^thread.Thread) {
	lane_idx = t.user_index
	e := cast(^Engine)t.data
	run_main_loop(e)
}
