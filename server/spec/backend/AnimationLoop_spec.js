var test = require('tape');

var AnimationLoop = require('../../src/AnimationLoop');

// A hand-cranked clock standing in for requestAnimationFrame, so frame pacing
// is asserted rather than waited on.
function fakeClock() {
  var queued = [];
  var now = 0;
  return {
    request: function (cb) {
      queued.push(cb);
    },
    advance: function (ms) {
      now += ms;
      var due = queued;
      queued = [];
      due.forEach(function (cb) {
        cb(now);
      });
    },
    pending: function () {
      return queued.length;
    },
  };
}

test('it steps participants at their declared frequency', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);
  var steps = 0;

  loop.add('w', function () {
    steps += 1;
    return {n: steps};
  }, 10);

  // 10Hz is one step per 100ms of accumulated time, however often frames land.
  for (var i = 0; i < 10; i++) clock.advance(16);
  t.equal(steps, 1, 'a 160ms span at 10Hz produced one step, not ten');

  for (var j = 0; j < 20; j++) clock.advance(16);
  t.ok(steps >= 3 && steps <= 5, 'it tracks its own interval, not the frame rate');
  t.end();
});

test('it does not drive faster than the fastest participant asks', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);
  var slow = 0;
  var fast = 0;

  loop.add('slow', function () { slow += 1; return {}; }, 10);
  loop.add('fast', function () { fast += 1; return {}; }, 30);

  for (var i = 0; i < 60; i++) clock.advance(16);

  t.ok(fast > slow, 'the faster widget steps more often');
  t.ok(slow <= 12, 'the slow widget is not dragged up to the fast one');
  t.end();
});

test('a settled widget parks, and the loop stops when all have', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);

  loop.add('w', function () {
    return undefined;
  }, 60);

  t.ok(loop.running(), 'it starts running');

  for (var i = 0; i < AnimationLoop.IDLE_STEPS_BEFORE_PARK * 3; i++) {
    if (loop.size() === 0) break;
    clock.advance(16);
  }

  t.equal(loop.size(), 0, 'the settled widget parked itself');

  clock.advance(16);
  t.equal(clock.pending(), 0, 'the loop stopped scheduling frames');
  t.end();
});

test('new data wakes a parked widget', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);
  var moving = false;

  loop.add('w', function () {
    return moving ? {} : undefined;
  }, 60);

  for (var i = 0; i < AnimationLoop.IDLE_STEPS_BEFORE_PARK * 3; i++) {
    if (loop.size() === 0) break;
    clock.advance(16);
  }
  t.equal(loop.size(), 0, 'it parked while idle');

  // wake() only revives a widget still registered; a parked one is re-added.
  loop.add('w', function () { return {}; }, 60);
  moving = true;
  loop.wake('w');
  clock.advance(16);
  t.ok(loop.running(), 'it is running again');
  t.equal(loop.size(), 1, 'the widget is animating again');
  t.end();
});

test('a throwing widget is removed and reported, not left spinning', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);
  var caught = null;

  loop.add(
    'bad',
    function () {
      throw new Error('boom');
    },
    60,
    function (err) {
      caught = err;
    },
  );

  for (var i = 0; i < 6; i++) clock.advance(16);

  t.ok(caught && caught.message === 'boom', 'the error reached the handler');
  t.equal(loop.size(), 0, 'the widget was removed');
  t.end();
});

test('removing a widget stops stepping it', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);
  var steps = 0;

  loop.add('w', function () { steps += 1; return {}; }, 60);
  for (var k = 0; k < 6; k++) clock.advance(20);
  var before = steps;

  loop.remove('w');
  clock.advance(20);
  clock.advance(20);

  t.equal(steps, before, 'it stopped being stepped');
  t.equal(loop.size(), 0, 'and is gone from the loop');
  t.end();
});

test('the dt handed to a widget reflects real elapsed time', function (t) {
  var clock = fakeClock();
  var loop = AnimationLoop(clock);
  var seen = [];

  loop.add('w', function (dt) {
    seen.push(dt);
    return {};
  }, 20);

  for (var i = 0; i < 12; i++) clock.advance(25);

  t.ok(seen.length > 0, 'it stepped');
  t.ok(
    seen.every(function (dt) {
      return dt >= 50 - 1e-6;
    }),
    'each dt covers at least the 50ms the 20Hz widget waited',
  );
  t.end();
});
