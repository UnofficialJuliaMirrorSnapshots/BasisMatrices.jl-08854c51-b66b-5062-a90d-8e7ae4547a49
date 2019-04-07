# -------------- #
# B-Spline Basis #
# -------------- #

immutable Spline <: BasisFamily end

type SplineParams{T<:AbstractVector} <: BasisParams
    breaks::T
    evennum::Int
    k::Int

    # constructor to accept spline params arguments, do some pre-processing
    function (::Type{SplineParams{T}}){T}(breaks::T, evennum::Int, k::Int)
        # error handling
        k < 0 && error("spline order must be positive")
        length(breaks) < 2 && error("Must have at least two breakpoints")
        any(diff(breaks) .< 0) && error("Breakpoints must be non-decreasing")

        if evennum == 0  # 43
            if length(breaks) == 2  # 44
                evennum = 2
            end
        else
            if length(breaks) == 2
                breaks = linspace(breaks[1], breaks[2], evennum)
            else
                error("Breakpoint squence must contain 2 values when evennum > 0")
            end
        end
        new{T}(breaks, evennum, k)
    end

end

SplineParams{T<:AbstractVector}(breaks::T, evennum::Int, k::Int) =
    SplineParams{T}(breaks, evennum, k)

# constructor to take a, b, n and form linspace for breaks
SplineParams(n::Int, a::Real, b::Real, k::Int=3) =
    SplineParams(linspace(a, b, n), 0, k)

## BasisParams interface
# define these methods on the type, the instance version is defined over
# BasisParams
family{T<:SplineParams}(::Type{T}) = Spline
family_name{T<:SplineParams}(::Type{T}) = "Spline"
Base.issparse{T<:SplineParams}(::Type{T}) = true
@generated function Base.eltype{T<:SplineParams}(::Type{T})
    elT = eltype(T.parameters[1])
    elT <: Integer ? Float64 : elT
end

# methods that only make sense for instances
Base.min(p::SplineParams) = minimum(p.breaks)
Base.max(p::SplineParams) = maximum(p.breaks)
Base.length(p::SplineParams) = length(p.breaks) + p.k - 1

function Base.show(io::IO, p::SplineParams)
    m = string("$(p.k) order spline interpoland parameters from ",
               "$(p.breaks[1]), $(p.breaks[end])")
    print(io, m)
end


"""
Construct interpolation nodes, given SplineParams

Note that `p.k - 1` additional nodes will be inserted

##### Arguments

- `p::SplineParams`: `SplineParams` instance

##### Returns

- `x::Vector`: The Vector of 1d interpolation nodes.

"""
function nodes(p::SplineParams)
    breaks, evennum, k = p.breaks, p.evennum, p.k
    a = breaks[1]  # 20
    b = breaks[end]  # 21
    n = length(breaks) + k - 1  # 22
    x = cumsum(vcat(fill(a, k), breaks, fill(b, k)))  # 23
    x = (x[1+k:n+k] - x[1:n]) / k  # 24
    x[1] = a  # 25
    x[end] = b  # 26
    x
end

# TODO: define method derivative_op(::Type{SplineSparse}, p::SplineParams, order::Int)
function derivative_op(p::SplineParams, order=1)
    breaks, evennum, k = p.breaks, p.evennum, p.k

    any(order .> k) && error("Order of differentiation can't be greater than k")

    # 38-40
    n = length(breaks) + k - 1
    kk = max(k - 1, k - order - 1)
    augbreaks = vcat(fill(breaks[1], kk), breaks, fill(breaks[end], kk))

    D = Array{SparseMatrixCSC{Float64,Int64}}(abs(order), 1)

    if order > 0  # derivative
        temp = k ./ (augbreaks[k+1:n+k-1] - augbreaks[1:n-1])
        D[1] = spdiagm((-temp, temp), 0:1, n-1, n)

        for i in 2:order
            temp = (k+1-i) ./ (augbreaks[k+1:n+k-i] - augbreaks[i:n-1])
            D[i] = spdiagm((-temp, temp), 0:1, n-i, n+1-i)*D[i-1]
        end
    else
        error("not implemented")
    end

    D, SplineParams(breaks, evennum, k-order)
end

function _chk_evalbase(p::SplineParams, x, order)
    breaks, evennum, k = p.breaks, p.evennum, p.k

    # error handling
    k < 0 && error("spline order must be positive")
    !(issorted(breaks)) && error("Breakpoints must be non-decreasing")
    any(order .>= k) && error("Order of differentiation must be less than k")
    size(x, 2) > 1 && error("x must be a column vector")

    m = size(x, 1)  # 54
    minorder = minimum(order)  # 55

    # Augment the breakpoint sequence 57-59
    n = length(breaks)+k-1
    a = breaks[1]
    b = breaks[end]
    augbreaks = vcat(fill(a, k-minorder), breaks, fill(b, k-minorder))

    ind = lookup(augbreaks, x, 3)  # 69

    n, m, minorder, augbreaks, ind
