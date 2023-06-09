function numerical_range(A::Matrix, resolution::Number = 0.01)
    w = ComplexF64[]
    for θ = 0:resolution:2pi
        Ath = exp(1im * -θ) * A
        Hth = (Ath + Ath') / 2
        F = eigen(Hth)
        m = F.values[end]
        s = findall(≈(m), F.values)
        if length(s) == 1
            p = F.vectors[:, s]' * A * F.vectors[:, s]
            push!(w, tr(p))
        else
            Kth = 1im * (Hth - Ath)
            pKp = F.vectors[:, s]' * Kth * F.vectors[:, s]
            FF = eigen(pKp)
            mm = FF.values[1]
            ss = findall(≈(mm), FF.values)
            p =
                FF.vectors[:, ss[1]]' *
                F.vectors[:, s]' *
                A *
                F.vectors[:, s] *
                FF.vectors[:, ss[1]]
            push!(w, tr(p))
            mM = maximum(FF.values[end])
            sS = findall(≈(mM), FF.values)
            p =
                FF.vectors[:, sS[1]]' *
                F.vectors[:, s]' *
                A *
                F.vectors[:, s] *
                FF.vectors[:, sS[1]]
            push!(w, tr(p))
        end
    end
    return w
end

function get_bounding_box_old(A::Matrix)
    reA = Hermitian(A + A' / 2)
    imA = Hermitian(-1im * (A - A') / 2.0)
    reEig = eigvals(reA)
    imEig = eigvals(imA)
    mx, Mx, my, My = reEig[1], reEig[end], imEig[1], imEig[end]
    return mx, Mx, my, My
end

function get_bounding_box(A::Matrix)
    nr = numerical_range(A)
    minimum(real(nr)), maximum(real(nr)), minimum(imag(nr)), maximum(imag(nr))
end

function get_bin_edges(A::Matrix, nbins_x::Int, nbins_y::Int = nbins_x)
    min_x, max_x, min_y, max_y = get_bounding_box(A)
    x_edges = min_x:(max_x-min_x)/nbins_x:max_x
    y_edges = min_y:(max_y-min_y)/nbins_y:max_y
    x_edges, y_edges
end

mutable struct Hist2D
    x_edges::AbstractVector
    y_edges::AbstractVector
    hist::AbstractMatrix
    nr::AbstractVector
    evs::AbstractVector
    Hist2D(x_edges, y_edges, hist) = new(x_edges, y_edges, hist)
end

function Hist2D(x_edges::AbstractVector, y_edges::AbstractVector)
    hist = zeros(Int64, length(x_edges) - 1, length(y_edges) - 1)
    Hist2D(x_edges, y_edges, hist)
end

function Hist2D(x_edges::CuVector, y_edges::CuVector)
    hist = CUDA.zeros(Int32, length(x_edges) - 1, length(y_edges) - 1)
    Hist2D(x_edges, y_edges, hist)
end

function Base.:+(h1::Hist2D, h2::Hist2D)
    @assert all(h1.x_edges .≈ h2.x_edges)
    @assert all(h1.y_edges .≈ h2.y_edges)
    Hist2D(h1.x_edges, h1.y_edges, h1.hist + h2.hist)
end

function save(h::Hist2D, fname::String)
    NPZ.npzwrite(
        fname,
        Dict(
            "x_edges" => Array(h.x_edges),
            "y_edges" => Array(h.y_edges),
            "hist" => Array(h.hist),
            "nr" => Array(h.nr),
            "evs" => Array(h.evs),
        ),
    )
end

function histogram(xs::CuVector, ys::CuVector, x_edges::CuVector, y_edges::CuVector)
    function kernel(xs, ys, x_edges, y_edges, hist)
        i = (blockIdx().x - 1) * blockDim().x + threadIdx().x
        i > length(xs) && return
        @inbounds x, y = xs[i], ys[i]
        idx_x = searchsorted(x_edges, x).stop
        idx_y = searchsorted(y_edges, y).stop
        m = length(x_edges)
        n = length(y_edges)
        if idx_x == m
            idx_x = m - 1
        end
        if idx_y == n
            idx_y = n - 1
        end
        @inbounds k = LinearIndices(hist)[idx_x, idx_y]
        CUDA.atomic_add!(pointer(hist, k), Int32(1))
        nothing
    end

    @assert length(xs) == length(ys)
    n_blocks = (length(xs) + nTPB - 1) ÷ nTPB
    hist = CUDA.zeros(Int32, length(x_edges) - 1, length(y_edges) - 1)
    @cuda threads = nTPB blocks = n_blocks kernel(xs, ys, x_edges, y_edges, hist)
    Hist2D(x_edges, y_edges, hist)
end
