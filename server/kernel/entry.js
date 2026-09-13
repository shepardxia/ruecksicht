// Bundled to a standalone script and evaluated in JavaScriptCore, so the
// CoffeeScript and classic-widget transforms run without a Node runtime.
//
// Built by `npm run build-kernel`. Nothing here may reach for a filesystem,
// a process or a module loader at call time; the shims under ./shims stand in
// for the ones stylus and coffee-script expect at load time.

const transformWidget = require('../src/transformWidget');

globalThis.__ubTransform = transformWidget;
