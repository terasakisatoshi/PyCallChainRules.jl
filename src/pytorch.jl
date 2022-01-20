module Torch

using PyCall
using ChainRulesCore

const inspect = PyNULL()
const torch = PyNULL()
const functorch = PyNULL()

function reversedims(a::AbstractArray{T,N}) where {T<:AbstractFloat,N}
    permutedims(a, N:-1:1)
end


struct TorchModuleWrapper
    torch_stateless_module::PyObject
    dtype::PyObject
    device::PyObject
    params::Tuple
end

function TorchModuleWrapper(torch_module, device)
    pybuiltin("isinstance")(torch_module, torch.nn.Module) || error("Not a torch.nn.Module")
    torch_module = torch_module.to(device)
    funmod, params = functorch.make_functional(torch_module)
    dtype = params[1].dtype
    jlparams = map(x->x.detach().numpy(), params)
    return TorchModuleWrapper(funmod, dtype, device, jlparams)
end

function TorchModuleWrapper(torch_module)
    device = torch.cuda.is_available() ? torch.device("cuda:0") : torch.device("cpu")
    TorchModuleWrapper(torch_module, device)
end

function (wrap::TorchModuleWrapper)(args...)
    tensor_out = wrap.torch_stateless_module(Tuple(map(x->torch.as_tensor(x).to(device=wrap.device, dtype=wrap.dtype).requires_grad_(true), wrap.params)),
                                            map(x->torch.as_tensor(PyReverseDims(x)).to(dtype=wrap.dtype, device=wrap.device), args)...)
    return reversedims(tensor_out.detach().numpy())
end

function ChainRulesCore.rrule(f::TorchModuleWrapper, args...)
    torch_primal, torch_vjpfun = functorch.vjp(f.torch_stateless_module, Tuple(map(x->torch.as_tensor(x).to(device=wrap.device, dtype=wrap.dtype).requires_grad_(true), wrap.params)),
    map(x->torch.as_tensor(PyReverseDims(x)).to(dtype=wrap.dtype, device=wrap.device).requires_grad_(true), args)...)
    function TorchModuleWrapper_pullback(Δ)
        torch_tangent_vals = torch_vjpfun(torch.as_tensor(PyReverseDims(Δ)).to(dtype=f.dtype, device=f.device))
        jlparams_tangents = map(x->x.detach().numpy(), torch_tangent_vals[1])
        args_tangents = map(x->x.detach().numpy(), torch_tangent_vals[2:end])
        return (Tangent{TorchModuleWrapper}(;torch_stateless_module=NoTangent(),dtype=NoTangent(), device=NoTangent(), params=jlparams_tangents), args_tangents...)
    end
    return reversedims(torch_primal.detach().numpy()), TorchModuleWrapper_pullback
end


function __init__()
    copy!(torch, pyimport("torch"))
    copy!(functorch, pyimport("functorch"))
    copy!(inspect, pyimport("inspect"))
end

end