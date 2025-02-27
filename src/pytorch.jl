module Torch

using PyCall

using ChainRulesCore
using DLPack
using Functors: @functor
using Adapt

using ..PyCallChainRules: PyAdaptor, fmap

const inspect = PyNULL()
const torch = PyNULL()
const functorch = PyNULL()
const dlpack = PyNULL()
const ispysetup = Ref{Bool}(false)

pyto_dlpack(x) = @pycall dlpack.to_dlpack(x)::PyObject
pyfrom_dlpack(x) = @pycall dlpack.from_dlpack(x)::PyObject


struct TorchModuleWrapper
    torch_stateless_module::PyObject
    dtype::PyObject
    params::Tuple
    buffers::Tuple
end

@functor TorchModuleWrapper (params,)

Base.show(io::IO, f::TorchModuleWrapper) = print(io, f.torch_stateless_module, " ", f.dtype, " ", " params size=", size.(f.params))

Base.length(f::TorchModuleWrapper) = length(f.params)
Base.iterate(f::TorchModuleWrapper) = iterate(f.params)
Base.iterate(f::TorchModuleWrapper, state) = iterate(f.params, state)

function TorchModuleWrapper(torch_module)
    pybuiltin("isinstance")(torch_module, torch.nn.Module) || error("Not a torch.nn.Module")
    funmod, params, buffers = functorch.make_functional_with_buffers(torch_module)
    dtype = params[1].dtype
    jlparams = map(params) do x
        DLPack.wrap(x, pyto_dlpack)
    end
    return TorchModuleWrapper(funmod, dtype, jlparams, buffers)
end


function (wrap::TorchModuleWrapper)(args...; kwargs...)
    params = wrap.params
    out = wrap.torch_stateless_module(Tuple(map(x -> DLPack.share(x, PyObject, pyfrom_dlpack).requires_grad_(true), params)),
        wrap.buffers, fmap(x -> DLPack.share(x, PyObject, pyfrom_dlpack), args)...; kwargs...)
    res = fmap(x->DLPack.wrap(x, pyto_dlpack), out)
    return res
end

function ChainRulesCore.rrule(wrap::TorchModuleWrapper, args...; kwargs...)
    T = typeof(first(wrap.params))
    params = wrap.params
    pyparams = Tuple(map(x -> DLPack.share(x, PyObject, pyfrom_dlpack).requires_grad_(true), params))
    pyargs = fmap(x -> DLPack.share(x, PyObject, pyfrom_dlpack).requires_grad_(true), args)

    torch_primal, torch_vjpfun = functorch.vjp(py"buffer_implicit"(wrap.torch_stateless_module, wrap.buffers), pyparams, pyargs...; kwargs...)
    project = ProjectTo(args)
    function TorchModuleWrapper_pullback(Δ)
        cΔ = fmap(x->Adapt.adapt(PyAdaptor{T}(), x), Δ)
        pycΔ = fmap(x->DLPack.share(x, PyObject, pyfrom_dlpack), cΔ)
        torch_tangent_vals = torch_vjpfun(pycΔ)
        jlparams_tangents = map(x -> DLPack.wrap(x, pyto_dlpack), torch_tangent_vals[1])
        args_tangents = project(fmap(x -> DLPack.wrap(x, pyto_dlpack), torch_tangent_vals[2:end]))
        return (Tangent{TorchModuleWrapper}(; torch_stateless_module = NoTangent(), dtype = NoTangent(), params = jlparams_tangents, buffers = NoTangent()), args_tangents...)
    end
    res = fmap(x->DLPack.wrap(x, pyto_dlpack), torch_primal)
    return res, TorchModuleWrapper_pullback
end


function __init__()
    try
        copy!(torch, pyimport("torch"))
        copy!(dlpack, pyimport("torch.utils.dlpack"))
        copy!(functorch, pyimport("functorch"))
        copy!(inspect, pyimport("inspect"))
        ispysetup[] = true
        py"""
        def buffer_implicit(fn, buffers):
            def newfn(params, *inputs, **kwargs):
                return fn(params, buffers, *inputs, **kwargs)
            
            return newfn
        """        
    catch err
        @warn """PyCallChainRules.jl has failed to import torch and functorch from Python.
                 Please make sure these are installed. 
        """
        @debug err
        ispysetup[] = false
        #rethrow(err)        
    end
end

end