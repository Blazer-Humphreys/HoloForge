@tool
extends RefCounted
## Timing checks that hold on a busy machine: an operation is timed against a calibration of the
## same kind, in turns, keeping the fastest of several runs of each, and checked by their ratio.
## Load from other programs slows both alike, where a limit in milliseconds failed whenever the
## machine was busy; a real slowdown of the operation still moves the ratio.
##
## Test-only knobs: HOLO_FORGE_TIMING_SLOWDOWN=n runs the operation n times in each of its runs (to
## show that every limit still catches an n-fold slowdown); HOLO_FORGE_TIMING_PRINT=1 prints each
## comparison.


## Each timed run lasts at least this long (ms): a calibration of a few milliseconds fits in one slice
## of the scheduler's time, so on a busy machine it ran whole while the longer operation was cut
## off.
const SPAN := 50.0


## {"op", "calibration" (the fastest of each, ms a call), "ratio" (op / calibration)}: the two run in
## turns, rounds times each, each run calling it as many times over as makes both runs last as long
## (and at least SPAN), so load from other programs falls on both alike.
static func compare(op: Callable, calibration: Callable, rounds := 5, label := "") -> Dictionary:
	var repeat := maxi(1, int(OS.get_environment("HOLO_FORGE_TIMING_SLOWDOWN")))
	var timed := func(f: Callable, times: int) -> float:
		var started := Time.get_ticks_usec()
		for i in times:
			f.call()
		return (Time.get_ticks_usec() - started) / 1000.0
	# One call of each first: how many calls make a run.
	var op_once: float = timed.call(op, repeat)
	var calibration_once: float = timed.call(calibration, 1)
	var span := maxf(maxf(op_once, calibration_once), SPAN)
	var op_calls := clampi(ceili(span / maxf(op_once, 1e-3)), 1, 1000)
	var calibration_calls := clampi(ceili(span / maxf(calibration_once, 1e-3)), 1, 1000)
	var fastest_op := INF
	var fastest_calibration := INF
	for k in rounds:
		fastest_calibration = minf(fastest_calibration, timed.call(calibration, calibration_calls) / calibration_calls)
		fastest_op = minf(fastest_op, timed.call(op, op_calls * repeat) / op_calls)
	var ratio := fastest_op / maxf(fastest_calibration, 1e-6)
	if OS.get_environment("HOLO_FORGE_TIMING_PRINT") != "":
		print("timing %s: %.2f ms against %.2f ms, ratio %.3f (%d and %d calls a run)" % [label, fastest_op, fastest_calibration, ratio, op_calls, calibration_calls])
	return {"op": fastest_op, "calibration": fastest_calibration, "ratio": ratio}
