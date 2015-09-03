try
    using QuantEcon: tauchen, MarkovChain, simulate
catch
    using QuantEcon: tauchen, MarkovChain, simulate
end

# ------------------------------------------------------------------- #
# Define the main Arellano Economy type
# ------------------------------------------------------------------- #

#=
Arellano 2008 deals with a small open economy whose government
invests in foreign assets in order to smooth the consumption of
domestic households. Domestic households receive a stochastic
path of income.

Parameters
----------
beta : float
    Time discounting parameter
gamma : float
    Risk-aversion parameter
r : float
    int lending rate
rho : float
    Persistence in the income process
eta : float
    Standard deviation of the income process
theta : float
    Probability of re-entering financial markets in each period
ny : int
    Number of points in y grid
nB : int
    Number of points in B grid
=#
immutable Arellano_Economy
    # Model Parameters
    β::Float64
    γ::Float64
    r::Float64
    ρ::Float64
    η::Float64
    θ::Float64

    # Grid Parameters
    ny::Int
    nB::Int
    ygrid::Array{Float64, 1}
    ydefgrid::Array{Float64, 1}
    Bgrid::Array{Float64, 1}
    Π::Array{Float64, 2}

    # Value function
    vf::Array{Float64, 2}
    vd::Array{Float64, 2}
    vc::Array{Float64, 2}
    policy::Array{Float64, 2}
    q::Array{Float64, 2}
    defprob::Array{Float64, 2}
end

function Arellano_Economy(;β=.953, γ=2., r=0.017, ρ=0.945, η=0.025, θ=0.282,
                          ny=21, nB=251)

    # Create grids
    Bgrid = collect(linspace(-.4, .4, nB))
    ly, Π = tauchen(ny, ρ, η)
    ygrid = exp(ly)
    ydefgrid = min(.969 * mean(ygrid), ygrid)

    # Define value functions (Notice ordered different than Python to take
    # advantage of column major layout of Julia)
    vf = zeros(nB, ny)
    vd = zeros(1, ny)
    vc = zeros(nB, ny)
    policy = Array(Int, nB, ny)
    q = ones(nB, ny) .* (1 / (1 + r))
    defprob = Array(Float64, nB, ny)

    return Arellano_Economy(β, γ, r, ρ, η, θ, ny, nB, ygrid, ydefgrid, Bgrid, Π,
                            vf, vd, vc, policy, q, defprob)
end

u(ae::Arellano_Economy, c) = c^(1 - ae.γ) / (1 - ae.γ)
_unpack(ae::Arellano_Economy) =
    ae.β, ae.γ, ae.r, ae.ρ, ae.η, ae.θ, ae.ny, ae.nB
_unpackgrids(ae::Arellano_Economy) =
    ae.ygrid, ae.ydefgrid, ae.Bgrid, ae.Π, ae.vf, ae.vd, ae.vc, ae.policy, ae.q, ae.defprob


# ------------------------------------------------------------------- #
# Write the value function iteration
# ------------------------------------------------------------------- #
#=
This function performs the one step update -- Using current value
functions and their expected value, it updates the value function
at every state by solving for the optimal choice of savings

Note: Updates value functions in place.
=#
function one_step_update!(ae, EV, EVd, EVc)

    # Unpack stuff
    β, γ, r, ρ, η, θ, ny, nB = _unpack(ae)
    ygrid, ydefgrid, Bgrid, Π, vf, vd, vc, policy, q, defprob = _unpackgrids(ae)
    zero_ind = searchsortedfirst(Bgrid, 0.)

    for iy=1:ny
        y = ae.ygrid[iy]
        ydef = ae.ydefgrid[iy]

        # Value of being in default with income y
        defval = u(ae, ydef) + β*(θ*EVc[zero_ind, iy] + (1-θ)*EVd[1, iy])
        ae.vd[1, iy] = defval

        for ib=1:nB
            B = ae.Bgrid[ib]

            current_max = -1e14
            pol_ind = 0
            for ib_next=1:nB
                c = max(y - ae.q[ib_next, iy]*Bgrid[ib_next] + B, 1e-14)
                m = u(ae, c) + β * EV[ib_next, iy]

                if m > current_max
                    current_max = m
                    pol_ind = ib_next
                end

            end

            # Update value and policy functions
            ae.vc[ib, iy] = current_max
            ae.pol[ib, iy] = pol_ind
            ae.vf[ib, iy] = defval > current_max ? defval : current_max
        end
    end

    nothing
end

function compute_prices!(ae)
    # Unpack parameters
    β, γ, r, ρ, η, θ, ny, nB = _unpack(ae)

    # Create default values with a matching size
    vd_compat = repmat(ae.vd, nB)
    default_states = vd_compat .> ae.vc

    # Update default probabilities and prices
    copy!(ae.defprob, default_states * ae.Π')
    copy!(ae.q, (1 - ae.defprob) / (1 + r))

    nothing
end

function vfi(ae; tol=1e-8, maxit=10000)

    # Unpack stuff
    β, γ, r, ρ, η, θ, ny, nB = _unpack(ae)
    ygrid, ydefgrid, Bgrid, Π, vf, vd, vc, policy, q, defprob = _unpackgrids(ae)
    Πt = Π'

    # Iteration stuff
    it = 0
    dist = 10.

    # Allocate memory for update
    V_upd = zeros(ae.vf)

    while dist > tol && it < maxit
        it += 1

        # Compute expectations for this iterations
        # (We need Π' because of order value function dimensions)
        copy!(V_upd, ae.vf)
        EV = ae.vf * Πt
        EVd = ae.vd * Πt
        EVc = ae.vc * Πt

        # Update Value Function
        one_step_update!(ae, EV, EVd, EVc)

        # Update prices
        compute_prices!(ae)

        dist = maxabs(V_upd - ae.vf)

        if it%25 == 0
            println("Finished iteration $(it) with dist of $(dist)")
        end
    end

    nothing
end
