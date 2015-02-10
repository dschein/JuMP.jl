export setLazyCallback, setCutCallback, setHeuristicCallback, setInfoCallback
export setlazycallback
@Base.deprecate setlazycallback setLazyCallback

abstract JuMPCallback
type LazyCallback <: JuMPCallback
    f::Function
    fractional::Bool
end
type CutCallback <: JuMPCallback
    f::Function
end
type HeuristicCallback <: JuMPCallback
    f::Function
end
type InfoCallback <: JuMPCallback
    f::Function
end

Base.copy{T<:JuMPCallback}(c::T) = T(copy(c))
Base.copy(c::LazyCallback) = LazyCallback(copy(c.f), c.fractional)

function setLazyCallback(m::Model, f::Function; fractional::Bool=false)
    m.internalModelLoaded = false
    push!(m.callbacks, LazyCallback(f,fractional))
end
function setCutCallback(m::Model, f::Function)
    m.internalModelLoaded = false
    push!(m.callbacks, CutCallback(f))
end
function setHeuristicCallback(m::Model, f::Function)
    m.internalModelLoaded = false
    push!(m.callbacks, HeuristicCallback(f))
end
function setInfoCallback(m::Model, f::Function)
    m.internalModelLoaded = false
    push!(m.callbacks, InfoCallback(f))
end

function attach_callback(m::Model, cb::LazyCallback)
    lazy, fractional = cb.f::Function, cb.fractional::Bool
    function lazycallback(d::MathProgBase.MathProgCallbackData)
        state = MathProgBase.cbgetstate(d)
        @assert state == :MIPSol || state == :MIPNode
        if state == :MIPSol
            MathProgBase.cbgetmipsolution(d,m.colVal)
        else
            fractional || return
            MathProgBase.cbgetlpsolution(d,m.colVal)
        end
        lazy(d)
    end
    MathProgBase.setlazycallback!(m.internalModel, lazycallback)
end

function attach_callback(m::Model, cb::CutCallback)
    function cutcallback(d::MathProgBase.MathProgCallbackData)
        state = MathProgBase.cbgetstate(d)
        @assert state == :MIPSol || state == :MIPNode
        if state == :MIPSol  # This shouldn't happen right?
            println("Is this ever called?")
            MathProgBase.cbgetmipsolution(d,m.colVal)
        else
            MathProgBase.cbgetlpsolution(d,m.colVal)
        end
        cb.f(d)
    end
    MathProgBase.setcutcallback!(m.internalModel, cutcallback)
end

function attach_callback(m::Model, cb::HeuristicCallback)
    function heurcallback(d::MathProgBase.MathProgCallbackData)
        state = MathProgBase.cbgetstate(d)
        @assert state == :MIPSol || state == :MIPNode
        if state == :MIPSol  # This shouldn't happen right?
            println("Is this ever called?")
            MathProgBase.cbgetmipsolution(d,m.colVal)
        else
            MathProgBase.cbgetlpsolution(d,m.colVal)
        end
        cb.f(d)
    end
    MathProgBase.setheuristiccallback!(m.internalModel, heurcallback)
end

function attach_callback(m::Model, cb::InfoCallback)
    function infocallback(d::MathProgBase.MathProgCallbackData)
        state = MathProgBase.cbgetstate(d)
        @assert state == :MIPSol || state == :MIPNode
        if state == :MIPSol  # This shouldn't happen right?
            println("Is this ever called?")
            MathProgBase.cbgetmipsolution(d,m.colVal)
        else
            MathProgBase.cbgetlpsolution(d,m.colVal)
        end
        cb.f(d)
    end
    MathProgBase.setinfocallback!(m.internalModel, infocallback)
end

function registercallbacks(m::Model)
    isempty(m.callbacks) && return # might as well avoid allocating the indexedVector

    for cb in m.callbacks
        attach_callback(m, cb)
    end

    # prepare storage for callbacks
    m.indexedVector = IndexedVector(Float64, m.numCols)
end


# TODO: Should this be somewhere else?
const sensemap = @compat Dict(:(<=) => '<', :(==) => '=', :(>=) => '>')


## Lazy constraints
export addLazyConstraint, @addLazyConstraint

macro addLazyConstraint(cbdata, x)
    cbdata = esc(cbdata)
    if (x.head != :comparison)
        error("Expected comparison operator in constraint $x")
    end
    if length(x.args) == 3 # simple comparison
        lhs = :($(x.args[1]) - $(x.args[3])) # move everything to the lhs
        newaff, parsecode = parseExpr(lhs, :aff, [1.0])
        quote
            aff = AffExpr()
            $parsecode
            constr = $(x.args[2])($newaff,0)
            addLazyConstraint($cbdata, constr)
        end
    else
        error("Syntax error (ranged constraints not permitted in callbacks)")
    end
end

function addLazyConstraint(cbdata::MathProgBase.MathProgCallbackData, constr::LinearConstraint)
    if length(constr.terms.vars) == 0
        MathProgBase.cbaddlazy!(cbdata, Cint[], Float64[], sensemap[sense(constr)], rhs(constr))
        return
    end
    assert_isfinite(constr.terms)
    m::Model = constr.terms.vars[1].m
    indices, coeffs = merge_duplicates(Cint, constr.terms, m.indexedVector, m)
    MathProgBase.cbaddlazy!(cbdata, indices, coeffs, sensemap[sense(constr)], rhs(constr))
end

## User cuts
export addUserCut, @addUserCut

macro addUserCut(cbdata, x)
    cbdata = esc(cbdata)
    if (x.head != :comparison)
        error("Expected comparison operator in constraint $x")
    end
    if length(x.args) == 3 # simple comparison
        lhs = :($(x.args[1]) - $(x.args[3])) # move everything to the lhs
        newaff, parsecode = parseExpr(lhs, :aff, [1.0])
        quote
            aff = AffExpr()
            $parsecode
            constr = $(x.args[2])($newaff,0)
            addUserCut($cbdata, constr)
        end
    else
        error("Syntax error (ranged constraints not permitted in callbacks)")
    end
end

function addUserCut(cbdata::MathProgBase.MathProgCallbackData, constr::LinearConstraint)
    if length(constr.terms.vars) == 0
        MathProgBase.cbaddcut!(cbdata, Cint[], Float64[], sensemap[sense(constr)], rhs(constr))
        return
    end
    assert_isfinite(constr.terms)
    m::Model = constr.terms.vars[1].m
    indices, coeffs = merge_duplicates(Cint, constr.terms, m.indexedVector, m)
    MathProgBase.cbaddcut!(cbdata, indices, coeffs, sensemap[sense(constr)], rhs(constr))
end

## User heuristic
export addSolution, setSolutionValue!

addSolution(cbdata::MathProgBase.MathProgCallbackData) = MathProgBase.cbaddsolution!(cbdata)
function setSolutionValue!(cbdata::MathProgBase.MathProgCallbackData, v::Variable, x)
    MathProgBase.cbsetsolutionvalue!(cbdata, convert(Cint, v.col), x)
end
