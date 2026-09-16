// Reference widget for the two-clock contract.
//
// `refreshFrequency` is the DATA cadence: how often the shell command runs.
// `animate(state, dtMs)` is the MOTION cadence, stepped on a loop shared with
// every other animating widget on the page and parked when nothing is moving.

export const command = 'ps -A -o %cpu | awk \'{s+=$1} END {print s}\'';

// Data: once every 5 seconds. This is a real measurement; it does not need to
// be taken more often than it changes meaningfully.
export const refreshFrequency = 5000;

// Motion: 30 times a second, and only while the bar is actually moving.
export const animationFrequency = 30;

export const initialState = {target: 0, shown: 0};

export const updateState = (event, previous) => {
  if (event.error) return {...previous, error: event.error};
  const target = Math.min(100, parseFloat(event.output) || 0);
  return {...previous, error: null, target};
};

// Called with the time actually elapsed since this widget's last step. Return
// the next state to keep animating, or undefined once you have settled --
// returning undefined is what lets the shared loop park and stop waking the
// CPU. Never re-read data here; that is what `command` is for.
export const animate = (state, dtMs) => {
  const distance = state.target - state.shown;
  if (Math.abs(distance) < 0.05) return undefined;

  // Ease toward the target at a rate independent of frame timing, so the
  // motion looks the same whether frames arrive at 30Hz or 120Hz.
  const step = distance * Math.min(1, dtMs / 250);
  return {...state, shown: state.shown + step};
};

export const className = `
  left: 20px;
  top: 20px;
  font-family: -apple-system, Helvetica Neue, sans-serif;
  color: #fff;
  width: 220px;
`;

export const render = ({shown, error}) => {
  if (error) return <div>{String(error)}</div>;

  return (
    <div>
      <div style={{fontSize: 11, opacity: 0.7, letterSpacing: '0.08em'}}>
        CPU {shown.toFixed(1)}%
      </div>
      <div
        style={{
          height: 6,
          marginTop: 6,
          background: 'rgba(255,255,255,0.15)',
          borderRadius: 3,
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            height: '100%',
            width: `${shown}%`,
            background: '#5FC2D6',
            borderRadius: 3,
          }}
        />
      </div>
    </div>
  );
};
