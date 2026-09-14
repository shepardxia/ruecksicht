'use strict';

// Every other action the reducer handles arrives as JSON from the daemon; only
// the client mints this one, once a widget bundle has finished loading.

exports.showWidget = function showWidget(id, impl) {
  return {
    type: 'WIDGET_LOADED',
    id: id,
    payload: impl,
  };
};