end

evalbase(p::SplineParams, x=nodes(p), order::Int=0) = evalbase(p, x, [order])[1]

evalbase(::Type{SplineSparse}, p::SplineParams, x=nodes(p), order::Int=0) =
    evalbase(SplineSparse, p, x, [order])[1]

"""
Evaluate spline basis matrices for a certain order derivative at x

##### Arguments

- `p::SplineParams`: A `SplineParams` summarizing spline properties
- `x(nodes(p))` : the nodes at which to evaluate the basis matrices
- `order(0)` : The order(s) of derivative for which to evaluate the basis
matrices. `order=0` corresponds to the function itself, negative numbers
correspond to integrals.

##### Returns

- `B::SparseMatrixCSC` : Matrix containing the evaluation of basis functions
at each point in `x`. Each column represents a basis function.
- `x`: Points at which the functions were evaluated

"""
function evalbase(p::SplineParams, x, order::AbstractVector{Int})
    n, m, minorder, augbreaks, ind = _chk_evalbase(p, x, order)

    max_repeat = p.k-minorder + 1
    T = eltype(p)
    bas = zeros(T, m, max_repeat)  # 73
    bas[:, 1] = one(T)  # 74
    B = Array{SparseMatrixCSC{T,Int}}(length(order))  # 75

    # 76
    if maximum(order) > 0
        D = derivative_op(p, maximum(order))[1]
    end

    # 77
    if minorder < 0
        I = derivative_op(p, minorder)[1]
    end

    # We know what the rows and columns will be, we just compute them once and
    # then extract chunks as we need them.
    # note: I benchmarked and the version with collect was (2-5)x faster
    r = repmat(collect(1:m), max_repeat)
    c = (minorder-p.k:0)' .+ ind

    for j in 1:p.k-minorder  # 78
        for jj in j:-1:1  # 79
            for ix in eachindex(ind)
                b0 = augbreaks[ind[ix]+jj-j]  # 80
                b1 = augbreaks[ind[ix]+jj]  # 81
                temp = bas[ix, jj] / (b1 - b0)  # 82
                bas[ix, jj+1] = (x[ix] - b0) * temp + bas[ix, jj+1]  # 83
                bas[ix, jj] = (b1-x[ix]) * temp  # 84
            end
        end

        # bas now contains the order `j` spline basis
        ii = findfirst(order, p.k-j)  # 87
        if ii > 0
            # Put values in appropriate columns of a sparse matrix
            N = m * (p.k-order[ii]+1)
            B[ii] = sparse(view(r, 1:N), view(c, 1:N), view(bas, 1:N), m, n-order[ii])

            # 96-100
            if order[ii] > 0
                B[ii] = B[ii] * D[order[ii]]
            elseif order[ii] < 0
                B[ii] = B[ii] * I[-order[ii]]
            end
        end
    end

    B
end

function evalbase(::Type{SplineSparse}, p::SplineParams, x,
                  order::AbstractVector{Int})
    n, m, minorder, augbreaks, ind = _chk_evalbase(p, x, order)

    max_repeat = p.k-minorder + 1
    T = eltype(p)
    bas = zeros(T, max_repeat, m)
    bas[1, :] = one(T)
    B = Array{SplineSparse{T,Int}}(length(order))  # 75

    if maximum(order) > 0
        error("not supported yet")
        D = derivative_op(p, maximum(order))[1]
    end

    if minorder < 0
        error("not supported yet")
        I = derivative_op(p, minorder)[1]
    end

    for j in 1:p.k-minorder  # 78
        for ix in eachindex(ind)
            for jj in j:-1:1  # 79
                b0 = augbreaks[ind[ix]+jj-j]  # 80
                b1 = augbreaks[ind[ix]+jj]  # 81
                temp = bas[jj, ix] / (b1 - b0)  # 82
                bas[jj+1, ix] = (x[ix] - b0) * temp + bas[jj+1, ix]  # 83
                bas[jj, ix] = (b1-x[ix]) * temp  # 84
            end
        end

        # bas now contains the order `j` spline basis
        ii = findfirst(order, p.k-j)  # 87
        if ii > 0
            ord = order[ii]
            cols = (ord - p.k) + ind
            B[ii] = SplineSparse{T,Int,1,p.k-ord+1}(n-ord, vec(bas), cols)
        end
    end
    return B
end
