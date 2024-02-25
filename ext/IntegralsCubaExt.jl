module IntegralsCubaExt

using Integrals, Cuba
import Integrals: transformation_if_inf,
    scale_x, scale_x!, CubaVegas, AbstractCubaAlgorithm,
    CubaSUAVE, CubaDivonne, CubaCuhre

function Integrals.__solvebp_call(prob::IntegralProblem, alg::AbstractCubaAlgorithm,
        sensealg,
        domain, p;
        reltol = 1e-4, abstol = 1e-12,
        maxiters = 1000000)
    @assert maxiters>=1000 "maxiters for $alg should be larger than 1000"
    lb, ub = domain
    mid = (lb + ub) / 2
    ndim = length(mid)
    (vol = prod(map(-, ub, lb))) isa Real ||
        throw(ArgumentError("Cuba.jl only supports real-valued integrands"))
    # we could support other types by multiplying by the jacobian determinant at the end

    if prob.f isa BatchIntegralFunction
        nvec = min(maxiters, prob.f.max_batch)
        # nvec == 1 in Cuba will change vectors to matrices, so we won't support it when
        # batching
        nvec > 1 ||
            throw(ArgumentError("BatchIntegralFunction must take multiple batch points"))

        if mid isa Real
            _x = zeros(typeof(mid), nvec)
            scale = x -> scale_x!(resize!(_x, length(x)), ub, lb, vec(x))
        else
            _x = zeros(eltype(mid), length(mid), nvec)
            scale = x -> scale_x!(view(_x, :, 1:size(x, 2)), ub, lb, x)
        end

        if isinplace(prob)
            y = prob.f.integrand_prototype
            fsize = size(y)[begin:(end - 1)]
            ax = map(_ -> (:), fsize)
            f = let y = similar(y, fsize..., nvec)
                function (x, dx)
                    dy = @view(y[ax..., begin:(begin + size(dx, 2) - 1)])
                    prob.f(dy, scale(x), p)
                    dx .= reshape(dy, :, size(dx, 2)) .* vol
                end
            end
        else
            y = mid isa Number ? prob.f(typeof(mid)[], p) :
                prob.f(Matrix{eltype(mid)}(undef, length(mid), 0), p)
            fsize = size(y)[begin:(end - 1)]
            f = (x, dx) -> dx .= reshape(prob.f(scale(x), p), :, size(dx, 2)) .* vol
        end
        ncomp = prod(fsize)
    else
        nvec = 1

        if mid isa Real
            scale = x -> scale_x(ub, lb, only(x))
        else
            _x = zeros(eltype(mid), length(mid))
            scale = x -> scale_x!(_x, ub, lb, x)
        end

        if isinplace(prob)
            y = prob.f.integrand_prototype
            f = let y = similar(y)
                (x, dx) -> begin
                    prob.f(y, scale(x), p)
                    dx .= vec(y) .* vol
                end
            end
        else
            y = prob.f(mid, p)
            f = (x, dx) -> dx .= Iterators.flatten(prob.f(scale(x), p)) .* vol
        end
        ncomp = length(y)
    end

    out = if alg isa CubaVegas
        Cuba.vegas(f, ndim, ncomp; rtol = reltol,
            atol = abstol, nvec = nvec,
            maxevals = maxiters,
            flags = alg.flags, seed = alg.seed, minevals = alg.minevals,
            nstart = alg.nstart, nincrease = alg.nincrease,
            gridno = alg.gridno)
    elseif alg isa CubaSUAVE
        Cuba.suave(f, ndim, ncomp; rtol = reltol,
            atol = abstol, nvec = nvec,
            maxevals = maxiters,
            flags = alg.flags, seed = alg.seed, minevals = alg.minevals,
            nnew = alg.nnew, nmin = alg.nmin, flatness = alg.flatness)
    elseif alg isa CubaDivonne
        Cuba.divonne(f, ndim, ncomp; rtol = reltol,
            atol = abstol, nvec = nvec,
            maxevals = maxiters,
            flags = alg.flags, seed = alg.seed, minevals = alg.minevals,
            key1 = alg.key1, key2 = alg.key2, key3 = alg.key3,
            maxpass = alg.maxpass, border = alg.border,
            maxchisq = alg.maxchisq, mindeviation = alg.mindeviation)
    elseif alg isa CubaCuhre
        Cuba.cuhre(f, ndim, ncomp; rtol = reltol,
            atol = abstol, nvec = nvec,
            maxevals = maxiters,
            flags = alg.flags, minevals = alg.minevals, key = alg.key)
    end

    # out.integral is a Vector{Float64}, but we want to return it to the shape of the integrand
    val = if prob.f isa BatchIntegralFunction
        if y isa AbstractVector
            out.integral[1]
        else
            reshape(out.integral, fsize)
        end
    else
        if y isa Real
            out.integral[1]
        elseif y isa AbstractVector
            out.integral
        else
            reshape(out.integral, size(y))
        end
    end

    SciMLBase.build_solution(prob, alg, val, out.error,
        chi = out.probability, retcode = ReturnCode.Success)
end

end
