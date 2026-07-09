// CoreAIGraphRunner — a thin wrapper over a stateless Core AI `.aimodel` graph: load once,
// run flat Float tensors in, get flat Float tensors out.
//
// Built directly on the SYSTEM `CoreAI` framework (macOS/iOS 27) — `AIModel` /
// `SpecializationOptions` / `NDArray` / `InferenceFunction` are all public there; no external
// package is needed. The NDArray marshaling follows the public-API usage of
// apple/coreai-models and the coreai-kit `GraphModel` (BSD-3-Clause).
//
// ⚠️ Load caveat (verified 2026-07-09 on macOS 26A5378j / Xcode 27A5218g): the community
// `sortformer_float16.aimodel` published on HF was exported against an earlier Core AI
// toolchain and its MLIR fails the current runtime's IR versioner during specialization with
// a *fatal, uncatchable* `LLVM ERROR: cannot unwrap empty odiec_module_t`. This aborts the
// process, so callers MUST NOT attempt to load it as a fallible probe — gate the load behind
// an explicit opt-in (a re-exported / AOT-compiled model, or an env flag a human sets when the
// model is known-loadable). `AIModelAsset.summary()` succeeds (the bundle is intact); only
// specialization aborts. The unblock is a re-export against the current toolchain.

import Foundation

/// A flat, host-side tensor: row-major Float values plus their shape.
public struct GraphTensor: Sendable, Equatable {
    public let values: [Float]
    public let shape: [Int]

    public init(values: [Float], shape: [Int]) {
        self.values = values
        self.shape = shape
    }
}

/// The graph seam: named Float tensors in, named Float tensors out. `CoreAIGraphRunner` is the
/// real implementation; tests inject a fake to exercise the streaming/AOSC math without the model.
public protocol GraphRunner: Sendable {
    var inputNames: [String] { get }
    var outputNames: [String] { get }
    func run(_ inputs: [String: GraphTensor]) async throws -> [String: GraphTensor]
}

public enum GraphRunnerError: Error, LocalizedError {
    case unavailable(String)
    case functionNotFound(String)
    case statefulGraphUnsupported([String])
    case unknownInput(String)
    case shapeMismatch(input: String, expected: [Int], got: [Int])
    case missingOutput(String)
    case unsupportedScalarType(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): "Core AI graph runtime unavailable: \(m)"
        case .functionNotFound(let n): "graph function not found: \(n)"
        case .statefulGraphUnsupported(let s): "stateful graph unsupported (states: \(s))"
        case .unknownInput(let n): "unknown graph input: \(n)"
        case .shapeMismatch(let i, let e, let g): "input \(i) shape \(g) != expected \(e)"
        case .missingOutput(let n): "graph produced no output named \(n)"
        case .unsupportedScalarType(let t): "unsupported tensor scalar type: \(t)"
        }
    }
}

#if canImport(CoreAI)
import CoreAI

/// Loads and runs a single-`main`, stateless Core AI graph on the GPU.
public final class CoreAIGraphRunner: GraphRunner, @unchecked Sendable {
    private let function: InferenceFunction
    private let descriptor: InferenceFunctionDescriptor
    public let inputNames: [String]
    public let outputNames: [String]

    /// Loads and specializes the `.aimodel`. GPU + `expectFrequentReshapes` is the recipe for a
    /// dynamic graph (raw `AIModel` with defaults picks the ANE and crashes on these shapes).
    ///
    /// ⚠️ See the file header: specialization of the currently-published Sortformer model aborts
    /// the process on this toolchain. Only call against a model known to specialize.
    public init(modelURL: URL, function name: String = "main") async throws {
        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = true
        let model = try await AIModel(contentsOf: modelURL, options: options)
        guard let descriptor = model.functionDescriptor(for: name) else {
            throw GraphRunnerError.functionNotFound(name)
        }
        guard descriptor.stateNames.isEmpty else {
            throw GraphRunnerError.statefulGraphUnsupported(descriptor.stateNames)
        }
        guard let function = try model.loadFunction(named: name) else {
            throw GraphRunnerError.functionNotFound(name)
        }
        self.descriptor = descriptor
        self.function = function
        self.inputNames = descriptor.inputNames
        self.outputNames = descriptor.outputNames
    }

    public func run(_ inputs: [String: GraphTensor]) async throws -> [String: GraphTensor] {
        var ndInputs: [String: NDArray] = [:]
        for name in inputNames {
            guard let value = inputs[name] else { throw GraphRunnerError.unknownInput(name) }
            guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else {
                throw GraphRunnerError.unknownInput(name)
            }
            guard d.shape.count == value.shape.count,
                  zip(d.shape, value.shape).allSatisfy({ $0 < 0 || $0 == $1 }) else {
                throw GraphRunnerError.shapeMismatch(input: name, expected: d.shape, got: value.shape)
            }
            let resolved = d.resolvingDynamicDimensions(value.shape)
            ndInputs[name] = try Self.makeNDArray(value.values, descriptor: resolved, inputName: name)
        }

        var raw = try await function.run(inputs: ndInputs)
        var outputs: [String: GraphTensor] = [:]
        for name in outputNames {
            guard let array = raw.remove(name)?.ndArray else {
                throw GraphRunnerError.missingOutput(name)
            }
            outputs[name] = try Self.readTensor(array)
        }
        return outputs
    }

    // MARK: NDArray bridge

    private static func makeNDArray(_ values: [Float],
                                    descriptor: NDArrayDescriptor,
                                    inputName: String) throws -> NDArray {
        var array = NDArray(descriptor: descriptor)
        switch descriptor.scalarType {
        case .float16:
            var view = array.mutableView(as: Float16.self)
            view.copyElements(fromContentsOf: values.map(Float16.init))
        case .float32:
            var view = array.mutableView(as: Float.self)
            view.copyElements(fromContentsOf: values)
        default:
            throw GraphRunnerError.unsupportedScalarType("\(descriptor.scalarType) for input \(inputName)")
        }
        return array
    }

    private static func readTensor(_ array: NDArray) throws -> GraphTensor {
        let shape = array.shape
        let count = shape.reduce(1, *)
        let values: [Float]
        switch array.scalarType {
        case .float16:
            values = array.view(as: Float16.self).withUnsafePointer { ptr, _, _ in
                (0..<count).map { Float(ptr[$0]) }
            }
        case .float32:
            values = array.view(as: Float.self).withUnsafePointer { ptr, _, _ in
                Array(UnsafeBufferPointer(start: ptr, count: count))
            }
        default:
            throw GraphRunnerError.unsupportedScalarType("\(array.scalarType)")
        }
        return GraphTensor(values: values, shape: shape)
    }
}
#endif
