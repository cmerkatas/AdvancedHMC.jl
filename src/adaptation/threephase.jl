######################
### Mutable states ###
######################

mutable struct ThreePhaseState
    i           :: Int
    window_size :: Int
    next_window :: Int
end

################
### Adapterers ###
################

# TODO: currently only StanNUTSAdapter has the filed `n_adapts`. maybe we could unify all
# Acknowledgement: this adaption settings is mimicing Stan's 3-phase adaptation.
struct StanNUTSAdapter <: AbstractCompositeAdapter
    n_adapts    :: Int
    pc          :: AbstractPreConditioner
    ssa         :: StepSizeAdapter
    init_buffer :: Int
    term_buffer :: Int
    state       :: ThreePhaseState
end

function StanNUTSAdapter(n_adapts::Int, pc::AbstractPreConditioner, ssa::StepSizeAdapter,
                         init_buffer::Int=75, term_buffer::Int=50, window_size::Int=25)
    next_window = init_buffer + window_size - 1
    return StanNUTSAdapter(n_adapts, pc, ssa, init_buffer, term_buffer, ThreePhaseState(0, window_size, next_window))
end

# Ref: https://github.com/stan-dev/stan/blob/develop/src/stan/mcmc/windowed_adaptation.hpp
function is_in_window(tp::StanNUTSAdapter)
    return (tp.state.i >= tp.init_buffer) &&
           (tp.state.i < tp.n_adapts - tp.term_buffer) &&
           (tp.state.i != tp.n_adapts)
end

function is_window_end(tp::StanNUTSAdapter)
    return (tp.state.i == tp.state.next_window) &&
           (tp.state.i != tp.n_adapts)
end

is_final(tp::StanNUTSAdapter) = tp.state.i == tp.n_adapts

function compute_next_window!(tp::StanNUTSAdapter)
    if ~(tp.state.next_window == tp.n_adapts - tp.term_buffer - 1)
        tp.state.window_size *= 2
        tp.state.next_window = tp.state.i + tp.state.window_size
        if ~(tp.state.next_window == tp.n_adapts - tp.term_buffer - 1)
            next_window_boundary = tp.state.next_window + 2 * tp.state.window_size
            if (next_window_boundary >= tp.n_adapts - tp.term_buffer)
                tp.state.next_window = tp.n_adapts - tp.term_buffer - 1
            end
        end
    end
end

function adapt!(tp::StanNUTSAdapter, θ::AbstractVector{<:Real}, α::AbstractFloat)
    tp.state.i += 1

    adapt!(tp.ssa, θ, α)

    # Ref: https://github.com/stan-dev/stan/blob/develop/src/stan/mcmc/hmc/nuts/adapt_diag_e_nuts.hpp
    if is_in_window(tp)
        adapt!(tp.pc, θ, α, false)
    elseif is_window_end(tp)
        # TODO: consider make the boolean variable as part of reset! (similar to what happens to μ)
        adapt!(tp.pc, θ, α, true)
    end

    if is_window_end(tp)
        reset!(tp.ssa)
        reset!(tp.pc)
    end

    if is_final(tp)
        finalize!(tp.ssa)
    end

    # If window ends, compute next window
    is_window_end(tp) && compute_next_window!(tp)
end
