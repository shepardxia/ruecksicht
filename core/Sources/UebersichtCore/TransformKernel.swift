import Foundation
import JavaScriptCore

/// Runs the CoffeeScript compiler and the classic-widget rewrite.
///
/// Both are JavaScript and have no native equivalent, so they are hosted in
/// JavaScriptCore, which ships with the OS. This is why serving widgets needs
/// no Node runtime even though two of the three widget languages are compiled
/// by JavaScript.
public final class TransformKernel {
    private let context = JSContext()!
    private let lock = NSLock()

    public enum KernelError: Error {
        case kernelMissing
        case kernelFailed(String)
        case transformFailed(String)
    }

    public init() throws {
        guard
            let url = Bundle.module.url(forResource: "transform-kernel", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw KernelError.kernelMissing }

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown JavaScript error"
        }
        // The bundled compilers still reach for Node's globals; JSC has none.
        context.evaluateScript(
            """
            var global = globalThis;
            var process = {
                env: {NODE_ENV: 'production'},
                platform: 'darwin',
                argv: [],
                cwd: function () { return '/'; },
                nextTick: function (fn) { fn(); }
            };
            """
        )
        context.evaluateScript(source)
        if let thrown { throw KernelError.kernelFailed(thrown) }
    }

    /// Compiles a widget's source to the JavaScript esbuild will bundle.
    public func transform(source: String, id: String, isCoffee: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown JavaScript error"
        }

        guard let function = context.objectForKeyedSubscript("__ubTransform") else {
            throw KernelError.transformFailed("kernel did not define __ubTransform")
        }
        let result = function.call(withArguments: [source, id, isCoffee])

        if let thrown { throw KernelError.transformFailed(thrown) }
        guard let output = result?.toString(), !output.isEmpty else {
            throw KernelError.transformFailed("transform produced nothing")
        }
        return output
    }
}
