"""
    dsea(data, train, y, train_and_predict_proba;
         features = setdiff(names(train), [y]),
         kwargs...)

Deconvolve the `y` distribution in the DataFrame `data`, as learned from the DataFrame
`train`. This function wraps `dsea(::Matrix, ::Matrix, ::Array, ::Function)`.

The additional keyword arguments allows to specify the columns in `data` and `train` to be
used as the `features`.
"""
function dsea(data::AbstractDataFrame, train::AbstractDataFrame, y::Symbol,
              train_and_predict_proba::Function;
              features::AbstractArray{Symbol, 1} = setdiff(names(train), [y]),
              kwargs...)
    X_data,  _       = Util.df2Xy(data,  y, features)
    X_train, y_train = Util.df2Xy(train, y, features)
    dsea(X_data, X_train, y_train, train_and_predict_proba; kwargs...)
end

"""
    dsea(X_data, X_train, y_train, train_and_predict_proba; kwargs...)

Deconvolve the target distribution of `X_data`, as learned from `X_train` and `y_train`.
The function `train_and_predict_proba` trains and applies a classifier. It has the signature
`(X_data, X_train, y_train, w_train, ylevels) -> Any`
where all arguments but `w_train`, which is updated in each iteration, are simply passed
through.
To facilitate classification, `y_train` has to be discrete, i.e., it has to have a limited
number of unique values that are used as labels for the classifier.

# Keyword arguments
- `ylevels = sort(unique(y_train))`
  The unique values in `y_train`, optionally specified to ensure that each expected unique
  value is considered in the deconvolution result.
- `f_0 = ones(length(ylevels)) ./ length(ylevels)`
  defines the prior, which is uniform by default
- `fixweighting = false`
  sets, whether or not the weight update fix is applied. This fix is proposed in my Master's
  thesis and in the corresponding paper.
- `alpha = 1.0`
  is the step size taken in every iteration.
  This parameter can be either a constant value or a function with the signature
  `(k::Int, pk::AbstractArray{Float64,1}, f_prev::AbstractArray{Float64,1} -> Float`,
  where `f_prev` is the estimate of the previous iteration and `pk` is the direction that
  DSEA takes in the current iteration `k`.
- `smoothing = Base.identity`
  is a function that optionally applies smoothing in between iterations
- `K = 1`
  is the maximum number of iterations.
- `epsilon = 0.0`
  is the minimum symmetric Chi Square distance between iterations. If the actual distance is
  below this threshold, convergence is assumed and the algorithm stops.
- `inspect = nothing`
  is a function `(k::Int, alpha::Float64, chi2s::Float64, spectrum::Array) -> Any`
  optionally called in every iteration.
- `loggingstream = DevNull`
  is an optional `IO` stream to write log messages to.
- `return_contributions = false`
  sets, whether or not the contributions of individual examples in `X_data` are returned as
  a tuple together with the deconvolution result.
"""
function dsea{T <: Number}(
              X_data::AbstractMatrix{Float64},
              X_train::AbstractMatrix{Float64},
              y_train::AbstractArray{T, 1},
              train_and_predict_proba::Function;
              ylevels::AbstractArray{Float64, 1} = sort(unique(y_train)),
              f_0::AbstractArray{Float64, 1} = ones(length(ylevels)) ./ length(ylevels),
              fixweighting::Bool = true,
              alpha::Union{Float64, Function} = 1.0,
              smoothing::Function = Base.identity,
              K::Int64 = 1,
              epsilon::Float64 = 0.0,
              inspect::Union{Function, Void} = nothing,
              loggingstream::IO = DevNull,
              return_contributions::Bool = false)
    
    m = length(ylevels) # number of classes
    
    # check arguments
    if size(X_data, 2) != size(X_train, 2)
        error("X_data and X_train have a different number of features")
    elseif length(f_0) != m
        error("f_0 has a wrong dimensionality")
    elseif m > .05 * (size(X_data, 1) + size(X_train, 1))
        warn("More than 5\% of the data are unique values. Are you sure the data is discrete?")
    end
    
    # initial estimate (uniform prior by default)
    f       = Util.normalizepdf(f_0)
    f_train = Util.histogram(y_train, ylevels) ./ m                            # training distribution
    w_train = _dsea_weights(y_train, fixweighting ? f ./ f_train : f, ylevels) # instance weights
    if inspect != nothing
        inspect(0, NaN, NaN, f)
    end
    
    # iterative deconvolution
    proba = Matrix{Float64}(0, 0) # empty matrix
    for k in 1:K
        f_prev = f
        
        # === update the estimate ===
        proba     = train_and_predict_proba(X_data, X_train, y_train, w_train, ylevels)
        f, alphak = _dsea_step(_dsea_reconstruct(proba), f_prev, alpha)
        # = = = = = = = = = = = = = =
        
        # monitor progress
        chi2s = Util.chi2s(f_prev, f) # Chi Square distance between iterations
        info(loggingstream, "DSEA iteration $k/$K uses alpha = $alphak (chi2s = $chi2s)")
        if inspect != nothing
            inspect(k, alphak, chi2s, f)
        end
        
        # stop when convergence is assumed
        if chi2s < epsilon # also holds when alpha is zero
            info(loggingstream, "DSEA convergence assumed from chi2s = $chi2s < epsilon = $epsilon")
            break
        end
        
        # == smoothing and reweighting in between iterations ==
        if k < K
            f = smoothing(f)
            w_train = _dsea_weights(y_train, fixweighting ? f ./ f_train : f, ylevels)
        end
        # = = = = = = = = = = = = = = = = = = = = = = = = = = =
        
    end
    
    return return_contributions ? (f, proba) : f # result may contain contributions
    
end

# the weights of training instances are based on the bin weights in w_bin
function _dsea_weights{T <: Number}(y_train::AbstractArray{T, 1},
                                    w_bin::AbstractArray{Float64, 1},
                                    ylevels::AbstractArray{T, 1})
    w_bin = Util.normalizepdf(w_bin)
    return max.([ w_bin[findfirst(ylevels .== y)] for y in y_train ], 1/length(y_train))
end

# the reconstructed estimate is the sum of confidences in each bin
_dsea_reconstruct(proba::AbstractMatrix{Float64}) = map(i -> sum(proba[:, i]), 1:size(proba, 2))

# the step taken by DSEA+, where alpha may be a constant or a function
function _dsea_step(f::AbstractArray{Float64, 1},
                    f_prev::AbstractArray{Float64, 1},
                    alpha::Union{Float64, Function})
    pk     = f - f_prev # search direction
    alphak = typeof(alpha) == Float64 ? alpha : alpha(k, pk, f_prev) # function or float
    return f_prev + alphak * pk, alphak # return tuple of estimate and step size
end

