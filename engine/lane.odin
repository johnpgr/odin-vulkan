package engine

import "core:sync"
import "core:thread"

MAX_LANES :: 4

@(thread_local)
_lane_idx: int

@(private)
_num_lanes: int

@(private)
_lane_barrier: sync.Barrier

Lane_Range :: struct {
	min, max: int,
}

lane_idx :: #force_inline proc() -> int {
	return _lane_idx
}

lane_count :: proc() -> int {
	return _num_lanes
}

lane_range :: proc(total: int) -> Lane_Range {
	n := _num_lanes
	idx := _lane_idx
	chunk := total / n
	rem := total % n
	lo := idx * chunk + min(idx, rem)
	hi := lo + chunk + (1 if idx < rem else 0)
	return Lane_Range{min = lo, max = hi}
}

lane_sync :: proc() {
	sync.barrier_wait(&_lane_barrier)
}

lane_init :: proc(n: int) {
	_num_lanes = n
	sync.barrier_init(&_lane_barrier, n)
}

@(private)
engine_thread_proc :: proc(t: ^thread.Thread) {
	_lane_idx = t.user_index
	e := cast(^Engine)t.data
	run_main_loop(e)
}
