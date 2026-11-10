package inspecteur

// A thread that reads something slow for a section (the sockets of every process, systemd over D-Bus, the system's
// details) while the window's thread goes on drawing. The window asks (worker_ask); the thread runs the section's job,
// which publishes its result under the worker's mutex and sets `fresh`; the thread then wakes the window, which takes
// the result at its next turn (worker_take). One job runs at a time; asks that come while it runs make one more run.

import "core:sync"
import "core:thread"
import "gt:platform"

Worker :: struct {
	thread: ^thread.Thread,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	stop:   bool,
	asked:  bool,      // a run is wanted
	busy:   bool,      // a run is going on (the window shows that it reads)
	fresh:  bool,      // a result was published and the window has not taken it
	job:    proc(w: ^Worker),
	user:   rawptr,    // the section's state, for its job
	win:    ^platform.Window,
}

// Starts the thread; nothing runs before the first worker_ask.
worker_start :: proc(w: ^Worker, job: proc(w: ^Worker), user: rawptr, win: ^platform.Window) {
	w.job, w.user, w.win = job, user, win
	w.thread = thread.create_and_start_with_data(w, worker_run, context)
}

worker_stop :: proc(w: ^Worker) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
}

// Asks for a run. The caller sets what the job reads (under the mutex) before, when it has something to say.
worker_ask :: proc(w: ^Worker) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.asked = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
}

// Whether a run is asked or going on.
worker_busy :: proc(w: ^Worker) -> bool {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	return w.asked || w.busy
}

// True once per published result: the caller then takes it (under the mutex, with worker_lock).
worker_take :: proc(w: ^Worker) -> bool {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if !w.fresh { return false }
	w.fresh = false
	return true
}

worker_lock :: proc(w: ^Worker) { sync.mutex_lock(&w.mutex) }
worker_unlock :: proc(w: ^Worker) { sync.mutex_unlock(&w.mutex) }

// Called by a job, under no lock, with its result ready: the job takes the mutex to swap it in, then this marks it.
worker_published :: proc(w: ^Worker) {
	sync.mutex_lock(&w.mutex)
	w.fresh = true
	sync.mutex_unlock(&w.mutex)
	if w.win != nil { platform.wake(w.win) }
}

@(private = "file")
worker_run :: proc(data: rawptr) {
	w := (^Worker)(data)
	for {
		sync.mutex_lock(&w.mutex)
		for !w.asked && !w.stop { sync.cond_wait(&w.cond, &w.mutex) }
		if w.stop { sync.mutex_unlock(&w.mutex); return }
		w.asked = false
		w.busy = true
		sync.mutex_unlock(&w.mutex)
		w.job(w)
		sync.mutex_lock(&w.mutex)
		w.busy = false
		sync.mutex_unlock(&w.mutex)
		free_all(context.temp_allocator)
	}
}
