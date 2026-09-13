'use strict';

// One animation clock per page, shared by every animating widget on it.
//
// Widgets declare `animate(state, dtMs)` and an optional `animationFrequency`;
// this steps them together on a single rAF-driven loop instead of each widget
// owning a timer. Two properties matter and are easy to lose:
//
// Frames are throttled to the highest frequency any participant asked for, not
// to the display. Driving raw rAF on a 120Hz panel would quadruple the frame
// rate against a 30Hz default and call it an optimization.
//
// The loop stops when nothing is animating, and rAF stops on its own when the
// page is hidden or occluded, which is the parking behaviour the scheduler
// wants -- a `setInterval` fallback would keep running behind a fullscreen
// window, so it is used only where rAF is unavailable.

const DEFAULT_FREQUENCY = 30;
const IDLE_STEPS_BEFORE_PARK = 60;

module.exports = function AnimationLoop(scheduler) {
  const raf =
    (scheduler && scheduler.request) ||
    (typeof requestAnimationFrame === 'function'
      ? requestAnimationFrame
      : (cb) => setTimeout(() => cb(Date.now()), 16));

  const participants = new Map();
  let running = false;
  let lastStepAt = null;

  function step(now) {
    if (!participants.size) {
      running = false;
      lastStepAt = null;
      return;
    }

    if (lastStepAt === null) lastStepAt = now;
    const dt = now - lastStepAt;
    lastStepAt = now;

    // Each participant accumulates elapsed time and fires on its own interval.
    // Gating the whole loop on the fastest interval instead would stall every
    // widget whenever frames arrive marginally faster than it: a 60Hz widget on
    // 16ms frames would never reach 16.67ms and would never step at all.
    participants.forEach((p, id) => {
      p.sinceStep += dt;
      if (p.sinceStep + 1e-9 < 1000 / p.frequency) return;
      const elapsed = p.sinceStep;
      p.sinceStep = 0;
      let next;
      try {
        next = p.animate(elapsed);
      } catch (err) {
        participants.delete(id);
        p.onError(err);
        return;
      }
      // A widget that keeps returning nothing has settled; parking it stops
      // the loop entirely once every participant has settled.
      if (next === undefined) {
        p.idleSteps += 1;
        if (p.idleSteps >= IDLE_STEPS_BEFORE_PARK) participants.delete(id);
      } else {
        p.idleSteps = 0;
      }
    });

    raf(step);
  }

  function start() {
    if (running) return;
    running = true;
    lastStepAt = null;
    raf(step);
  }

  return {
    add(id, animate, frequency, onError) {
      participants.set(id, {
        animate: animate,
        frequency: frequency > 0 ? frequency : DEFAULT_FREQUENCY,
        idleSteps: 0,
        sinceStep: 0,
        onError: onError || function () {},
      });
      start();
    },

    remove(id) {
      participants.delete(id);
    },

    // A widget that parked after settling has to be revived when new data
    // arrives, or a data-driven animation never restarts.
    wake(id) {
      const p = participants.get(id);
      if (p) {
        p.idleSteps = 0;
        start();
      }
    },

    has(id) {
      return participants.has(id);
    },

    size() {
      return participants.size;
    },

    running() {
      return running;
    },
  };
};

module.exports.DEFAULT_FREQUENCY = DEFAULT_FREQUENCY;
module.exports.IDLE_STEPS_BEFORE_PARK = IDLE_STEPS_BEFORE_PARK;
