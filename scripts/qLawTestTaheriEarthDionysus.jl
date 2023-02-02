using DrWatson
@quickactivate "QLawIndirectOptimization"

using AstroEOMs, AstroUtils, SPICE, StaticArrays
using DifferentialEquations, DiffEqCallbacks, Plots
using DelimitedFiles
using QLawIndirectOptimization
furnshDefaults()

function main()
    # Compute initial epoch
    initEpoch   = utc2et("2005-01-30T00:00:00")

    # Define parameters for EOMs
    μs          = 132712440018.0
    tMax        = 0.32
    Isp         = 3000.0
    m0          = 4000.0
    mp          = 3500.0
    LU          = 1.496e8
    TU          = 365.0*24.0*3600.0 / (2*pi)
    meeParams   = MEEParams(initEpoch; LU = LU, MU = 1.0, TU = TU, μ = μs)
    spaceCraft  = SimpleSpacecraft(m0, m0, tMax, Isp)

    # Define initial and target orbital elements
    μ           = AstroEOMs.getScaledGravityParameter(meeParams)
    cart0       = SVector(-3637871.081 / LU, 147099798.784 / LU, -2261.441 / LU,
                    -30.265097 * TU/LU, -0.8486854 * TU/LU, 0.0000505 * TU/LU)
    mee0        = AstroUtils.convertState(cart0, AstroUtils.Cartesian, AstroUtils.MEE, μ)
    fullState0  = SVector(mee0[1], mee0[2], mee0[3], mee0[4], mee0[5], mee0[6], spaceCraft.initMass)
    kept        = [2.2, 0.542, 13.6*pi/180.0, 82.2*pi/180.0, 204.2*pi/180.0]

    # Define qLaw parameters
    oeW          = [2.0, 1.0, 1.0, 0.0, 1.0] 
    qLawPs       = qLawParams(kept, oeW, 0.0, 6578.0 / meeParams.LU, 1.0, μ,
                    spaceCraft.tMax * meeParams.TU^2 / (1000.0*meeParams.MU*meeParams.LU),
                    0.05, 360)

    # Define tolerance on targeted elements
    atol        = 1000.0 / meeParams.LU
    etol        = 0.001
    itol        = 0.01*pi / 180
    Ωtol        = 0.01*pi / 180
    ωtol        = 0.01*pi / 180
    tolVec      = SVector(atol,etol,itol,Ωtol,ωtol)

    # Set weights for error computation
    Wa          = qLawPs.oeW[1] > 0.0 ? 1.0 : 0.0
    We          = qLawPs.oeW[2] > 0.0 ? 1.0 : 0.0
    Wi          = qLawPs.oeW[3] > 0.0 ? 1.0 : 0.0
    WΩ          = qLawPs.oeW[4] > 0.0 ? 1.0 : 0.0
    Wω          = qLawPs.oeW[5] > 0.0 ? 1.0 : 0.0
    Ws          = SVector(Wa,We,Wi,WΩ,Wω)

    # Define EOMs
    function qLawEOMs(u, p, t)
        # Grab parameters
        meeParams   = p[1]
        spaceCraft  = p[2]
        qLawPs      = p[3]

        # Construct MEE state
        mee         = SVector(u[1],u[2],u[3],u[4],u[5],t)

        # Compute acceleration due to thrust
        if qLawPs.coasting == true
            at   = SVector(0.0,0.0,0.0)
            umag = 0.0
        else
            α  = qLawPs.α
            β  = qLawPs.β
            at = SVector(qLawPs.tMax*cos(β)*sin(α) / u[7],
                        qLawPs.tMax*cos(β)*cos(α) / u[7],
                        qLawPs.tMax*sin(β) / u[7])
            umag = qLawPs.tMax 
        end

        # Compute state dynamics
        dmee    = AstroEOMs.meeEomControl(mee,meeParams,u[6],at)
        dLinv   = 1.0 / dmee[6]

        # Compute sundman transformed dynamics
        dmees   = SVector(dmee[1]*dLinv, dmee[2]*dLinv, dmee[3]*dLinv,
                    dmee[4]*dLinv, dmee[5]*dLinv, dLinv)

        # Compute mass dynamics
        cs  = spaceCraft.c * meeParams.TU / (1000.0 * meeParams.LU)
        dm  = -umag / cs
        dms = dm*dLinv

        # Return full state dynamics
        return SVector(dmees[1],dmees[2],dmees[3],dmees[4],dmees[5],dmees[6],dms)
    end

    # Deal with Sundman transformation
    fullState0s = SVector(fullState0[1], fullState0[2], fullState0[3], 
                    fullState0[4], fullState0[5], 0.0, fullState0[7])

    # Specify independant variable span and info
    nRevs       = 20.0
    step        = 1.0 * pi / 180
    Lspan       = (fullState0[6], fullState0[6] + nRevs*2*pi)

    # Allocate storage arrays
    n           = ceil(Int,90.0*nRevs)
    Ls          = range(Lspan[1], Lspan[2]; length = n)
    ts          = fill(NaN, n)
    cart_th     = fill(NaN, n, 7)
    mee_th      = fill(NaN, n, 7)
    kep_th      = fill(NaN, n, 7)
    coast_th    = fill(true, n)

    # Begin integration loop
    done = false
    idx  = 1
    L0   = Lspan[1]
    Lf   = L0 + step
    while !done
        # Compute kep state
        mee     = SVector(fullState0s[1], fullState0s[2], fullState0s[3], 
                        fullState0s[4], fullState0s[5], L0)
        cart    = AstroUtils.convertState(mee, AstroUtils.MEE,
                        AstroUtils.Cartesian, qLawPs.μ)
        kep, fl = AstroUtils.convertState(cart, AstroUtils.Cartesian,
                        AstroUtils.Keplerian, qLawPs.μ)

        # Compute coasting
        qLawPs.coasting = false
        if qLawPs.ηr > 0.0
            val = try
                qLawCoastContinuousCallbackCheck(kep, fullState0s[7], qLawPs)
            catch e
                display(kep)
                throw(e)
            end
            qLawPs.coasting = val > 0.0 ? false : true
        end

        # Compute thrust angles
        if !qLawPs.coasting
            α, β = qLawThrustAngles(kep[1], kep[2], kep[3], kep[5], kep[4], kep[6], fullState0s[7], qLawPs)
            qLawPs.α = α
            qLawPs.β = β
        end

        # Perform numerical integration
        prob = ODEProblem(qLawEOMs, fullState0s, (L0, Lf), (meeParams,spaceCraft,qLawPs))
        sol  = solve(prob, Vern9(), reltol=1e-12, abstol=1e-12)

        # Save info
        while idx <= n && Ls[idx] <= sol.t[end] 
            mees_us     = sol(Ls[idx])
            mee_us      = SVector(mees_us[1], mees_us[2], mees_us[3],
                            mees_us[4], mees_us[5], Ls[idx], mees_us[7])

            ts[idx]             = mees_us[6]
            mee_th[idx,1]       = meeParams.LU * mee_us[1]
            mee_th[idx,2:7]    .= mee_us[2:7] 

            cart_us             = AstroUtils.convertState(mee_us, AstroUtils.MEE, AstroUtils.Cartesian, μ)
            cart_th[idx,1:3]   .= meeParams.LU*view(cart_us,1:3)
            cart_th[idx,4:6]   .= meeParams.LU*view(cart_us,4:6)/meeParams.TU
            cart_th[idx,7]      = mee_us[7]

            kep_us,fff          = AstroUtils.convertState(cart_us, AstroUtils.Cartesian, AstroUtils.Keplerian, μ)
            kep_th[idx,1]       = meeParams.LU*kep_us[1]
            kep_th[idx,2:6]    .= view(kep_us, 2:6)
            kep_th[idx,7]       = mee_us[7]

            # Deal with coasting
            coast_th[idx]      = qLawPs.coasting

            # Increment index
            idx += 1
        end

        # Compute targeting error
        aerr                = Ws[1]*abs(kep[1] - qLawPs.oet[1]) - tolVec[1]
        eerr                = Ws[2]*abs(kep[2] - qLawPs.oet[2]) - tolVec[2]
        ierr                = Ws[3]*abs(kep[3] - qLawPs.oet[3]) - tolVec[3]
        Ωerr                = Ws[4]*abs(acos(cos(kep[4] - qLawPs.oet[4]))) - tolVec[4]
        ωerr                = Ws[5]*abs(acos(cos(kep[5] - qLawPs.oet[5]))) - tolVec[5]
        targError           = (aerr, eerr, ierr, Ωerr, ωerr)

        # Print targeting error
        print(string(meeParams.LU * targError[1]) * "\t" * string(targError[2]) * "\t" * 
            string(targError[3]) * "\t" * string(targError[4]) * "\t" * 
            string(targError[5]) * "\n")

        # Check if we need to stop
        if Lf >= Lspan[2]
            done = true
        elseif maximum(targError) <= 0.0
            done = true
        elseif sol[end][7] < (m0 - mp)
            done = true
            print("Ran out of propellant!\n")
        end

        # Update loop variables
        fullState0s = SVector(sol[end]...)
        L0          = Lf
        Lf          = L0 + step
    end

    # Construct target orbit states with SI units
    kepts           = [kept[1]*LU, kept[2], kept[3], kept[4], kept[5]]

    # Construct constants output
    consts          = [μs]

    # Write data to files
    open(datadir("kep.txt"),   "w") do io; writedlm(io,   kep_th); end
    open(datadir("mee.txt"),   "w") do io; writedlm(io,   mee_th); end
    open(datadir("cart.txt"),  "w") do io; writedlm(io,  cart_th); end
    open(datadir("coast.txt"), "w") do io; writedlm(io, Int.(coast_th)); end
    open(datadir("time.txt"),  "w") do io; writedlm(io, ts); end
    open(datadir("kept.txt"),  "w") do io; writedlm(io, kepts); end
    open(datadir("consts.txt"),"w") do io; writedlm(io, consts); end
    


    #plot(cart[:,1],cart[:,2],cart[:,3])
    #plot(ts,kep[:,1])
end

main()